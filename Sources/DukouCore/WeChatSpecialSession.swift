import Foundation

/// Session-list rows that are not conversations.
///
/// WeChat puts these in the same list as chats. Opening one replaces the
/// transcript with another surface, so a batch must leave them alone.
/// Add a name here when a new entry of this kind shows up.
public enum WeChatSpecialSession: String, Sendable, Equatable {
    /// 公众号. The article list, not a message transcript.
    case officialAccounts
    /// 折叠的聊天. A folder that replaces the session list.
    case foldedChats
    /// 服务通知 / 企业通知. Notification cards, including 企业微信 invites.
    case serviceNotices
    /// 微信支付. Bills and payment services, not a transcript.
    case weChatPay
    /// 微信团队. The product account, not a group to export.
    case weChatTeam
    /// 客服消息. The customer-service inbox, not a group transcript.
    case customerService

    public static func kind(of name: String) -> Self? {
        catalog[WeChatForwardPreset.normalizedChat(name)]
    }

    private static let catalog: [String: Self] = [
        "公众号": .officialAccounts,
        "官方帳號": .officialAccounts,
        "Official Accounts": .officialAccounts,
        "折叠的聊天": .foldedChats,
        "摺疊的聊天": .foldedChats,
        "Folded Chats": .foldedChats,
        "服务通知": .serviceNotices,
        "服務通知": .serviceNotices,
        "Service Notifications": .serviceNotices,
        "企业通知": .serviceNotices,
        "企業通知": .serviceNotices,
        "微信支付": .weChatPay,
        "WeChat Pay": .weChatPay,
        "微信团队": .weChatTeam,
        "微信團隊": .weChatTeam,
        "WeChat Team": .weChatTeam,
        "客服消息": .customerService,
        "客服訊息": .customerService,
        "Customer Service Messages": .customerService,
    ]
}
