import AppKit
import ApplicationServices
import DukouCore

/// Reads the conversation names in the current WeChat window, scrolling the
/// session list itself until both ends stop moving. Wheel events go to that
/// list only; the message pane is not scrolled and no row is opened.
enum WeChatChatListReader {
    private static let messagingTimeout: Float = 1
    private static let maximumScrolls = 120

    enum Failure: LocalizedError {
        case permissionRequired, windowUnavailable, ambiguousWindow, listUnavailable
        case ambiguousList, missingName, unexpectedStructure, windowChanged
        case attribute(String, AXError), interrupted, listUnstable, listTooLong

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
            case .interrupted: L10n.text("读取时微信不在前台，请重新读取。")
            case .listUnstable: L10n.text("会话列表滚动后对不齐，请重新读取。")
            case .listTooLong: L10n.text("会话列表太长，这次没有滚到尽头。请再读一次。")
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
        try bringToFront(app)
        let window = try currentWindow(root)
        let cursor = CGEvent(source: nil)?.location
        defer { if let cursor { moveCursor(to: cursor) } }
        let initial = try stableSnapshot(window)
        var list = initial.list
        var collected = initial.identifiers
        var previous = collected
        var delta = try scrollDistance(of: list)
        var idle = 0
        var termini = 0
        var jumps = 0
        var steps = 0
        while steps < maximumScrolls && termini < 2 {
            try requireFront(app)
            guard CFEqual(window, try currentWindow(root)) else { throw Failure.windowChanged }
            try scroll(list, delta: delta)
            steps += 1
            Thread.sleep(forTimeInterval: 0.08)
            let page = try identifiersAfterScroll(of: &list, window: window, scope: initial.scope)
            if page == previous {
                idle += 1
                if idle >= 2 {
                    termini += 1
                    delta = -delta
                    idle = 0
                    jumps = 0
                }
                continue
            }
            idle = 0
            switch WeChatSessionStitch.merge(collected, with: page, scrolling: delta > 0 ? .up : .down) {
            case .grown(let next, let actual):
                collected = next
                jumps = 0
                let magnitude = abs(delta)
                delta = actual == .up ? magnitude : -magnitude
                previous = page
            case .unchanged:
                previous = page
            case .jumped:
                jumps += 1
                guard jumps <= 3 else { throw Failure.listUnstable }
                try requireFront(app)
                try scroll(list, delta: -delta)
                let magnitude = abs(delta) / 2
                guard magnitude >= 80 else { throw Failure.listUnstable }
                delta = delta > 0 ? magnitude : -magnitude
            }
        }
        guard termini >= 2 else { throw Failure.listTooLong }
        // The walk finishes at whichever end came second, usually the bottom.
        // Later lookups only see the rows on screen, so put the list back at
        // the top before returning the names.
        returnToTop(app: app, window: window, scope: initial.scope)
        let finished = try stableSnapshot(window)
        guard finished.scope == initial.scope else { throw Failure.windowChanged }
        do {
            return try WeChatChatList.make(
                scope: finished.scope, identifiers: collected,
                currentChatName: finished.currentNames.count == 1 ? finished.currentNames.first : nil,
                currentChatMemberCount: finished.memberCounts.count == 1 ? finished.memberCounts.first : nil
            )
        } catch WeChatChatList.Error.missingName {
            throw Failure.missingName
        } catch WeChatChatList.Error.unexpectedRow {
            throw Failure.unexpectedStructure
        }
    }

    private struct Snapshot {
        let list: AXUIElement
        let scope: WeChatChatList.Scope
        let identifiers: [String]
        let currentNames: [String]
        let memberCounts: [String]
    }

    /// Two identical reads. A list that is still moving is not a page boundary.
    private static func stableSnapshot(_ window: AXUIElement) throws -> Snapshot {
        let first = try snapshot(window)
        let second = try snapshot(window)
        guard first.scope == second.scope, first.identifiers == second.identifiers,
              first.currentNames == second.currentNames, first.memberCounts == second.memberCounts else {
            throw Failure.windowChanged
        }
        return second
    }

