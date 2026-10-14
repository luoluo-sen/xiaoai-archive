import Foundation

/// Where Home landed during warm-up. The child index is the focused row's
/// position among the message list's accessibility children. A virtual prefix
/// can keep that index above zero even when repeated Home keys reveal no new
/// history, so identity changes alone are not evidence of progress.
public struct WeChatHomeLanding: Equatable, Sendable {
    public let childIndex: Int?
    public let flushWithListTop: Bool
    /// A real, readable row at the top edge. Virtual cells and blank frames are not.
    public let materialized: Bool

    public init(childIndex: Int?, flushWithListTop: Bool, materialized: Bool) {
        self.childIndex = childIndex
        self.flushWithListTop = flushWithListTop
        self.materialized = materialized
    }
}

/// Whether a Home key established a baseline or actually revealed an older
/// materialised prefix. The first landing is only a baseline: its absolute
/// child index is not a count of newly loaded messages. Later decreases are
/// the only distances credited to warm-up progress.
public enum WeChatHomeAdvance: Equatable, Sendable {
    case baseline(bestIndex: Int)
    case older(distance: Int, bestIndex: Int)
    case unchanged
    case pending

    public static func judge(bestIndex: Int?, _ landing: WeChatHomeLanding) -> WeChatHomeAdvance {
        guard landing.materialized, landing.flushWithListTop,
              let index = landing.childIndex, index >= 0 else { return .pending }
        // The first child has no unresolved prefix above it. Let the existing
        // history-top probe decide whether this is the conversation beginning.
        guard index > 0 else { return .unchanged }
        guard let bestIndex else { return .baseline(bestIndex: index) }
        guard index < bestIndex else { return .unchanged }
        return .older(distance: bestIndex - index, bestIndex: index)
    }
}
