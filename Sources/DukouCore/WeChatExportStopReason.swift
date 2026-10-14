import Foundation

/// Partial delivery is not necessarily a boundary failure. Keep the reason
/// separate so slow I/O cannot masquerade as a missing next-batch anchor.
public enum WeChatExportStopReason: String, Sendable {
    case nextBatchAnchor, rangeEndpoint, historyLoadingTimeout, scrollStalled

    public var isBoundary: Bool { self == .nextBatchAnchor || self == .rangeEndpoint }

    public var savedMessage: String {
        switch self {
        case .nextBatchAnchor:
            L10n.text("已保存已导出的记录。下一批的起点无法确认，已停止。")
        case .rangeEndpoint:
            L10n.text("已保存已导出的记录。本批消息的选区终点无法确认，已停止。")
        case .historyLoadingTimeout:
            L10n.text("已保存已导出的记录。微信加载历史超时，已停止。")
        case .scrollStalled:
            L10n.text("已保存已导出的记录。微信滚动持续受限，等待恢复超时，已停止。")
        }
    }
}