    private static func identifiersAfterScroll(of list: inout AXUIElement, window: AXUIElement, scope: WeChatChatList.Scope) throws -> [String] {
        if let page = try? stableIdentifiers(list) { return page }
        let again = try stableSnapshot(window)
        guard again.scope == scope else { throw Failure.windowChanged }
        list = again.list
        return again.identifiers
    }

    private static func stableIdentifiers(_ list: AXUIElement) throws -> [String] {
        var last: [String]?
        for _ in 0..<6 {
            let page = try sessionIdentifiers(of: list)
            if page == last { return page }
            last = page
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure.listUnstable
    }

    private static func snapshot(_ window: AXUIElement) throws -> Snapshot {
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
        return Snapshot(list: list, scope: scope, identifiers: try sessionIdentifiers(of: list), currentNames: currentNames, memberCounts: memberCounts)
    }

    /// Materialized conversation rows only. After a scroll, WeChat keeps a
    /// prefix of `virtual_cell` placeholders for rows that have not been
    /// built yet; those are not conversations and must not be stitched.
    private static func sessionIdentifiers(of list: AXUIElement) throws -> [String] {
        try children(list, required: true).map { try text($0, "AXIdentifier") ?? "" }.filter { $0.hasPrefix("session_item_") }
    }

    /// Scroll toward the top until the visible rows stop changing. A list that
    /// will not move is left where it is; the names already collected stay.
    private static func returnToTop(app: NSRunningApplication, window: AXUIElement, scope: WeChatChatList.Scope) {
        guard var list = try? stableSnapshot(window).list, let distance = try? scrollDistance(of: list) else { return }
        var previous = (try? sessionIdentifiers(of: list)) ?? []
        var idle = 0
        for _ in 0..<maximumScrolls {
            if (try? requireFront(app)) == nil { return }
            if (try? scroll(list, delta: distance)) == nil { return }
            Thread.sleep(forTimeInterval: 0.08)
            let page: [String]
            if let stable = try? stableIdentifiers(list) {
                page = stable
            } else if let again = try? stableSnapshot(window), again.scope == scope {
                list = again.list
                page = again.identifiers
            } else {
                return
            }
            if page == previous {
                idle += 1
                if idle >= 2 { return }
            } else {
                idle = 0
                previous = page
            }
        }
    }

    /// Positive moves toward the top of the session list, matching the wheel
    /// direction that reveals older rows in a chat. Half the list stays on
    /// screen so the next page still overlaps.
    private static func scrollDistance(of list: AXUIElement) throws -> Int32 {
        let height = try frame(list).height
        // A session row is about 65 points. Keep most of the current page on
        // screen so the next page still shares real conversation names.
        return Int32(min(220, max(130, height * 0.3)).rounded())
    }

    private static func scroll(_ list: AXUIElement, delta: Int32) throws {
        let rect = try frame(list)
        guard rect.width > 20, rect.height > 20 else { throw Failure.listUnavailable }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let source = CGEventSource(stateID: .privateState)
        moveCursor(to: point)
        Thread.sleep(forTimeInterval: 0.03)
        func event(_ phase: CGScrollPhase, _ amount: Int32) -> CGEvent? {
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
            event?.location = point
            event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return event
        }
        guard let began = event(.began, 0), let changed = event(.changed, delta), let ended = event(.ended, 0) else {
            throw Failure.listUnstable
        }
        began.post(tap: .cghidEventTap)
        changed.post(tap: .cghidEventTap)
        ended.post(tap: .cghidEventTap)
    }

    private static func moveCursor(to point: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func bringToFront(_ app: NSRunningApplication) throws {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
        guard let url = app.bundleURL else { throw WeChatAutomationError.notRunning }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in opened.signal() }
        _ = opened.wait(timeout: .now() + 3)
        let deadline = Date().addingTimeInterval(3)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        try requireFront(app)
    }

    private static func requireFront(_ app: NSRunningApplication) throws {
        guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw Failure.interrupted
        }
    }

    private static func frame(_ element: AXUIElement) throws -> CGRect {
        guard let position = try attribute(element, "AXPosition", required: true),
              let size = try attribute(element, "AXSize", required: true),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { throw Failure.unexpectedStructure }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { throw Failure.unexpectedStructure }
        return CGRect(origin: point, size: dimensions)
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
