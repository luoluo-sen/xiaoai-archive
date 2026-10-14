import Foundation

/// A loading episode borrows a slower cadence; it must not become the cadence
/// of the remaining conversation. Gain is measured in points/event units.
/// Geometry and message identity remain the navigation engine's responsibility.
public struct WeChatScrollPacing: Sendable {
    public enum Event: String, Sendable { case unchanged, throttled, restored, timedOut }
    public static let maximumStallSeconds = 8.0
    public static let maximumTransientPause = 0.45
    public static let recoveryObservations = 2

    public private(set) var pause: Double
    public private(set) var ceiling: Int32
    private var previous: (pause: Double, ceiling: Int32)?
    private var started: Double?
    private var recovery = 0
    private var healthySteps = 0

    public init(pause: Double = WeChatScrollStep.baseGesturePause,
                ceiling: Int32 = WeChatScrollStep.maximumDelta) {
        self.pause = pause.isFinite
            ? max(WeChatScrollStep.minimumGesturePause, min(WeChatScrollStep.maximumGesturePause, pause))
            : WeChatScrollStep.baseGesturePause
        self.ceiling = max(60, min(WeChatScrollStep.maximumDelta, ceiling))
    }

    public var isLoading: Bool { previous != nil }

    public func hasTimedOut(at now: Double) -> Bool {
        guard let started else { return false }
        return !now.isFinite || now < started || now - started >= Self.maximumStallSeconds
    }

    /// Two consecutive healthy measurements restore the exact pre-load values,
    /// including a previously calibrated ceiling. Bad/unmeasured samples cannot
    /// reset the loading deadline or count as successful recovery.
    @discardableResult
    public mutating func observe(gain: Double, at now: Double) -> Event {
        guard now.isFinite, !hasTimedOut(at: now) else { return .timedOut }
        if WeChatScrollStep.isPlausible(gain: gain) {
            if previous != nil {
                recovery += 1
                if recovery >= Self.recoveryObservations {
                    finishSegment()
                    return .restored
                }
            } else {
                healthySteps += 1
                pause = WeChatScrollStep.shortened(pause, healthySteps: healthySteps)
            }
            return .unchanged
        }
        recovery = 0
        guard gain.isFinite, gain >= 0, gain < 0.4 else { return .unchanged }
        if previous == nil {
            previous = (pause, ceiling)
            started = now
        }
        healthySteps = 0
        pause = max(pause, min(Self.maximumTransientPause, max(WeChatScrollStep.baseGesturePause, pause * 2)))
        let floor = min(previous?.ceiling ?? ceiling, 300)
        ceiling = max(floor, ceiling / 2)
        return .throttled
    }

    /// End of prefetch or of one selection interval, including error/cancel.
    /// Slow cold-history state must never leak into another batch or group.
    @discardableResult
    public mutating func finishSegment() -> Bool {
        let hadLoading = previous != nil
        if let previous { pause = previous.pause; ceiling = previous.ceiling }
        previous = nil
        started = nil
        recovery = 0
        healthySteps = 0
        return hadLoading
    }
}
