import Foundation
#if !HISTORY_BOUNDARY_STANDALONE
import DukouCore
#endif

/// Shared by XCTest and the command-line runner; no alternative production
/// implementation is substituted when the machine has only Command Line Tools.
enum HistoryBoundaryScenarios {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static func require(_ value: @autoclosure () -> Bool, _ message: String = "assertion failed") throws {
        if !value() { throw Failure(description: message) }
    }
    static func notice(_ id: String) -> WeChatHistoryRow {
        .init(kind: .notice, fingerprint: id)
    }
    static func message(_ id: String = "oldest-message", selected: Bool = false) -> WeChatHistoryRow {
        .init(kind: .message, fingerprint: id, selected: selected)
    }
    static var cases: [(String, () throws -> Void)] {
        [
            ("notice-only viewport", noticeOnlyViewport),
            ("first bubble after notices", firstBubbleAfterNotices),
            ("older bubble is not EOF", olderBubbleIsNotEOF),
            ("virtual prefix is pending", virtualPrefixIsPending),
            ("unreadable prefix", unreadablePrefix),
            ("busy list", busyList),
            ("changed prefix resets quiet proof", changedPrefixResets),
            ("read failure resets quiet proof", failureResets),
            ("observations alone are insufficient", observationCountNeedsTime),
            ("elapsed time alone is insufficient", elapsedTimeNeedsObservations),
            ("nonmonotonic clock", invalidClock),
            ("missing list is not EOF", missingList),
            ("zero separators needs no Down", zeroSeparators),
            ("one separator", oneSeparator),
            ("220 join notices", manyNotices),
            ("identical notices retain multiplicity", repeatedNotices),
            ("wrong message aborts", wrongMessage),
            ("changed notice aborts permanently", changedNotice),
            ("single selected anchor", selectedAnchor),
            ("unexpected selection state", changedSelection),
            ("unresolved route is rejected", unresolvedRoute),
            ("delayed older history", delayedHistory),
            ("exact batch boundary can end without another bubble", exactBatchBoundary),
            ("offscreen new arrivals do not reset a history prefix", offscreenArrivals),
            ("oversized first row must reach its leading edge", leadingEdgeMustBeVisible)
        ]
    }
    static func noticeOnlyViewport() throws {
        let prefix = [notice("timestamp"), notice("joined-by-QR")]
        try require(WeChatHistoryPrefix.judge(prefix) == .candidate)
        var probe = WeChatHistoryTopProbe()
        try require(!probe.observe(prefix, at: 0))
        try require(!probe.observe(prefix, at: 1))
        try require(probe.observe(prefix, at: 2))
    }
    static func firstBubbleAfterNotices() throws {
        try require(WeChatHistoryPrefix.judge([notice("timestamp"), message()]) == .candidate)
    }
    static func olderBubbleIsNotEOF() throws {
        try require(WeChatHistoryPrefix.judge([message("older"), notice("current")]) == .olderMessage)
        var probe = WeChatHistoryTopProbe()
        for t in 0..<10 { try require(!probe.observe([message("older"), message()], at: Double(t))) }
    }
    static func virtualPrefixIsPending() throws {
        let prefix: [WeChatHistoryRow] = [.init(kind: .unresolved, fingerprint: "virtual", materialized: false), notice("top")]
        try require(WeChatHistoryPrefix.judge(prefix) == .pending)
        var probe = WeChatHistoryTopProbe()
        for t in 0..<10 { try require(!probe.observe(prefix, at: Double(t))) }
    }
    static func unreadablePrefix() throws {
        try require(WeChatHistoryPrefix.judge([.init(kind: .notice, fingerprint: "unreadable", readable: false), notice("focus")]) == .unreadable)
    }
    static func busyList() throws {
        var probe = WeChatHistoryTopProbe()
        for t in 0..<10 { try require(!probe.observe([notice("top")], at: Double(t), busy: true)) }
    }
    static func changedPrefixResets() throws {
        var probe = WeChatHistoryTopProbe()
        let a = [notice("old-top")], b = [notice("newly-loaded"), notice("old-top")]
        try require(!probe.observe(a, at: 0))
        try require(!probe.observe(a, at: 1))
        try require(!probe.observe(b, at: 2))
        try require(!probe.observe(b, at: 3))
        try require(probe.observe(b, at: 4))
    }
    static func failureResets() throws {
        var probe = WeChatHistoryTopProbe()
        let prefix = [notice("top")]
        try require(!probe.observe(prefix, at: 0))
        try require(!probe.observe(prefix, at: 1))
        try require(!probe.observe([], at: 2))
        try require(!probe.observe(prefix, at: 3))
        try require(!probe.observe(prefix, at: 4))
        try require(probe.observe(prefix, at: 5))
    }
    static func observationCountNeedsTime() throws {
        var probe = WeChatHistoryTopProbe()
        for n in 0..<20 { try require(!probe.observe([notice("top")], at: Double(n) / 100)) }
    }
    static func elapsedTimeNeedsObservations() throws {
        var probe = WeChatHistoryTopProbe()
        try require(!probe.observe([notice("top")], at: 0))
        try require(!probe.observe([notice("top")], at: 50))
    }
    static func invalidClock() throws {
        var probe = WeChatHistoryTopProbe()
        try require(!probe.observe([notice("top")], at: 2))
        try require(!probe.observe([notice("top")], at: 1))
        try require(!probe.observe([notice("top")], at: .nan))
        try require(!probe.observe([notice("top")], at: .infinity))
    }
    static func missingList() throws {
        try require(WeChatHistoryPrefix.judge([]) == .missing)
        var probe = WeChatHistoryTopProbe()
        for t in 0..<10 { try require(!probe.observe([], at: Double(t))) }
    }
    static func zeroSeparators() throws {
        guard let rewind = WeChatHistoryRewind(endpoint: message(selected: true), passedNotices: []) else { throw Failure(description: "missing plan") }
        try require(rewind.isComplete && rewind.remaining == 0)
    }
    static func oneSeparator() throws {
        guard var rewind = WeChatHistoryRewind(endpoint: message(), passedNotices: [notice("timestamp")]) else { throw Failure(description: "missing plan") }
        try require(rewind.remaining == 1)
        try require(rewind.accept(message()) == .arrived)
    }
    static func manyNotices() throws {
        // Reproduction of the failure class: no visible bubble at the top,
        // and the first Down lands on ANOTHER notice, not on lastMessage.
        let trail = (0..<220).map { notice("join-\($0)") }
        guard var rewind = WeChatHistoryRewind(endpoint: message(), passedNotices: trail) else { throw Failure(description: "missing plan") }
        try require(rewind.remaining == 220)
        for row in trail.dropLast().reversed() { try require(rewind.accept(row) == .continuing) }
        try require(rewind.accept(message()) == .arrived)
        try require(rewind.isComplete && rewind.remaining == 0)
    }
    static func repeatedNotices() throws {
        let row = notice("same join notice")
        guard var rewind = WeChatHistoryRewind(endpoint: message(), passedNotices: Array(repeating: row, count: 4)) else { throw Failure(description: "missing plan") }
        for _ in 0..<3 { try require(rewind.accept(row) == .continuing) }
        try require(rewind.accept(message()) == .arrived)
    }
    static func wrongMessage() throws {
        guard var rewind = WeChatHistoryRewind(endpoint: message(), passedNotices: [notice("a"), notice("b")]) else { throw Failure(description: "missing plan") }
        try require(rewind.accept(message("unrelated")) == .mismatch)
        try require(!rewind.isComplete)
    }
    static func changedNotice() throws {
        guard var rewind = WeChatHistoryRewind(endpoint: message(), passedNotices: [notice("a"), notice("b")]) else { throw Failure(description: "missing plan") }
        try require(rewind.accept(notice("recycled")) == .mismatch)
        try require(rewind.accept(notice("a")) == .mismatch)
    }
    static func selectedAnchor() throws {
        let anchor = message(selected: true)
        guard var rewind = WeChatHistoryRewind(endpoint: anchor, passedNotices: [notice("timestamp")]) else { throw Failure(description: "missing plan") }
        try require(rewind.accept(anchor) == .arrived)
    }
    static func changedSelection() throws {
        guard var rewind = WeChatHistoryRewind(endpoint: message(), passedNotices: [notice("timestamp")]) else { throw Failure(description: "missing plan") }
        try require(rewind.accept(message(selected: true)) == .mismatch)
    }
    static func unresolvedRoute() throws {
        let unknown = WeChatHistoryRow(kind: .unresolved, fingerprint: "virtual")
        try require(WeChatHistoryRewind(endpoint: message(), passedNotices: [unknown]) == nil)
        try require(WeChatHistoryRewind(endpoint: notice("not a bubble"), passedNotices: []) == nil)
    }
    static func delayedHistory() throws {
        var probe = WeChatHistoryTopProbe()
        try require(!probe.observe([notice("top")], at: 0))
        try require(!probe.observe([notice("top")], at: 1))
        let loaded = [message("fetched older record"), notice("previous top")]
        for t in 2..<10 { try require(!probe.observe(loaded, at: Double(t))) }
    }
    static func exactBatchBoundary() throws {
        var probe = WeChatHistoryTopProbe()
        // Normal-mode endpoint after sharing the 100th message. No 101st
        // bubble is needed to prove that the exposed history has ended.
        let prefix = [notice("created"), notice("joined"), message("100th")]
        try require(!probe.observe(prefix, at: 0))
        try require(!probe.observe(prefix, at: 1))
        try require(probe.observe(prefix, at: 2))
    }
    static func offscreenArrivals() throws {
        var probe = WeChatHistoryTopProbe()
        // Only the prefix through focus is input, never the full child count.
        let prefix = [notice("top")]
        try require(!probe.observe(prefix, at: 0))
        try require(!probe.observe(prefix, at: 1))
        try require(probe.observe(prefix, at: 2))
    }
    static func leadingEdgeMustBeVisible() throws {
        var probe = WeChatHistoryTopProbe()
        let prefix = [notice("very tall join header")]
        for t in 0..<8 { try require(!probe.observe(prefix, at: Double(t), leadingEdgeVisible: false)) }
        try require(!probe.observe(prefix, at: 8))
        try require(!probe.observe(prefix, at: 9))
        try require(probe.observe(prefix, at: 10))
    }

}
