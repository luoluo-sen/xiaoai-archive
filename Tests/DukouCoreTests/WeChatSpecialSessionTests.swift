import XCTest
@testable import DukouCore

final class WeChatSpecialSessionTests: XCTestCase {
    func testOfficialAccountsIsNotAConversation() {
        XCTAssertEqual(WeChatSpecialSession.kind(of: "公众号"), .officialAccounts)
        XCTAssertEqual(WeChatSpecialSession.kind(of: "官方帳號"), .officialAccounts)
        XCTAssertEqual(WeChatSpecialSession.kind(of: "Official Accounts"), .officialAccounts)
    }

    func testFoldedChatsIsNotAConversation() {
        XCTAssertEqual(WeChatSpecialSession.kind(of: "折叠的聊天"), .foldedChats)
        XCTAssertEqual(WeChatSpecialSession.kind(of: " 折叠的聊天 "), .foldedChats)
    }

    func testServiceNoticesAreNotConversations() {
        XCTAssertEqual(WeChatSpecialSession.kind(of: "服务通知"), .serviceNotices)
        XCTAssertEqual(WeChatSpecialSession.kind(of: "企业通知"), .serviceNotices)
        XCTAssertEqual(WeChatSpecialSession.kind(of: "企業通知"), .serviceNotices)
    }

    func testWeChatPayAndTeamAreNotConversations() {
        XCTAssertEqual(WeChatSpecialSession.kind(of: "微信支付"), .weChatPay)
        XCTAssertEqual(WeChatSpecialSession.kind(of: "微信团队"), .weChatTeam)
        XCTAssertEqual(WeChatSpecialSession.kind(of: "微信團隊"), .weChatTeam)
        XCTAssertEqual(WeChatSpecialSession.kind(of: "客服消息"), .customerService)
        XCTAssertEqual(WeChatSpecialSession.kind(of: "客服訊息"), .customerService)
    }

    func testANormalGroupIsNotSpecial() {
        XCTAssertNil(WeChatSpecialSession.kind(of: "硅基边界｜智能体搭建交流10"))
        XCTAssertNil(WeChatSpecialSession.kind(of: "文件传输助手"))
    }
}
