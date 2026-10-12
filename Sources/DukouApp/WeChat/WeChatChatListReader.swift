import AppKit
import ApplicationServices
import DukouCore

/// A one-shot property read. This reader never activates WeChat or performs
/// an accessibility action, and never descends into the message subtree.
enum WeChatChatListReader {
    private static let messagingTimeout: Float = 1

    enum Failure: LocalizedError {
        case permissionRequired, windowUnavailable, ambiguousWindow, listUnavailable
        case ambiguousList, missingName, unexpectedStructure, windowChanged
        case attribute(String, AXError)

        var errorDescription: String? {
            switch self {
            case .permissionRequired: L10n.text("读取窗口列表需要辅助功能权限。")
            case .windowUnavailable: L10n.text("请先在微信中打开一个聊天窗口。")
            case .ambiguousWindow: L10n.text("无法确定当前微信窗口。请先选中需要读取的微信窗口。")
            case .listUnavailable: L10n.text("当前微信窗口没有可读取的会话列表，请先打开普通或折叠聊天列表。")
            case .ambiguousList: L10n.text("当前微信窗口包含多个会话列表，无法确认需要读取哪一个。")
            case .missingName: L10n.text("有会话没有提供完整名称，本次列表读取未完成。")
            case .unexpectedStructure: L10n.text("微信没有提供预期的列表结构，本次读取未完成。")
            case .windowChanged: L10n.text("读取期间微信窗口或列表发生变化，请重新读取。")
            case .attribute(let name, let error): L10n.format("读取微信界面失败（%@，错误 %d）。", name, error.rawValue)
            }
        }
    }

    static func read() throws -> WeChatChatList {
        guard AXIsProcessTrusted() else { throw Failure.permissionRequired }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: WeChatAccessibility.bundleIdentifier)
        guard !apps.isEmpty else { throw WeChatAutomationError.notRunning }
        guard apps.count == 1, let app = apps.first else { throw Failure.ambiguousWindow }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, messagingTimeout)
        let window = try currentWindow(root)
        let first = try snapshot(window)
        let second = try snapshot(window)
        guard CFEqual(window, try currentWindow(root)),
              first.scope == second.scope, first.identifiers == second.identifiers,
              first.currentNames == second.currentNames, first.memberCounts == second.memberCounts else {
            throw Failure.windowChanged
        }
        do {
            return try WeChatChatList.make(
                scope: first.scope, identifiers: first.identifiers,
                currentChatName: first.currentNames.count == 1 ? first.currentNames.first : nil,
                currentChatMemberCount: first.memberCounts.count == 1 ? first.memberCounts.first : nil
            )
        } catch WeChatChatList.Error.missingName {
            throw Failure.missingName
        } catch WeChatChatList.Error.unexpectedRow {
            throw Failure.unexpectedStructure
        }
    }

    private static func snapshot(_ window: AXUIElement) throws -> (
        scope: WeChatChatList.Scope, identifiers: [String], currentNames: [String], memberCounts: [String]
    ) {
        var queue = [window], index = 0
        var lists: [AXUIElement] = []
        var currentNames: [String] = [], memberCounts: [String] = []
        while index < queue.count {
            let element = queue[index]
            index += 1
            let id = try text(element, "AXIdentifier") ?? ""
            if id == "session_list" {
                lists.append(element)
                continue
            }
            if id == "current_chat_name_label", let name = try text(element, "AXValue") {
                currentNames.append(name)
            }
            if id == "current_chat_count_label", let count = try text(element, "AXValue") {
                memberCounts.append(count)
            }
            // Neither message bodies nor the input field are needed for names.
            if ["chat_message_list", "chat_log_message_list", "chat_input_field"].contains(id) { continue }
            let role = try text(element, "AXRole")
            if role == "AXMenuBar" || role == "AXTextArea" { continue }
            queue.append(contentsOf: try children(element))
        }
        guard lists.count <= 1 else { throw Failure.ambiguousList }
        guard let list = lists.first else { throw Failure.listUnavailable }
        let title = try text(list, "AXTitle")
        let scope: WeChatChatList.Scope
        if title == "折叠的聊天" {
            scope = .folded
        } else if title == "会话" {
            scope = .conversations
        } else {
            throw Failure.unexpectedStructure
        }
        let rows = try children(list, required: true)
        let identifiers = try rows.map { try text($0, "AXIdentifier") ?? "" }
        return (scope, identifiers, currentNames, memberCounts)
    }

    private static func currentWindow(_ root: AXUIElement) throws -> AXUIElement {
        guard let value = try attribute(root, "AXMainWindow", required: true),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw Failure.windowUnavailable
        }
        let window = value as! AXUIElement
        guard (try attribute(window, "AXMinimized") as? Bool) != true else { throw Failure.windowUnavailable }
        return window
    }

    private static func text(_ element: AXUIElement, _ key: String) throws -> String? {
        try attribute(element, key) as? String
    }

    private static func children(_ element: AXUIElement, required: Bool = false) throws -> [AXUIElement] {
        guard let value = try attribute(element, "AXChildren", required: required) else { return [] }
        guard let children = value as? [AXUIElement] else { throw Failure.unexpectedStructure }
        return children
    }

    private static func attribute(_ element: AXUIElement, _ key: String, required: Bool = false) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        switch result {
        case .success: return value
        case .attributeUnsupported, .noValue:
            if required { throw Failure.attribute(key, result) }
            return nil
        default: throw Failure.attribute(key, result)
        }
    }
}
