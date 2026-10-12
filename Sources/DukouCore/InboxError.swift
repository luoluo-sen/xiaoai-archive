import Foundation

public enum InboxError: Error, LocalizedError, Equatable {
    case inboxUnavailable
    case unsupportedAttachment(types: [String])
    case emptyShare
    case manifestUnreadable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .inboxUnavailable:
            return L10n.text("收件箱尚未就绪，请检查“下载”文件夹的访问权限。")
        case .unsupportedAttachment(let types):
            let list = types.isEmpty ? L10n.text("未知类型") : types.joined(separator: ", ")
            return L10n.format("这项内容不是 xiaoai-archive 能保存的文件（%@）。", list)
        case .emptyShare:
            return L10n.text("这次分享没有包含任何文件。")
        case .manifestUnreadable(let reason):
            return L10n.format("批次清单无法读取：%@", reason)
        }
    }
}
