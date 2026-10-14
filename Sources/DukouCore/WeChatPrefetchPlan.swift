import Foundation

/// A bounded warm-up target, deliberately separate from the exact export
/// count. Warming is only a performance hint: selection still proves every
/// message boundary and produces every native ZIP.
public struct WeChatPrefetchGoal: Equatable, Sendable {
    public let messages: Int
    public let timeBudget: Double

    public init(messages: Int, timeBudget: Double) {
        self.messages = max(0, messages)
        self.timeBudget = timeBudget.isFinite ? max(0, timeBudget) : 0
    }

    public var paddedSlots: Int {
        let padded = messages.addingReportingOverflow(max(32, messages / 4))
        return padded.overflow ? Int.max : padded.partialValue
    }

    public func needsMore(loadedSlots: Int) -> Bool {
        loadedSlots < paddedSlots
    }
}

public enum WeChatPrefetchPlan {
    /// Three native batches amortise the first cold edge without making a
    /// multi-year conversation load completely before the first ZIP exists.
    public static let initialWindowBatches = 3
    public static let initialWindowMessages = WeChatPrefetch.threshold * initialWindowBatches

    /// Initial warming must never dominate time-to-first-archive. A warm-up
    /// that cannot make enough progress within this budget is abandoned and
    /// ordinary verified selection continues from the live bottom.
    public static let maximumInitialSeconds = 30.0

    /// Incremental runs stop at an archived overlap and remain bounded to 40
    /// batches. Once selection begins, no code path may send the viewport back
    /// to End. Ordinary full-history runs warm only the initial window; they do
    /// not make reaching the client-visible beginning a prerequisite for saving.
    public static func goal(requestedMessages: Int, incremental: Bool = false,
                            completedBatches: Int = 0) -> WeChatPrefetchGoal? {
        guard !incremental, completedBatches == 0, requestedMessages >= 0 else { return nil }
        let requested = requestedMessages == 0 ? initialWindowMessages : requestedMessages
        guard requested > WeChatPrefetch.threshold else { return nil }
        let target = min(requested, initialWindowMessages)
        return WeChatPrefetchGoal(
            messages: target,
            timeBudget: min(maximumInitialSeconds, WeChatPrefetch.budget(messages: target))
        )
    }
}
