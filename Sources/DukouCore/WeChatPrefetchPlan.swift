import Foundation

/// A warm-up goal is deliberately separate from the exact selection count.
/// A nil time budget is allowed ONLY for a progressing full-history warm-up;
/// each loading episode is still bounded by WeChatScrollPacing.
public enum WeChatPrefetchGoal: Equatable, Sendable {
    case messages(Int)
    case allHistory

    public var paddedSlots: Int? {
        guard case .messages(let count) = self else { return nil }
        let padded = count.addingReportingOverflow(max(32, count / 4))
        return padded.overflow ? Int.max : padded.partialValue
    }

    public var timeBudget: Double? {
        guard case .messages(let count) = self else { return nil }
        return WeChatPrefetch.budget(messages: count)
    }

    public func needsMore(loadedSlots: Int) -> Bool {
        guard let paddedSlots else { return true }
        return loadedSlots < paddedSlots
    }
}

public enum WeChatPrefetchPlan {
    /// Incremental runs stop at an archived overlap and remain bounded to 40
    /// batches. Preloading the whole conversation would defeat that bound.
    /// Once selection begins, no code path may send the viewport back to End.
    public static func goal(requestedMessages: Int, incremental: Bool = false,
                            completedBatches: Int = 0) -> WeChatPrefetchGoal? {
        guard !incremental, completedBatches == 0, requestedMessages >= 0 else { return nil }
        if requestedMessages == 0 { return .allHistory }
        return requestedMessages > WeChatPrefetch.threshold ? .messages(requestedMessages) : nil
    }
}
