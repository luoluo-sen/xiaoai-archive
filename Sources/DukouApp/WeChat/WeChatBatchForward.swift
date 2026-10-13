import DukouCore
import Foundation

enum WeChatBatchState: Equatable {
    case waiting, running, completed, failed, cancelled

    var title: String {
        switch self {
        case .waiting: L10n.text("等待执行")
        case .running: L10n.text("正在处理")
        case .completed: L10n.text("已完成")
        case .failed: L10n.text("失败，已暂停")
        case .cancelled: L10n.text("已取消")
        }
    }
}

struct WeChatBatchRow: Identifiable {
    let id: String
    let chat: String
    let isConfirmedGroup: Bool
    var isSelected = false
    /// Empty means the explicitly configured uniform count.
    var countText = ""
    var state = WeChatBatchState.waiting
    var detail: String?
}
