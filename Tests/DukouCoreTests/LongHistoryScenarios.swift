import Foundation
#if !LONG_HISTORY_STANDALONE
@testable import DukouCore
#endif

/// Shared by XCTest and the CLT-only runner. Every assertion calls production
/// policies, not a second implementation of the navigation algorithm.
enum LongHistoryScenarios {
    struct Scenario {
        let name: String
        let run: () throws -> Void
        init(_ name: String, _ run: @escaping () throws -> Void) { self.name = name; self.run = run }
    }
    struct Failure: Error, CustomStringConvertible {
        let line: UInt
        var description: String { "Expectation failed at LongHistoryScenarios.swift:\(line)" }
    }
    static func expect(_ value: @autoclosure () -> Bool, line: UInt = #line) throws {
        if !value() { throw Failure(line: line) }
    }
    static func near(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 0.000_001 }

    static func all() -> [Scenario] {
        [
            Scenario("all history preloads") {
                try expect(WeChatPrefetchPlan.goal(requestedMessages: 0) == .allHistory)
            },
            Scenario("long finite requests preload") {
                for n in [101, 300, 4000] { try expect(WeChatPrefetchPlan.goal(requestedMessages: n) == .messages(n)) }
            },
            Scenario("one batch and invalid input skip prefetch") {
                for n in [-1, 1, 99, 100] { try expect(WeChatPrefetchPlan.goal(requestedMessages: n) == nil) }
            },
            Scenario("never prefetch between batches") {
                for batch in 1...50 {
                    try expect(WeChatPrefetchPlan.goal(requestedMessages: 0, completedBatches: batch) == nil)
                    try expect(WeChatPrefetchPlan.goal(requestedMessages: 5000, completedBatches: batch) == nil)
                }
            },
            Scenario("incremental does not warm unlimited history") {
                for n in [0, 100, 4000, Int.max] { try expect(WeChatPrefetchPlan.goal(requestedMessages: n, incremental: true) == nil) }
            },
            Scenario("full history has no arbitrary total time cap") {
                try expect(WeChatPrefetchGoal.allHistory.timeBudget == nil)
                try expect(WeChatPrefetchGoal.allHistory.needsMore(loadedSlots: Int.max))
            },
            Scenario("finite warm-up budget stays bounded") {
                try expect(WeChatPrefetchGoal.messages(300).timeBudget == 130)
                try expect(WeChatPrefetchGoal.messages(Int.max).timeBudget == 180)
            },
            Scenario("finite goal includes padding and saturates safely") {
                try expect(WeChatPrefetchGoal.messages(300).paddedSlots == 375)
                try expect(WeChatPrefetchGoal.messages(300).needsMore(loadedSlots: 374))
                try expect(!WeChatPrefetchGoal.messages(300).needsMore(loadedSlots: 375))
                try expect(WeChatPrefetchGoal.messages(Int.max).paddedSlots == Int.max)
            },
            Scenario("50-point clamp is temporary") {
                var p = WeChatScrollPacing(pause: 0.08)
                try expect(p.observe(gain: 50.0 / 520, at: 1) == .throttled)
                try expect(p.ceiling == 300 && p.pause >= 0.22 && p.isLoading)
            },
            Scenario("two healthy steps restore exact prior calibration") {
                var p = WeChatScrollPacing(pause: 0.08, ceiling: 460)
                p.observe(gain: 0.1, at: 1)
                p.observe(gain: 1.2, at: 2)
                try expect(p.isLoading)
                try expect(p.observe(gain: 1.1, at: 3) == .restored)
                try expect(p.ceiling == 460 && near(p.pause, 0.08) && !p.isLoading)
            },
            Scenario("repeated clamps retain original baseline") {
                var p = WeChatScrollPacing(pause: 0.12)
                for t in 0...5 { p.observe(gain: 0.1, at: Double(t)) }
                p.observe(gain: 1, at: 6)
                p.observe(gain: 1, at: 7)
                try expect(p.ceiling == 520 && near(p.pause, 0.12))
            },
            Scenario("one healthy step cannot hide another stall") {
                var p = WeChatScrollPacing()
                p.observe(gain: 0.1, at: 0)
                p.observe(gain: 1, at: 1)
                p.observe(gain: 0.1, at: 2)
                p.observe(gain: 1, at: 3)
                try expect(p.isLoading)
                try expect(p.observe(gain: 1, at: 4) == .restored)
            },
            Scenario("segment end restores even without healthy steps") {
                var p = WeChatScrollPacing(pause: 0.1, ceiling: 500)
                p.observe(gain: 0, at: 0)
                try expect(p.finishSegment())
                try expect(p.ceiling == 500 && near(p.pause, 0.1) && !p.isLoading)
                try expect(!p.finishSegment())
            },
            Scenario("transient wait never grows to 0.9 seconds") {
                var p = WeChatScrollPacing()
                for t in 0...7 { p.observe(gain: 0.1, at: Double(t)) }
                try expect(p.pause <= WeChatScrollPacing.maximumTransientPause)
            },
            Scenario("loading deadline is not restarted on every gesture") {
                var p = WeChatScrollPacing()
                for t in 0...7 { p.observe(gain: 0.1, at: Double(t)) }
                try expect(p.observe(gain: 0.1, at: 8) == .timedOut)
            },
            Scenario("late healthy sample cannot defeat timeout") {
                var p = WeChatScrollPacing()
                p.observe(gain: 0.1, at: 0)
                try expect(p.observe(gain: 1.2, at: 8) == .timedOut)
            },
            Scenario("nonfinite gain cannot manufacture recovery") {
                var p = WeChatScrollPacing()
                p.observe(gain: 0.1, at: 0)
                p.observe(gain: .nan, at: 1)
                p.observe(gain: .infinity, at: 2)
                try expect(p.isLoading && p.ceiling == 300)
                try expect(p.hasTimedOut(at: 8))
            },
            Scenario("implausible fast displacement cannot recover") {
                var p = WeChatScrollPacing()
                p.observe(gain: 0.1, at: 0)
                p.observe(gain: 50, at: 1)
                p.observe(gain: 50, at: 2)
                try expect(p.isLoading)
            },
            Scenario("clock regression cannot produce endless wait") {
                var p = WeChatScrollPacing()
                p.observe(gain: 0.1, at: 5)
                try expect(p.hasTimedOut(at: 4))
                try expect(p.observe(gain: 1, at: .nan) == .timedOut)
            },
            Scenario("thousands of healthy steps do not retain ceiling 300") {
                var p = WeChatScrollPacing()
                p.observe(gain: 0.1, at: 0)
                for n in 1...4000 { p.observe(gain: 1, at: Double(n) * 0.1) }
                try expect(p.ceiling == 520 && near(p.pause, WeChatScrollStep.minimumGesturePause))
            },
            Scenario("independent group starts with default cadence") {
                var first = WeChatScrollPacing()
                first.observe(gain: 0.1, at: 0)
                let second = WeChatScrollPacing()
                try expect(second.ceiling == 520 && near(second.pause, 0.22) && !second.isLoading)
            },
            Scenario("healthy baseline still speeds up adaptively") {
                var p = WeChatScrollPacing()
                for n in 0..<4 { p.observe(gain: 1, at: Double(n)) }
                try expect(near(p.pause, 0.20))
            },
            Scenario("calibrated smaller ceiling is not raised by recovery") {
                var p = WeChatScrollPacing(pause: 0.1, ceiling: 240)
                p.observe(gain: 0, at: 0)
                try expect(p.ceiling <= 240)
                p.finishSegment()
                try expect(p.ceiling == 240)
            },
            Scenario("ordinary measured wheel reach is 70 percent") {
                let reach = WeChatScrollStep.reach(listHeight: 650, tallestRow: 98, gainMeasured: true, reachFactor: 1)
                try expect(near(Double(reach), 455))
            },
            Scenario("tall bubble retains overlap safeguard") {
                let reach = WeChatScrollStep.reach(listHeight: 650, tallestRow: 400, gainMeasured: true, reachFactor: 1)
                try expect(reach + 400 + 24 <= 650)
            },
            Scenario("oversized bubble retains third-screen fallback") {
                let reach = WeChatScrollStep.reach(listHeight: 650, tallestRow: 900, gainMeasured: true, reachFactor: 1)
                try expect(near(Double(reach), 650.0 / 3))
            },
            Scenario("unmeasured gain stays careful") {
                try expect(WeChatScrollStep.reach(listHeight: 650, tallestRow: 90, gainMeasured: false, reachFactor: 1) == 260)
            },
            Scenario("overshoot factor still reduces 70-percent reach") {
                let reach = WeChatScrollStep.reach(listHeight: 650, tallestRow: 90, gainMeasured: true, reachFactor: 0.5)
                try expect(near(Double(reach), 227.5))
            },
            Scenario("event units never exceed 520") {
                for gain in [0.01, 0.4, 1.0, 5.0] {
                    try expect(WeChatScrollStep.delta(reach: 50_000, gain: gain) <= 520)
                }
            },
            Scenario("pinned endpoint still uses row-sized clearance") {
                try expect(WeChatFocusClearance.pinnedClearance(rowHeight: 79) == 79)
                try expect(WeChatFocusClearance.pinnedClearance(rowHeight: 289) == 140)
                try expect(WeChatFocusClearance.pinnedClearance(rowHeight: 20) == 48)
            },
            Scenario("loading errors are not boundary errors") {
                try expect(!WeChatExportStopReason.historyLoadingTimeout.isBoundary)
                try expect(!WeChatExportStopReason.scrollStalled.isBoundary)
                try expect(WeChatExportStopReason.nextBatchAnchor.isBoundary)
                try expect(WeChatExportStopReason.rangeEndpoint.isBoundary)
            }
        ]
    }
}
