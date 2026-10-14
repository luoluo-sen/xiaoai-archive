import AppKit
import ApplicationServices
import CryptoKit
import DukouCore
import Foundation
import Vision

enum WeChatAutomationError: Error, LocalizedError {
    case notRunning, interfaceHidden, wrongChat, busyChat, focusChanged, historyIncomplete, historyUnconfirmed, noMessages
    case selection, loading, screenRecording, unsupportedLayout, missingShare, ambiguousReceipt, receiptTimeout, invalidArchive, timeRangeUnavailable
    case incrementNeedsBaseline, incrementUnconfirmed
    case historyLoadingTimeout, scrollStalled
    case control(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: L10n.text("请先打开并登录微信。")
        case .interfaceHidden: L10n.text("微信没有向这个账号开放界面控件，快捷转发用不了，重装或重新授权无效。请在微信里手动多选后转发到 xiaoai-archive。")
        case .wrongChat: L10n.text("没有找到唯一匹配的群聊。请先在微信中打开这个群，再重新执行。")
        case .busyChat: L10n.text("请先关闭微信的聊天记录窗口，或退出正在进行的多选、转发。")
        case .focusChanged: L10n.text("前台应用或群聊发生了变化，已停止微信操作。")
        case .historyIncomplete: L10n.text("未能读到范围起点。请缩小范围，或先在微信中加载更早的聊天记录。")
        case .historyUnconfirmed: L10n.text("历史边界无法确认。")
        case .historyLoadingTimeout: L10n.text("微信加载历史超时，已停止。已收到的文件会保留。")
        case .scrollStalled: L10n.text("微信滚动持续受限，等待恢复超时，已停止。已收到的文件会保留。")
        case .noMessages: L10n.text("这个时间范围内没有消息。")
        case .selection: L10n.text("无法准确选中这一批消息，已停止。请缩小范围后重试。")
        case .loading: L10n.text("微信消息列表尚未稳定。请等待加载完成后重试。")
        case .screenRecording: L10n.text("这个转发界面需要识别按钮位置。请在系统设置中为 xiaoai-archive 开启屏幕录制权限后重试。")
        case .unsupportedLayout: L10n.text("没有定位到“转发到其他应用”按钮，已停止。请保持微信转发窗口完整可见。")
        case .missingShare: L10n.text("没有找到「暂存到 xiaoai-archive」分享入口。请在设置的「入口」中启用它。")
        case .ambiguousReceipt: L10n.text("同时收到了多次分享，无法确认本次文件，已停止自动粘贴。")
        case .receiptTimeout: L10n.text("等待微信导出超时。已收到的文件会保留在暂存架。")
        case .invalidArchive: L10n.text("微信导出的文件为空或无法完整读取，文件已保留。")
        case .timeRangeUnavailable: L10n.text("按时间选取暂未开放，请改用条数。")
        case .incrementNeedsBaseline: L10n.text("这个群还没有归档检查点。请先完整导出一次。")
        case .incrementUnconfirmed: L10n.text("未能确认和上次归档的重叠，已停止。原始文件已保留，检查点没有更新。")
        case .control(let label): L10n.format("微信没有显示“%@”。请回到普通聊天窗口后重试。", label)
        }
    }
}

/// A worker owns all AX references. Cancelling never releases the forward
/// queue until that worker has stopped posting events and cleaned up its UI.
final class WeChatCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

private func wcAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// One cross-process read per node. Message contents stay in memory; only the
/// external-share control may use a cropped visual fallback.
private struct WCNode {
    static let keys = ["AXRole", "AXIdentifier", "AXTitle", "AXValue", "AXDescription", "AXHelp", "AXChildren", "AXPosition", "AXSize", "AXEnabled"]
    let element: AXUIElement
    let role: String, id: String
    let strings: [String]
    let value: Any?
    let children: [AXUIElement]
    let rect: CGRect
    let enabled: Bool
    let readError: AXError

    init(_ element: AXUIElement) {
        self.element = element
        var copied: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, Self.keys as CFArray, [], &copied)
        readError = error
        let values: [Any] = error == .success ? (copied as? [Any] ?? []) : Self.keys.map { wcAttribute(element, $0) ?? NSNull() }
        func get(_ index: Int) -> Any? { values.indices.contains(index) ? values[index] : nil }
        role = get(0) as? String ?? ""
        id = get(1) as? String ?? ""
        value = get(3)
        strings = [2, 3, 4, 5].compactMap { get($0) as? String }.filter { !$0.isEmpty }
        children = get(6) as? [AXUIElement] ?? []
        var point = CGPoint.zero, size = CGSize.zero
        if let p = get(7), CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &point) }
        if let s = get(8), CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        rect = CGRect(origin: point, size: size)
        enabled = get(9) as? Bool ?? true
    }
    var selected: Bool { (value as? NSNumber)?.boolValue == true }

}

struct WeChatCapture: Sendable {
    /// Newest batch first. Delivery reverses this so attached ZIPs read forward.
    let directories: [URL]
    let batchMessageCounts: [Int]
    let messageCount: Int
    let readSeconds: Double
    let captureSeconds: Double
    let selfSender: String?
    /// Exported batches are kept, and no further batch was started: the next
    /// boundary was not proved. A finished request does not set this.
    let boundaryStopped: Bool
    let stopReason: WeChatExportStopReason?
    var stoppedEarly: Bool { boundaryStopped || stopReason != nil }
    /// The walk proved it had reached the conversation's first message, so a
    /// request larger than the conversation finished with what was there.
    let reachedHistoryStart: Bool
    /// Set only for an incremental run that found a unique overlap. Nil on a
    /// ordinary export. `retained == 0` means nothing new was appended.
    let increment: WeChatIncrementCut?
}

final class WeChatAccessibility {
    static let bundleIdentifier = "com.tencent.xinWeChat"
    private let app: NSRunningApplication
    private let root: AXUIElement
    private let chat: String
    /// Top-to-bottom names from the last session-list read. Empty when this
    /// run has no trail; opening a chat then searches both directions.
    private let sessionOrder: [String]
    private let cancellation: WeChatCancellation
    private let progress: (String) -> Void
    private var ownsSelection = false
    private var cleaningUp = false
    private let clock = { ProcessInfo.processInfo.systemUptime }
    private var phase = "open"
    private var historyBoundaryLog: [String: Any] = [:]
    private var scrollCount = 0
    private var scrollSeconds = 0.0
    private var scanSeconds = 0.0
    private var scanCalls = 0
    private var stableSeconds = 0.0
    private var exportSeconds = 0.0
    /// When the last scroll gesture ended, and where the wheel was left.
    /// WeChat needs a beat between gestures or two of them coalesce into one
    /// much smaller movement; spending that beat on the snapshot the engine
    /// needs anyway is free, sleeping through it is not.
    private var lastGestureEnded = 0.0
    private var lastHover: CGPoint?
    /// What this run has learned about the list it is navigating: how far a
    /// unit of scroll moves it, and the shortest gap between gestures WeChat
    /// keeps up with. Kept for the whole run — a second batch of 100 in the
    /// same conversation should not have to feel its way again.
    private var gain = 1.5
    private var gainMeasured = false
    private var scrollPacing = WeChatScrollPacing()
    private var gesturePause: Double { scrollPacing.pause }
    private var deltaCeiling: Int32 { scrollPacing.ceiling }
    private var pacingEvents: [[String: Any]] = []
    private var prefetchExit = "notRequested"
    /// The message list, kept across stability checks. Re-found whenever it
    /// stops answering as itself.
    private var settledList: AXUIElement?
    private var checksSinceChatVerified = 0
    /// One entry per navigation step: requested units, the points the content
    /// actually moved, and how far the target still was. Local diagnostics only.
    private var steps: [[String: Any]] = []
    private var scrollsByPhase: [String: Int] = [:]
    private var clickCount = 0
    private var exportCount = 0
    private var receiptReadRetries = 0
    private var navigationKeys = 0
    private var keyboardMessages = 0
    private var rangeClicks = 0
    private var shiftRangeClicks = 0
    private var locator = ""
    private var visualMilliseconds = 0.0
    private var lastNodeCount = 0
    private var scanTruncated = false
    private var controlFailure: [String: Any]?
    private var resumedBatches = 0
    private var keyboardPins: [String: Int] = [:]
    /// What the prefetch pass cost and what it loaded, for diagnostics only.
    private var prefetchSeconds = 0.0
    private var prefetchRows = 0
    private var prefetchLoaded = 0
    private var snapshots: [[String: Any]] = []
    /// Written the moment a keyboard walk finishes its count, before the page
    /// is asked to settle. A later snapshot failure must not look like the
    /// walk never arrived.
    private var keyboardTargetReached = false
    private var keyboardTarget: WeChatFocusedMessage?
    private var keyboardTargetElement: AXUIElement?
    private var focusedMessageLog: [String: Any] = [:]
    private var snapshotRejectReason = ""
    /// Diagnostic log for the whole chat. It is not a per-batch budget:
    /// every full batch of 100 pins its endpoint on the top edge and needs
    /// its own nudges.
    private var recoveryAttempts: [[String: Any]] = []
    private var rangeControlState = ""
    private var boundaryStopped = false
    private var stopReason: WeChatExportStopReason?
    /// Accidental clicks steal the foreground or the message-list focus.
    /// A few of those are put back; a run that keeps losing the chat still stops.
    private var focusRecoveries = 0

    init(chat: String, sessionOrder: [String] = [], cancellation: WeChatCancellation, progress: @escaping (String) -> Void) throws {
        guard AXIsProcessTrusted() else { throw AutoPaste.Failure.notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first else { throw WeChatAutomationError.notRunning }
        self.app = app
        self.chat = WeChatForwardPreset.normalizedChat(chat)
        self.sessionOrder = sessionOrder.map(WeChatForwardPreset.normalizedChat)
        self.cancellation = cancellation
        self.progress = progress
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
    }

    static func currentChat() throws -> String {
        let probe = try WeChatAccessibility(chat: "", cancellation: WeChatCancellation(), progress: { _ in })
        guard let node = try probe.scan().first(where: { $0.id == "current_chat_name_label" }), let name = node.strings.first else {
            throw probe.interfaceIsHidden ? WeChatAutomationError.interfaceHidden : WeChatAutomationError.wrongChat
        }
        return WeChatForwardPreset.normalizedChat(name)
    }

    /// See `WeChatInterfaceVisibility`. A handful of reads — the windows and
    /// their first level — so the settings panes can ask before the user has
    /// filled anything in. A hidden or minimised WeChat is not judged: what Qt
    /// publishes for a window nobody can see is not evidence about the account.
    static func interfaceVisibility() -> WeChatInterfaceVisibility {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              !app.isHidden else { return .unknown }
        return interfaceVisibility(pid: app.processIdentifier)
    }

    static func interfaceVisibility(pid: pid_t) -> WeChatInterfaceVisibility {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 1)
        let windows = (wcAttribute(root, "AXWindows") as? [AXUIElement] ?? []).filter {
            (wcAttribute($0, "AXMinimized") as? Bool) != true
        }
        return .evaluate(windows.map { window in
            (wcAttribute(window, "AXChildren") as? [AXUIElement] ?? []).map {
                .init(role: wcAttribute($0, "AXRole") as? String ?? "",
                      childCount: (wcAttribute($0, "AXChildren") as? [AXUIElement])?.count ?? 0)
            }
        })
    }

    private var interfaceIsHidden: Bool { Self.interfaceVisibility(pid: app.processIdentifier) == .hidden }

    /// Opens the account pane only for HTML exports and closes only the
    /// settings window this probe created. It never touches account controls,
    /// reads a database, or keeps an identity across account switches.
    func currentAccountNickname() throws -> String? {
        try frontmost()
        let settingsTitles = ["设置", "設定", "Settings", "Preferences", "偏好设置"]
        func settingsWindows() -> [WCNode] {
            (wcAttribute(root, "AXWindows") as? [AXUIElement] ?? []).map(WCNode.init).filter {
                $0.role == "AXWindow" && $0.strings.contains(where: settingsTitles.contains)
            }
        }
        func nickname(_ window: WCNode) -> String? {
            let fields = window.children.map(WCNode.init).map {
                WeChatAccountIdentity.Field(role: $0.role, text: $0.strings.first ?? "")
            }
            return WeChatAccountIdentity.nickname(in: fields)
        }
        // An already-open settings window belongs to the user. Read it as-is;
        // never switch its tab or close it for an optional preview feature.
        let existing = settingsWindows()
        if !existing.isEmpty { return existing.count == 1 ? nickname(existing[0]) : nil }
        guard let menu = wcAttribute(root, "AXMenuBar"), CFGetTypeID(menu) == AXUIElementGetTypeID() else { return nil }
        var queue = [menu as! AXUIElement], index = 0
        var settings: WCNode?
        while index < queue.count && index < 300 {
            if index % 16 == 0 { try check() }
            let node = WCNode(queue[index]); index += 1
            if node.role == "AXMenuItem", node.enabled,
               node.strings.contains(where: settingsTitles.contains),
               wcAttribute(node.element, "AXMenuItemCmdChar") as? String == "," {
                settings = node
                break
            }
            queue.append(contentsOf: node.children)
        }
        guard let settings else { return nil }
        try frontmost()
        // The real menu item supports AXPress even while the menu is closed.
        // No keyboard shortcut can reach the conversation's draft by mistake.
        let result = AXUIElementPerformAction(settings.element, "AXPress" as CFString)
        var ownedWindow: AXUIElement?
        var closed = false
        func closeOwnedSettings() throws {
            if let ownedWindow, let window = settingsWindows().first(where: { CFEqual($0.element, ownedWindow) }) {
                guard let button = wcAttribute(window.element, "AXCloseButton"),
                      CFGetTypeID(button) == AXUIElementGetTypeID(),
                      AXUIElementPerformAction(button as! AXUIElement, "AXPress" as CFString) == .success else {
                    throw WeChatAutomationError.control("关闭设置")
                }
            }
            let deadline = clock() + 0.5
            func isOpen() -> Bool { ownedWindow.map { owned in settingsWindows().contains { CFEqual($0.element, owned) } } ?? false }
            while isOpen(), clock() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            guard !isOpen() else { throw WeChatAutomationError.control("关闭设置") }
            closed = true
            settledList = nil
        }
        defer { if !closed { try? closeOwnedSettings() } }
        var value: String?
        if result == .success || result == .cannotComplete {
            let deadline = clock() + 1
            var window: WCNode?
            repeat {
                let found = settingsWindows()
                if found.count == 1 { window = found[0]; ownedWindow = found[0].element; break }
                // A menu action may already have opened a window when ESC or
                // a focus change arrives. Bind its cleanup target before
                // propagating cancellation; this wait is bounded to one second.
                Thread.sleep(forTimeInterval: 0.02)
            } while clock() < deadline
            try frontmost()
            if let window {
                value = nickname(window)
                if value == nil {
                    let accountTabs = ["账号与存储", "帳號與儲存空間", "Account & Storage", "Account and Storage"]
                    if settingsWindows().contains(where: { CFEqual($0.element, window.element) }),
                       let tab = WCNode(window.element).children.map(WCNode.init).first(where: {
                        $0.role == "AXButton" && $0.strings.contains(where: accountTabs.contains)
                    }), AXUIElementPerformAction(tab.element, "AXPress" as CFString) == .success {
                        // No coordinate fallback for this optional probe: an
                        // unsupported tab leaves identity unknown.
                        let deadline = clock() + 0.6
                        repeat {
                            try frontmost()
                            value = nickname(WCNode(window.element))
                            if value != nil { break }
                            try pause(0.02)
                        } while clock() < deadline
                    }
                }
            }
        }
        try closeOwnedSettings()
        try verifyChat()
        return value
    }

    private func check() throws { if !cleaningUp { try cancellation.check() } }
    private func pause(_ seconds: Double = 0.06) throws {
        try check()
        Thread.sleep(forTimeInterval: seconds)
        try check()
    }
    private func scan() throws -> [WCNode] {
        let started = clock()
        defer { scanSeconds += clock() - started; scanCalls += 1 }
        var queue = [root], index = 0, nodes: [WCNode] = []
        while index < queue.count && nodes.count < 2000 {
            if index % 32 == 0 { try check() }
            let node = WCNode(queue[index]); index += 1
            nodes.append(node)
            // Controls are outside the virtualised message subtree. Reading
            // hundreds of empty cells cannot help locate a toolbar or menu.
            if node.role != "AXMenuBar", node.id != "chat_message_list" { queue.append(contentsOf: node.children) }
        }
        lastNodeCount = nodes.count
        // A tree larger than the walk would mean the control being looked for
        // may simply never have been visited.
        scanTruncated = nodes.count >= 2000
        return nodes
    }
    private func matches(_ name: String) -> Bool { WeChatForwardPreset.normalizedChat(name) == chat }
    private func chatMatches(_ nodes: [WCNode]) -> Bool {
        nodes.contains { $0.id == "current_chat_name_label" && $0.strings.contains(where: matches) }
    }
    private var weChatIsFront: Bool {
        !app.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }
    private func frontmost() throws {
        try check()
        guard !app.isTerminated else { throw WeChatAutomationError.notRunning }
        if weChatIsFront { return }
        try recoverForeground()
    }
    private func verifyChat() throws {
        try frontmost()
        if chatMatches(try scan()) { return }
        // One reading can land between window animations. A second miss is a
        // click on another session, which this puts back.
        try pause(0.15)
        try frontmost()
        if chatMatches(try scan()) { return }
        try recoverOpenChat()
    }
    /// Bring WeChat forward again after a bump moved the cursor onto another app.
    private func recoverForeground() throws {
        guard focusRecoveries < 8 else { throw WeChatAutomationError.focusChanged }
        focusRecoveries += 1
        steps.append(["kind": "focus-recover", "reason": "foreground", "attempt": focusRecoveries])
        try activate()
        let deadline = clock() + 1.5
        while clock() < deadline {
            try check()
            if weChatIsFront { return }
            try pause(0.05)
        }
        throw WeChatAutomationError.focusChanged
    }
    /// The open conversation changed. Return to the one this run is exporting.
    private func recoverOpenChat() throws {
        guard focusRecoveries < 8 else { throw WeChatAutomationError.focusChanged }
        focusRecoveries += 1
        steps.append(["kind": "focus-recover", "reason": "chat", "attempt": focusRecoveries])
        let nodes = try scan()
        if nodes.contains(where: { $0.id == "cancel_btn" }) { throw WeChatAutomationError.focusChanged }
        let row = try revealSessionRow(in: nodes)
        try press(row)
        settledList = nil
        let deadline = clock() + 2
        while clock() < deadline {
            try check()
            if chatMatches(try scan()) { return }
            try pause(0.05)
        }
        throw WeChatAutomationError.focusChanged
    }
    private func click(_ point: CGPoint, right: Bool = false, modifiers: CGEventFlags = []) throws {
        try frontmost()
        let source = CGEventSource(stateID: .privateState)
        let button: CGMouseButton = right ? .right : .left
        guard let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: button) else { throw AutoPaste.Failure.eventCreationFailed }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.flags = modifiers; up.flags = modifiers
        clickCount += 1
        lastHover = nil
        settledList = nil
        down.post(tap: .cghidEventTap)
        // Always release a posted button, including when cancellation arrives.
        Thread.sleep(forTimeInterval: 0.025)
        up.post(tap: .cghidEventTap)
        try pause()
    }
    private func press(_ node: WCNode) throws {
        try frontmost()
        guard node.enabled else { throw WeChatAutomationError.selection }
        var copied: CFArray?
        AXUIElementCopyActionNames(node.element, &copied)
        if (copied as? [String] ?? []).contains("AXPress") {
            let result = AXUIElementPerformAction(node.element, "AXPress" as CFString)
            if result == .success { try pause(); return }
            // An unacknowledged action may already have happened. Only an
            // explicitly unsupported action permits a synthetic fallback.
            guard result == .actionUnsupported || result == .notImplemented else { throw WeChatAutomationError.selection }
        }
        guard !node.rect.isEmpty else { throw WeChatAutomationError.selection }
        try click(CGPoint(x: node.rect.midX, y: node.rect.midY))
    }
    private func control(_ label: String, in nodes: [WCNode]) -> WCNode? {
        nodes.first { node in
            ["AXButton", "AXMenuItem", "AXStaticText"].contains(node.role) && node.enabled && !node.rect.isEmpty &&
            node.strings.contains { $0 == label || $0 == label + "…" || $0 == label + "..." }
        }
    }

    /// The same control, found without assuming what kind of thing it is.
    ///
    /// `control` asks for one of the three roles WeChat's own buttons have
    /// answered as. A build that dresses the same row as something else — a
    /// cell, a group, a plain image with a label — puts it out of reach while
    /// it sits on screen, pressable, in front of the user; 选择电脑中的应用 on
    /// macOS 26 is that report. So the fallback drops the role entirely and
    /// keeps only what makes a control a control: enabled, on screen, and
    /// carrying this exact text once spacing is ignored.
    ///
    /// It must also be the only such thing in the tree. Labels like 取消 repeat
    /// across a sheet and its parent window, and pressing the wrong one is
    /// worse than reporting that this could not be found.
    private func looseControl(_ label: String, in nodes: [WCNode]) -> WCNode? {
        let wanted = label.filter { !$0.isWhitespace }
        let matches = nodes.filter { node in
            node.enabled && !node.rect.isEmpty && node.role != "AXWindow" &&
            node.strings.contains { $0.filter { !$0.isWhitespace } == wanted }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func waitControl(_ label: String, timeout: Double = 2, settled: Bool = false) throws -> WCNode {
        let deadline = clock() + timeout
        var relaxed: WCNode?
        var previous: WCNode?
        repeat {
            try frontmost()
            let nodes = try scan()
            guard chatMatches(nodes) else { throw WeChatAutomationError.focusChanged }
            if let node = control(label, in: nodes) {
                if !settled || previous.map({ CFEqual($0.element, node.element) && $0.rect == node.rect }) == true { return node }
                previous = node
            } else { previous = nil }
            // Kept, not taken: the strict match may still be a frame away, and
            // it is the one that has been verified against this UI.
            relaxed = looseControl(label, in: nodes)
            try pause(0.02)
        } while clock() < deadline
        if !settled, let relaxed {
            locator = locator.isEmpty ? "loose-control" : locator + "+loose-control"
            return relaxed
        }
        recordControlFailure(label)
        throw WeChatAutomationError.control(label)
    }

    /// What was on screen when a control could not be found.
    ///
    /// A layout that moves under a new macOS or WeChat build cannot be taught
    /// in advance, and whoever hits it first is not holding a debugger. One
    /// reproduction now leaves behind the role, label and geometry of
    /// everything that was pressable, which is what a fix is made from.
    ///
    /// Message bodies, conversation names and the placeholder cells behind them
    /// are left out: this is a report about controls, and it is a file the user
    /// may well send someone.
    private func recordControlFailure(_ label: String) {
        let nodes = (try? scan()) ?? []
        controlFailure = [
            "label": label,
            "nodeCount": lastNodeCount,
            "scanTruncated": scanTruncated,
            "candidates": nodes.filter {
                // AXCheckBox is a person in the recipient list or a message in
                // the transcript — never a control this searches for, and both
                // carry names this file should not.
                $0.enabled && !$0.rect.isEmpty && $0.role != "AXCheckBox" && $0.role != "AXWindow" &&
                $0.id != "chat_bubble_item_view" && $0.id != "virtual_cell" && !$0.id.hasPrefix("session_item_")
            }.prefix(80).map { node -> [String: Any] in
                ["role": node.role, "id": node.id, "strings": node.strings.map { String($0.prefix(24)) },
                 "rect": [Int(node.rect.minX), Int(node.rect.minY), Int(node.rect.width), Int(node.rect.height)]]
            },
        ]
    }
    private func scroll(_ list: AXUIElement, delta: Int32, settle: Double = WeChatScrollStep.baseGesturePause) throws {
        let started = clock()
        defer { scrollSeconds += clock() - started }
        try frontmost()
        let rect = WCNode(list).rect
        guard !rect.isEmpty else { throw WeChatAutomationError.selection }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let source = CGEventSource(stateID: .privateState)
        // Whatever is left of the gap between gestures, minus everything the
        // caller already spent looking at the result of the last one.
        let remaining = settle - (clock() - lastGestureEnded)
        if remaining > 0 { try pause(remaining) }
        // The wheel is already over this list unless something else moved it.
        if lastHover != point {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            lastHover = point
            try pause(0.025)
        }
        try frontmost()
        func event(_ phase: CGScrollPhase, _ amount: Int32) -> CGEvent? {
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
            event?.location = point
            event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return event
        }
        guard let began = event(.began, 0), let changed = event(.changed, delta), let ended = event(.ended, 0) else { throw AutoPaste.Failure.eventCreationFailed }
        // Without gesture phases this WeChat build turns even a 1-unit wheel
        // event into a ~298-point jump. Gesture scrolls retain fine movement.
        began.post(tap: .cghidEventTap)
        do {
            try frontmost()
            scrollCount += 1
            scrollsByPhase[phase, default: 0] += 1
            changed.post(tap: .cghidEventTap)
        } catch { ended.post(tap: .cghidEventTap); throw error }
        ended.post(tap: .cghidEventTap)
        lastGestureEnded = clock()
    }

    /// Where keyboard focus sits relative to the message list.
    ///
    /// Join notices and message text are often an inner element, not the list
    /// child itself. Treating that inner element as a different chat aborts a
    /// batch that is still inside this conversation.
    private enum ListFocus {
        case row(WCNode)
        case unsettled
        case outside
    }

    private func listFocus(_ focus: WCNode, list: AXUIElement) -> ListFocus {
        if focus.id == "chat_input_field" { return .outside }
        if CFEqual(focus.element, list) || focus.id == "chat_message_list" || focus.id == "virtual_cell" {
            return .unsettled
        }
        if let children = wcAttribute(list, "AXChildren") as? [AXUIElement],
           children.contains(where: { CFEqual($0, focus.element) }) {
            return focus.rect.isEmpty ? .unsettled : .row(focus)
        }
        var current = focus.element
        for _ in 0..<12 {
            guard let parent = wcAttribute(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return .outside }
            let parentElement = parent as! AXUIElement
            let parentID = wcAttribute(parentElement, "AXIdentifier") as? String ?? ""
            if parentID == "chat_input_field" { return .outside }
            if CFEqual(parentElement, list) || parentID == "chat_message_list" {
                if parentID == "chat_message_list" { settledList = parentElement }
                let node = WCNode(current)
                guard node.readError == .success else { return .unsettled }
                if node.id == "virtual_cell" || node.rect.isEmpty { return .unsettled }
                return .row(node)
            }
            current = parentElement
        }
        return .outside
    }

    /// Qt's list has native Home/End and row-by-row keyboard navigation.
    /// These events go to this process, after verifying the list owns focus;
    /// they must never reach a draft in the composer.
    private func focusList(_ page: Page) throws -> Bool {
        try verifyChat()
        guard AXUIElementSetAttributeValue(page.list.element, "AXFocused" as CFString, kCFBooleanTrue) == .success else { return false }
        let deadline = clock() + 0.3
        repeat {
            if let focused = focusedNode(), CFEqual(focused.element, page.list.element) || page.list.children.contains(where: { CFEqual($0, focused.element) }) { return true }
            try pause(0.002)
        } while clock() < deadline
        return false
    }

    private func focusedNode() -> WCNode? {
        guard let value = wcAttribute(root, "AXFocusedUIElement"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let node = WCNode(value as! AXUIElement)
        return node.readError == .success ? node : nil
    }

    /// A bump can leave the caret in the composer. The chat is unchanged, so
    /// the walk continues once the message list has focus again.
    private func ensureListFocus() throws {
        guard let list = settledList else { throw WeChatAutomationError.focusChanged }
        if let focused = focusedNode(), case .outside = listFocus(focused, list: list) {
            try refocusMessageList(list)
        } else if focusedNode() == nil {
            try refocusMessageList(list)
        }
    }

    private func refocusMessageList(_ list: AXUIElement) throws {
        guard focusRecoveries < 8 else { throw WeChatAutomationError.focusChanged }
        focusRecoveries += 1
        steps.append(["kind": "focus-recover", "reason": "list", "attempt": focusRecoveries])
        try verifyChat()
        _ = AXUIElementSetAttributeValue(list, "AXFocused" as CFString, kCFBooleanTrue)
        let deadline = clock() + 0.4
        while clock() < deadline {
            try check()
            if let focused = focusedNode() {
                if case .outside = listFocus(focused, list: list) {
                    try pause(0.02)
                    continue
                }
                return
            }
            try pause(0.02)
        }
        historyBoundaryLog = ["stage": "focus", "reason": "outsideList"]
        throw WeChatAutomationError.focusChanged
    }

    private func navigationKey(_ code: CGKeyCode) throws {
        try frontmost()
        try ensureListFocus()
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw AutoPaste.Failure.eventCreationFailed }
        down.flags = []; up.flags = []
        down.postToPid(app.processIdentifier)
        // A posted key is always released, including on cancellation.
        up.postToPid(app.processIdentifier)
        navigationKeys += 1
    }

    /// Brings WeChat forward from this worker thread.
    ///
    /// Same finding as `AutoPaste.bringToFront`: on macOS 14+
    /// `NSRunningApplication.activate(options:)` is ignored when the caller is
    /// not the frontmost app, and it never restores a minimized window.
    /// Measured from a background process (2026-09-06), only the LaunchServices
    /// door changed the foreground and un-minimized. The completion-handler
    /// form is used because this engine is synchronous and runs on
    /// `WeChatQuickForward.worker` — the semaphore is waited on there, never on
    /// the main thread, which is where the completion may be delivered.
    private func activate() throws {
        try check()
        guard let url = app.bundleURL else { throw WeChatAutomationError.notRunning }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in opened.signal() }
        // Capped rather than trusted: the frontmost poll below is the real
        // check, and a LaunchServices call that never calls back must not hang
        // a forward the user can no longer cancel.
        _ = opened.wait(timeout: .now() + 3)
        AutoPaste.restoreWindows(pid: app.processIdentifier)
    }

    private func openChat() throws {
        try check()
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        try activate()
        let deadline = clock() + 3
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier && clock() < deadline { try pause(0.04) }
        try frontmost()
        if !wasFrontmost { try pause(0.15) }
        // Before anything is looked for: an account WeChat shows no controls
        // for fails every search below, and 「没有找到群聊」 would send the user
        // off to fix a name that was never the problem.
        guard !interfaceIsHidden else { throw WeChatAutomationError.interfaceHidden }
        let nodes = try scan()
        guard !nodes.contains(where: { $0.id == "chat_log_message_list" || $0.id == "cancel_btn" }), control("合并转发", in: nodes) == nil else { throw WeChatAutomationError.busyChat }
        if chatMatches(nodes) { return }
        let node = try revealSessionRow(in: nodes)
        try press(node)
        let opened = clock() + 2
        repeat {
            if chatMatches(try scan()) { return }
            try pause()
        } while clock() < opened
        throw WeChatAutomationError.wrongChat
    }

    /// The session list only exposes the rows on screen. Scroll it, using the
    /// saved top-to-bottom order when this run has one, until the named row
    /// is visible. Both ends stopping without that row is a real miss.
    private func revealSessionRow(in initial: [WCNode]) throws -> WCNode {
        let found = sessionMatches(in: initial)
        if found.count == 1 { return found[0] }
        if found.count > 1 { throw WeChatAutomationError.wrongChat }
        guard let list = initial.first(where: { $0.id == "session_list" && !$0.rect.isEmpty }) else {
            throw WeChatAutomationError.wrongChat
        }
        progress(L10n.text("正在滚动会话列表寻找群聊…"))
        let step = Int32(min(220, max(130, list.rect.height * 0.3)).rounded())
        var delta = sessionScrollDelta(visible: sessionNames(in: initial), step: step)
        var previous = sessionNames(in: initial)
        var idle = 0
        var termini = 0
        var currentList = list.element
        for _ in 0..<80 {
            try check()
            try scroll(currentList, delta: delta, settle: 0.02)
            try pause(0.08)
            let nodes = try scan()
            let matches = sessionMatches(in: nodes)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw WeChatAutomationError.wrongChat }
            if let refreshed = nodes.first(where: { $0.id == "session_list" && !$0.rect.isEmpty }) {
                currentList = refreshed.element
            }
            let page = sessionNames(in: nodes)
            if page == previous {
                idle += 1
                if idle >= 2 {
                    termini += 1
                    if termini >= 2 { break }
                    delta = -delta
                    idle = 0
                }
            } else {
                idle = 0
                previous = page
            }
        }
        throw WeChatAutomationError.wrongChat
    }

    private func sessionMatches(in nodes: [WCNode]) -> [WCNode] {
        sessionRows(in: nodes).filter { node in
            matches(String(node.id.dropFirst("session_item_".count))) || node.strings.contains {
                matches($0.components(separatedBy: "\n").first ?? "") || matches($0.components(separatedBy: ",").first ?? "")
            }
        }
    }

    private func sessionRows(in nodes: [WCNode]) -> [WCNode] {
        nodes.filter { $0.id.hasPrefix("session_item_") && !$0.rect.isEmpty }
    }

    private func sessionNames(in nodes: [WCNode]) -> [String] {
        sessionRows(in: nodes).map { String($0.id.dropFirst("session_item_".count)) }
    }

    /// Positive scrolls toward the top. Without a saved order, start that way:
    /// a list left at the bottom is the case that hides the earlier groups.
    private func sessionScrollDelta(visible: [String], step: Int32) -> Int32 {
        guard let target = sessionOrder.firstIndex(of: chat) else { return step }
        let indexes = visible.compactMap { sessionOrder.firstIndex(of: WeChatForwardPreset.normalizedChat($0)) }
        guard let anchor = indexes.min(by: { abs($0 - target) < abs($1 - target) }), anchor != target else { return step }
        return anchor > target ? step : -step
    }

    private struct Page {
        let list: WCNode
        let rows: [WCNode]
        var signature: String {
            // New messages can change the off-screen child count while this
            // history viewport stays still. Only visible rows need to settle.
            "\(list.rect):" + rows.map { "\($0.role):\($0.rect):\($0.selected):\($0.strings)" }.joined(separator: "|")
        }
        func canCheck(_ row: WCNode) -> Bool {
            list.rect.insetBy(dx: 0, dy: 5).contains(CGPoint(x: row.rect.minX + 22, y: row.rect.midY))
        }
        var data: [WeChatViewportRow] {
            rows.map { WeChatViewportRow(text: $0.strings.first ?? "", y: $0.rect.minY, height: $0.rect.height) }
        }
    }

    private struct ListSample {
        let list: WCNode
        let rows: [WCNode]
        let reject: WeChatSnapshotReject?
    }

    /// Require two equal materialized snapshots. An empty/loading AX page is
    /// retried; it is never interpreted as a changed conversation or its end.
    /// A timeout records why the last frame was refused. That reason is not
    /// cleared by a later success: the walk may already have reached its target.
    private func stablePage(timeout: Double = 3) throws -> Page {
        let started = clock()
        defer { stableSeconds += clock() - started; checksSinceChatVerified += 1 }
        let deadline = clock() + timeout
        var previous: String?
        // Walking WeChat's whole tree is most of what a navigation step costs,
        // and a step only needs to know whether the list has come to rest — the
        // list answers that itself. The walk is kept for the case where the
        // cached list stops answering, and for one check in eight of the
        // conversation's identity. Content is not left to that check: every
        // step also re-matches the rows it already knew through
        // `WeChatViewport`, which no other conversation can satisfy.
        var verifiedHere = false
        var lastReject: WeChatSnapshotReject?
        repeat {
            try frontmost()
            if let sample = try sampleList(verifiedHere: &verifiedHere) {
                if let reject = sample.reject {
                    lastReject = reject
                    previous = nil
                    settledList = nil
                } else {
                    let page = Page(list: sample.list, rows: sample.rows)
                    if page.signature == previous { return page }
                    previous = page.signature
                    lastReject = .pageChanged
                }
            } else {
                lastReject = .listMissing
                previous = nil
                settledList = nil
            }
            // The list settles on its own; this only paces the next look.
            try pause(0.02)
        } while clock() < deadline
        if let lastReject {
            if snapshotRejectReason.isEmpty { snapshotRejectReason = lastReject.rawValue }
            steps.append(["kind": "snapshot-rejected", "reason": lastReject.rawValue, "phase": phase])
        }
        throw WeChatAutomationError.loading
    }

    /// One reading of the visible bubbles. Calling it twice is what `stablePage`
    /// does; a caller that already holds the keyboard row may use one reading
    /// when the second will not match, and must not treat that as the batch boundary.
    private func readablePage() throws -> Page? {
        var verifiedHere = false
        guard let sample = try sampleList(verifiedHere: &verifiedHere) else { return nil }
        if sample.reject == nil { return Page(list: sample.list, rows: sample.rows) }
        // Another bubble's missing text does not move the focused row. Drop
        // those bubbles. Overlap and a failed read do not leave a geometry
        // that can be nudged safely.
        guard sample.reject == .emptyText else { return nil }
        let usable = sample.rows.filter { $0.readError == .success && !$0.strings.isEmpty }
        guard !usable.isEmpty, zip(usable, usable.dropFirst()).allSatisfy({ $0.rect.minY < $1.rect.minY }) else { return nil }
        return Page(list: sample.list, rows: usable)
    }

    /// A settled read when the list will give one, otherwise a single reading.
    /// Nil only when the list itself cannot be read. `settled` is false for
    /// that single reading: it can place the focused row, not the next batch.
    private func probedPage() throws -> (page: Page, settled: Bool)? {
        do { return (try stablePage(timeout: 3), true) }
        catch WeChatAutomationError.loading {
            guard let page = try readablePage() else { return nil }
            return (page, false)
        }
    }

    private func sampleList(verifiedHere: inout Bool) throws -> ListSample? {
        var found: WCNode?
        if let settledList, checksSinceChatVerified < 8 || verifiedHere {
            let node = WCNode(settledList)
            if node.readError == .success, node.id == "chat_message_list" { found = node }
        }
        if found == nil {
            let nodes = try scan()
            guard chatMatches(nodes) else { throw WeChatAutomationError.focusChanged }
            found = nodes.first { $0.id == "chat_message_list" }
            settledList = found?.element
            checksSinceChatVerified = 0
            verifiedHere = true
        }
        guard let list = found, list.readError == .success else { return nil }
        let rows = materializedBubbles(list)
        let reject = WeChatPageSample.reject(listFound: true, rows: rows.map {
            WeChatVisibleSample(readOK: $0.readError == .success, textEmpty: $0.strings.isEmpty, y: $0.rect.minY)
        })
        return ListSample(list: list, rows: rows, reject: reject)
    }

    /// WeChat exposes an empty virtual_cell prefix, followed by materialised
    /// rows ending at the viewport's bottom. Walk that suffix, not every
    /// previously loaded placeholder. The general reader stays for a version
    /// with virtual cells after, or among, its materialised children.
    private func materializedBubbles(_ list: WCNode) -> [WCNode] {
        var materialized: [WCNode] = []
        for child in list.children.reversed() {
            let node = WCNode(child)
            if node.id == "virtual_cell", node.rect.isEmpty { break }
            materialized.append(node)
        }
        var rows = materialized.reversed().filter {
            $0.id == "chat_bubble_item_view" && !$0.rect.intersection(list.rect).isNull
        }
        if rows.isEmpty {
            rows = list.children.map(WCNode.init).filter {
                $0.id == "chat_bubble_item_view" && !$0.rect.intersection(list.rect).isNull
            }
        }
        return rows
    }

    private func focusMessage(_ node: WCNode, ordinal: Int) -> WeChatFocusedMessage {
        WeChatFocusedMessage(identifier: node.id, role: node.role, texts: node.strings, y: node.rect.minY, height: node.rect.height, selected: node.selected, ordinal: ordinal)
    }

    private func textHash(_ strings: [String]) -> String {
        SHA256.hash(data: Data(strings.joined(separator: "\u{1e}").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Record the counted target before asking the page to settle. The hash is
    /// the only copy of the text that leaves this process.
    private func noteKeyboardTarget(_ node: WCNode, count: Int, keys: Int) {
        let ordinal = count - 1
        keyboardTarget = focusMessage(node, ordinal: ordinal)
        keyboardTargetElement = node.element
        keyboardTargetReached = true
        keyboardMessages += count
        let hash = textHash(node.strings)
        focusedMessageLog = ["id": node.id, "role": node.role, "hash": hash, "y": Double(node.rect.minY), "height": Double(node.rect.height), "selected": node.selected, "ordinal": ordinal]
        steps.append(["kind": "keyboard-target", "messages": count, "keys": keys, "hash": hash, "y": Double(node.rect.minY), "height": Double(node.rect.height), "selected": node.selected, "ordinal": ordinal])
    }

    /// The focused bubble, read more than once. The first read may sit at a new
    /// position: the page was given time to settle and Qt may have aligned the
    /// row. A recycled cell that kept the pointer has different text and is
    /// refused. A new pointer is the same message only when it is still on the
    /// spot the walk left. Later reads have to hold still; other rows may change.
    private func repeatedFocus(_ target: WeChatFocusedMessage, element: AXUIElement, samples: Int) throws -> WCNode? {
        var accepted = element
        var baseline: WeChatFocusedMessage?
        var last: WCNode?
        for index in 0..<samples {
            try verifyChat()
            guard let node = focusedNode() else { return nil }
            let current = focusMessage(node, ordinal: target.ordinal)
            if let baseline {
                let verdict = WeChatFocusHold.judge(current: current, target: baseline, elementMatches: CFEqual(node.element, accepted), expectedShift: 0, slack: 4)
                guard verdict == .held else { return nil }
            } else {
                guard WeChatFocusHold.identifies(current, as: target) else { return nil }
                let samePointer = CFEqual(node.element, element)
                if !samePointer, abs(current.y - target.y) > 24 { return nil }
            }
            accepted = node.element
            baseline = current
            last = node
            if index + 1 < samples { try pause(0.02) }
        }
        return last
    }

    /// Scroll the viewport toward older messages without sending an arrow key.
    /// A focus that lands on a different bubble — including another copy of the
    /// same text — stops the nudge. The caller must not then press Down to
    /// hunt for the row it lost. `attempt` is this batch's count, not the
    /// chat's: an ignored gesture asks for a larger clearance next time.
    private func nudgeOlder(from current: WCNode, ordinal: Int, list: WCNode, forced: Bool, attempt: Int = 0) throws -> WCNode? {
        let base = WeChatFocusClearance.olderNudge(rowY: current.rect.minY, listTop: list.rect.minY) ?? (forced ? WeChatFocusClearance.capNudge : nil)
        guard let base else { return current }
        let points = WeChatNudge.retryPoints(base: base, attempt: attempt)
        let units = WeChatNudge.units(points: points, gain: gain)
        let target = focusMessage(current, ordinal: ordinal)
        try scroll(list.element, delta: units, settle: gesturePause)
        // The ended phase returns before Qt redraws. Judging the old frame
        // reports every nudge as unmoved and spends the batch's budget on a
        // gesture that had not happened yet.
        guard let now = try focusAfterNudge(from: current) else {
            noteNudge(attempt: attempt, points: points, units: units, held: false, verdict: "missing", shift: nil)
            return nil
        }
        let shift = Double(now.rect.minY - current.rect.minY)
        let verdict = WeChatFocusHold.judge(current: focusMessage(now, ordinal: ordinal), target: target, elementMatches: CFEqual(now.element, current.element), expectedShift: points, slack: max(8, points * 0.6))
        let held = verdict == .held || verdict == .unmoved
        noteNudge(attempt: attempt, points: points, units: units, held: held, verdict: "\(verdict)", shift: shift)
        guard held else { return nil }
        if verdict == .held, units != 0 {
            let measured = shift / Double(units)
            if WeChatScrollStep.isPlausible(gain: measured) { gain = measured; gainMeasured = true }
        }
        return now
    }

    /// The focused row after a gesture scroll, once its vertical position has
    /// changed or a short wait shows that WeChat ignored the gesture.
    private func focusAfterNudge(from current: WCNode) throws -> WCNode? {
        let deadline = clock() + 0.45
        var last: WCNode?
        while true {
            guard let node = focusedNode() else { return last }
            last = node
            if abs(Double(node.rect.minY - current.rect.minY)) > 1 { return node }
            guard clock() < deadline else { return node }
            try pause(0.02)
        }
    }

    private func noteNudge(attempt: Int, points: Double, units: Int32, held: Bool, verdict: String, shift: Double?) {
        var entry: [String: Any] = [
            "attempt": recoveryAttempts.count + 1,
            "batch": exportCount + 1,
            "batchAttempt": attempt + 1,
            "phase": phase,
            "points": points,
            "units": Int(units),
            "held": held,
            "verdict": verdict,
        ]
        if let shift { entry["shift"] = shift }
        recoveryAttempts.append(entry)
    }

    /// Pointer equality is not enough: a recycled cell keeps the pointer and
    /// changes its text. Two bubbles with the same text are accepted only when
    /// one of them is unambiguously the focused row.
    private func indexOfFocus(_ node: WCNode, in page: Page) -> Int? {
        let current = focusMessage(node, ordinal: keyboardTarget?.ordinal ?? 0)
        let matches = page.rows.indices.filter {
            WeChatFocusHold.identifies(focusMessage(page.rows[$0], ordinal: current.ordinal), as: current)
        }
        if let exact = matches.first(where: { CFEqual(page.rows[$0].element, node.element) }) { return exact }
        let near = matches.filter { abs(page.rows[$0].rect.minY - node.rect.minY) < 8 }
        return near.count == 1 ? near[0] : nil
    }

    private func noteRangeControl(_ node: WCNode?) {
        rangeControlState = WeChatRangeControlLabel.parse(node?.strings ?? []).rawValue
    }

    private func checkedMessage(_ node: WCNode) throws -> String {
        guard node.role == "AXCheckBox", let label = node.strings.first else { throw WeChatAutomationError.selection }
        return label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginSelection(at index: Int, in initialPage: Page) throws -> (String, Page) {
        phase = "select-anchor-menu"
        guard initialPage.rows.indices.contains(index) else { throw WeChatAutomationError.selection }
        var page = initialPage
        var tracked = WeChatViewport(rows: page.data, anchorIndex: index)
        var failure: Error = WeChatAutomationError.selection
        // A menu can appear without its click taking effect immediately after
        // scrolling. Retry the whole transition, not just finding the label.
        // Both sides get another chance, using the current boundary geometry.
        for attempt in 0..<4 {
            if attempt > 0 {
                try verifyChat()
                if ownsSelection { try restoreSelection() }
                page = try stablePage()
                do { try tracked.resume(page.data) } catch { throw WeChatAutomationError.selection }
            }
            guard let current = tracked.index(of: 0), page.rows.indices.contains(current) else { throw WeChatAutomationError.selection }
            let node = page.rows[current], viewport = page.list.rect
            // Stay in the main body, above a quoted-message preview.
            let y = node.rect.minY + min(50, node.rect.height / 2)
            guard y > viewport.minY + 4, y < viewport.maxY - 4 else { throw WeChatAutomationError.selection }
            let inset = min(85, node.rect.width / 2)
            let x = attempt.isMultiple(of: 2) ? node.rect.minX + inset : node.rect.maxX - inset
            do {
                try click(CGPoint(x: x, y: y), right: true)
                let multi = try waitControl("多选", timeout: 0.5, settled: true)
                steps.append(["kind": "selection-menu", "attempt": attempt + 1, "rowY": node.rect.minY,
                              "menuY": multi.rect.minY, "menuX": multi.rect.minX])
                // Qt's menu items expose no AXPress. Their popup coordinates
                // must have settled before the synthetic click is posted.
                ownsSelection = true
                try press(multi)
                _ = try waitControl("合并转发", timeout: attempt == 3 ? 2 : 0.5)
                let selectedPage = try stablePage()
                let selected = selectedPage.rows.filter(\.selected)
                guard selected.count == 1, let first = selected.first,
                      node.strings.contains(where: { normal in first.strings.contains { $0 == normal || $0.hasSuffix(" " + normal) } }) else {
                    throw WeChatAutomationError.selection
                }
                observe("anchor-selected", selectedPage)
                return (try checkedMessage(first), selectedPage)
            }
            catch is CancellationError { throw CancellationError() }
            catch let error as WeChatAutomationError {
                switch error {
                case .control, .selection: failure = error
                default: throw error
                }
            }
        }
        throw failure
    }

    private struct Selection {
        let count: Int
        let checkpoint: Checkpoint
        /// This batch ended on the conversation's first message: there is
        /// nothing older to select, and a caller walking the whole
        /// conversation is done.
        let reachedConversationTop: Bool
        /// Two identical page snapshots proved the endpoint, so another batch
        /// may resume from the checkpoint. A focus-only proof still exports
        /// this batch, then stops.
        let boundaryConfirmed: Bool
    }
    private struct Checkpoint {
        let viewport: WeChatViewport
        let window: AXUIElement
        let windowRect: CGRect
        /// The ordinal the keyboard row was left on, when this batch walked there.
        let keyboardOrdinal: Int?
    }
    private enum SelectionStart { case latest, resume(Checkpoint, ordinal: Int) }

    /// Every navigation stage is bounded in both time and input events. A
    /// repeated viewport also catches oscillation across two different pages.
    private struct NavigationBudget {
        let deadline: Double
        let maximumSteps: Int
        var steps = 0
        var visits: [String: Int] = [:]
        /// A degraded short-conversation endpoint returns to the page the
        /// stall was measured on, which the visit cap would otherwise read
        /// as oscillation. Set for that one re-entry only.
        var forgivesRepeat = false
        mutating func observe(_ page: Page) throws {
            steps += 1
            visits[page.signature, default: 0] += 1
            let repeatViolation = visits[page.signature, default: 0] > 3
            if forgivesRepeat && repeatViolation { forgivesRepeat = false }
            else if repeatViolation { throw WeChatAutomationError.selection }
            guard ProcessInfo.processInfo.systemUptime < deadline, steps <= maximumSteps else { throw WeChatAutomationError.selection }
        }
    }

    private func window(of page: Page) throws -> WCNode {
        // WeChat's list does not expose AXWindow; its AXParent chain does.
        var current = page.list.element
        for _ in 0..<20 {
            let node = WCNode(current)
            if node.role == "AXWindow" { return node }
            guard let parent = wcAttribute(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        throw WeChatAutomationError.selection
    }

    private func checkpoint(_ tracked: WeChatViewport, page: Page, keyboardOrdinal: Int? = nil) throws -> Checkpoint {
        let owner = try window(of: page)
        return Checkpoint(viewport: tracked, window: owner.element, windowRect: owner.rect, keyboardOrdinal: keyboardOrdinal)
    }

    /// Rebinds `tracked` by the keyboard row sitting on `ordinal`. A wheel
    /// scroll and a share sheet both leave that row where it was, and unlike a
    /// label it tells one photo from the next. False when the row is off screen
    /// or the shared rows contradict it; the caller then matches content.
    private func pinKeyboardRow(_ tracked: inout WeChatViewport, page: Page, ordinal: Int?, afterLeavingSelection: Bool = false) -> Bool {
        guard let ordinal, let focused = focusedNode(), focused.id == "chat_bubble_item_view",
              let index = page.rows.firstIndex(where: { CFEqual($0.element, focused.element) && $0.strings == focused.strings }) else { return false }
        do { try tracked.pin(page.data, index: index, ordinal: ordinal, afterLeavingSelection: afterLeavingSelection) } catch { return false }
        keyboardPins[phase, default: 0] += 1
        return true
    }

    private func observe(_ label: String, _ page: Page) {
        snapshots.append(["stage": label, "firstY": page.list.rect.minY, "height": page.list.rect.height,
            "rows": page.rows.map { row -> [String: Any] in
                let hash = SHA256.hash(data: Data((row.strings.first ?? "").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                return ["hash": hash, "y": row.rect.minY, "height": row.rect.height, "selected": row.selected, "role": row.role]
            }])
        if snapshots.count > 8 { snapshots.removeFirst() }
    }

    private func rangeControl() throws -> WCNode? {
        try scan().first { node in
            node.enabled && !node.rect.isEmpty && ["AXStaticText", "AXButton"].contains(node.role) && node.strings.contains {
                let compact = $0.filter { !$0.isWhitespace }
                return compact == "选择到这里" || compact == "最多选择100条"
            }
        }
    }

    private func leaveSelection(page: Page, index: Int) throws -> (Int, Page) {
        let context = try page.rows.map { try checkedMessage($0) }
        try restoreSelection()
        let normal = try stablePage()
        let rebound: Int
        do { rebound = try WeChatMessageContext.resolve(selected: context, target: index, normal: normal.rows.map { $0.strings.first ?? "" }) }
        catch { throw WeChatAutomationError.selection }
        return (rebound, normal)
    }

    /// At the latest message, AXChildren counts loaded slots, including time
    /// separators and system notices. Above the bottom it counts only the
    /// prefix through the visible rows, so it is never a message ordinal.
    private func loadedSlots(_ list: AXUIElement) -> Int {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(list, "AXChildren" as CFString, &count) == .success else { return 0 }
        return Int(count)
    }

    /// Whether the page's list holds the conversation's first message.
    ///
    /// While WeChat still has history to fetch, the list exposes a prefix of
    /// unmaterialised `virtual_cell` slots above its rows; a conversation
    /// fully at its top has a materialised first child and no such prefix.
    /// The padding between the first row and the list's edge is not read:
    /// focus alignment puts a row flush against that edge too, so geometry
    /// cannot tell the two cases apart — only the slots can.
    private func conversationTopReached(_ children: [AXUIElement]) -> Bool {
        guard let first = children.first.map(WCNode.init),
              first.readError == .success, first.id != "virtual_cell", !first.rect.isEmpty else { return false }
        return children.dropFirst().prefix(8).allSatisfy { WCNode($0).id != "virtual_cell" }
    }

    private func conversationTopReached(_ page: Page) -> Bool {
        conversationTopReached(page.list.children)
    }

    /// A stalled walk has two readings: WeChat fetching older history, or the
    /// conversation's first message sitting at the top of the list. The first
    /// is temporary — a fetch that completes lets the next gesture move the
    /// list again — so the top is only confirmed after further spaced
    /// attempts move nothing and the list holds no unmaterialised slots
    /// above its first row. A probe that does move the list reports `moved`
    /// with the page it reached: the caller keeps going rather than failing
    /// on a load that was merely slow.
    private enum StallProbing {
        case top(Page, settled: Bool)
        case moved(Page)
        case stuck
    }

    private func confirmConversationTop(_ stalled: Page, stalledSettled: Bool) throws -> StallProbing {
        var page = stalled
        var settled = stalledSettled
        let signature = page.signature
        // Two pauses, then a scroll, before the absent virtual-cell prefix is
        // allowed to mean the first message. A list that is still fetching
        // moves, or still cannot be read, and is not the top.
        for _ in 0..<2 {
            try pause(1.0)
            guard let looked = try probedPage() else { return .stuck }
            page = looked.page
            settled = settled && looked.settled
            if page.signature != signature { return .moved(page) }
            try scroll(page.list.element, delta: 60, settle: WeChatScrollStep.lengthened(gesturePause))
            guard let looked = try probedPage() else { return .stuck }
            page = looked.page
            settled = settled && looked.settled
            if page.signature != signature { return .moved(page) }
        }
        return conversationTopReached(page) ? .top(page, settled: settled) : .stuck
    }

    /// Keep requesting the top until history is loaded, then return once. The
    /// wheel fallback is for a list that does not support keyboard focus.
    /// Navigation-only warm-up frame. Join notices are legitimate rows here;
    /// they must not require the message-selection reader to invent a bubble.
    private struct PrefetchFrame {
        let list: WCNode
        let rows: [WCNode]
        var page: Page { Page(list: list, rows: rows.filter { $0.id == "chat_bubble_item_view" }) }
        var signature: String {
            "\(list.rect):" + rows.map { "\($0.id):\($0.role):\($0.rect):\($0.strings)" }.joined(separator: "|")
        }
        var data: [WeChatViewportRow] {
            rows.map { WeChatViewportRow(text: $0.id + $0.role + String(describing: $0.strings), y: $0.rect.minY, height: $0.rect.height) }
        }
    }

    /// During warm-up no selection is committed. Return when rows change,
    /// not after a fixed sleep or two identical whole pages. An unchanged but
    /// readable frame is returned after 0.8s so top probing can proceed. Missing
    /// or unmaterialised frames get a bounded read-only wait, never blind input.
    private func prefetchFrame(after signature: String? = nil) throws -> PrefetchFrame {
        let started = clock()
        var fallback: PrefetchFrame?
        var verified = false
        repeat {
            try frontmost()
            // A later failed read invalidates the prior fallback. In particular,
            // do not feed a stale apparently quiet prefix into the top proof.
            fallback = nil
            if let sample = try sampleList(verifiedHere: &verified), !sample.list.rect.isEmpty {
                var visible: [WCNode] = []
                for child in sample.list.children.reversed().prefix(512) {
                    let node = WCNode(child)
                    if node.id == "virtual_cell", node.rect.isEmpty { break }
                    if (node.id == "chat_bubble_item_view" || node.role == "AXStaticText"),
                       !node.rect.intersection(sample.list.rect).isNull { visible.append(node) }
                }
                let rows = Array(visible.reversed())
                if !rows.isEmpty, rows.allSatisfy({ $0.readError == .success && !$0.strings.isEmpty && !$0.rect.isEmpty }),
                   zip(rows, rows.dropFirst()).allSatisfy({ $0.rect.minY < $1.rect.minY }) {
                    let frame = PrefetchFrame(list: sample.list, rows: rows)
                    fallback = frame
                    if signature == nil || frame.signature != signature { return frame }
                }
            }
            if clock() - started >= 0.8, let fallback { return fallback }
            try pause(0.03)
        } while clock() - started < WeChatScrollPacing.maximumStallSeconds
        prefetchExit = "loadingTimeout"
        throw WeChatAutomationError.historyLoadingTimeout
    }

    private func recordPacing(_ event: String, gain measured: Double? = nil) {
        var entry: [String: Any] = ["phase": phase, "event": event, "pause": gesturePause,
                                    "ceiling": Int(deltaCeiling), "batch": exportCount + 1]
        if let measured, measured.isFinite { entry["gain"] = measured }
        pacingEvents.append(entry)
        if pacingEvents.count > 32 { pacingEvents.removeFirst(pacingEvents.count - 32) }
    }

    private func updatePacing(gain measured: Double) throws {
        let wasLoading = scrollPacing.isLoading
        let event = scrollPacing.observe(gain: measured, at: clock())
        if event == .restored || event == .timedOut || (event == .throttled && !wasLoading) {
            recordPacing(event.rawValue, gain: measured)
        }
        if event == .timedOut { throw WeChatAutomationError.scrollStalled }
    }

    private func finishScrollSegment() {
        if scrollPacing.finishSegment() { recordPacing("segmentRestored") }
    }

    /// A row snapshot used after a wheel gesture still has to be suitable for
    /// exact selection. Poll in short windows without posting more gestures;
    /// eight seconds of failed materialisation is a load timeout, not a lost
    /// next-batch anchor. AX messaging itself retains its existing timeout.
    private func settledScrollPage() throws -> Page {
        let deadline = clock() + WeChatScrollPacing.maximumStallSeconds
        repeat {
            try check()
            if scrollPacing.hasTimedOut(at: clock()) { throw WeChatAutomationError.scrollStalled }
            do { return try stablePage(timeout: min(0.8, max(0.02, deadline - clock()))) }
            catch WeChatAutomationError.loading { try pause(0.04) }
        } while clock() < deadline
        throw WeChatAutomationError.historyLoadingTimeout
    }

    /// Exactly one warm-up before any selection. Home remains the fast path;
    /// the wheel fallback uses the same reversible pacing as range navigation.
    /// Only this phase can return to End. Warming is NOT proof of export count
    /// or EOF: the selection engine independently verifies both afterwards.
    private func prefetchHistory(goal: WeChatPrefetchGoal) throws -> Page {
        let previousPhase = phase
        phase = "prefetch"
        let started = clock()
        defer {
            prefetchSeconds = clock() - started
            finishScrollSegment()
            phase = previousPhase
        }
        let deadline = started + goal.timeBudget
        let first = try prefetchFrame()
        var page = try returnToLatest(from: first.page)
        var loaded = loadedSlots(page.list.element)
        prefetchExit = "goalReached"
        recordPacing("prefetchWindow")
        if steps.count < 200 {
            steps.append(["kind": "prefetch-plan", "target": goal.messages,
                          "padded": goal.paddedSlots, "budget": goal.timeBudget])
        }
        if try focusList(page) {
            var homes = 0
            var lastProgress = clock()
            // The first Home only establishes where the current materialised
            // prefix begins. Only a later, smaller child index proves that Qt
            // exposed older rows; repeating the same index is not progress.
            var bestHomeIndex: Int?
            homeWarmup: while goal.needsMore(loadedSlots: loaded) {
                try verifyChat()
                if clock() >= deadline { prefetchExit = "warmupBudget"; break }
                guard clock() - lastProgress < WeChatScrollPacing.maximumStallSeconds else {
                    prefetchExit = "loadingTimeout"
                    break
                }
                progress(L10n.text("正在预加载聊天历史…"))
                guard focusedNode() != nil else { throw WeChatAutomationError.focusChanged }
                try navigationKey(115) // Home, only before selection begins.
                homes += 1
                let loadingDeadline = min(deadline, clock() + 0.8)
                var advance = WeChatHomeAdvance.pending
                repeat {
                    try frontmost()
                    if let focused = focusedNode() {
                        let index = (wcAttribute(page.list.element, "AXChildren") as? [AXUIElement])?
                            .firstIndex(where: { CFEqual($0, focused.element) })
                        let landing = WeChatHomeLanding(
                            childIndex: index,
                            flushWithListTop: abs(focused.rect.minY - page.list.rect.minY) < 2,
                            materialized: focused.id != "virtual_cell" && !focused.rect.isEmpty
                                && focused.readError == .success && !focused.strings.isEmpty
                        )
                        advance = WeChatHomeAdvance.judge(bestIndex: bestHomeIndex, landing)
                        if case .baseline = advance { break }
                        if case .older = advance { break }
                    }
                    try pause(0.02)
                } while clock() < loadingDeadline
                switch advance {
                case .baseline(let index):
                    bestHomeIndex = index
                    continue
                case .older(let distance, let index):
                    bestHomeIndex = index
                    let sum = loaded.addingReportingOverflow(distance)
                    loaded = sum.overflow ? Int.max : sum.partialValue
                    lastProgress = clock()
                    continue
                case .unchanged, .pending:
                    break
                }
                // No closer prefix can mean a notice-only top or a pending
                // fetch. Reuse the tested raw-prefix proof, not Page. An
                // inconclusive warm-up is abandoned; exact selection remains
                // responsible for correctness and can still produce ZIPs.
                guard let focus = focusedNode() else { throw WeChatAutomationError.focusChanged }
                var probeKeys = 0
                do {
                    switch try probeKeyboardTop(from: focus, keys: &probeKeys) {
                    case .top:
                        prefetchExit = "clientHistoryStart"
                        break homeWarmup
                    case .moved:
                        lastProgress = clock()
                        continue
                    }
                } catch WeChatAutomationError.historyUnconfirmed {
                    prefetchExit = "unconfirmedAfterLoadingWait"
                    break homeWarmup
                }
            }
            if steps.count < 200 {
                var entry: [String: Any] = ["kind": "prefetch-home", "keys": homes,
                                            "loaded": loaded, "exit": prefetchExit]
                if let bestHomeIndex { entry["bestIndex"] = bestHomeIndex }
                steps.append(entry)
            }
        } else if goal.needsMore(loadedSlots: loaded) {
            _ = try dragBack(goal: goal, loaded: loaded, deadline: deadline)
        }
        // Do not ask stablePage to read a notice-only top before pressing End.
        // The original return-to-latest verification runs after navigation.
        let oldest = try prefetchFrame()
        page = try returnToLatest(from: oldest.page)
        prefetchLoaded = loadedSlots(page.list.element)
        return page
    }

    /// Warming is an optimisation, not a correctness gate. A navigation or
    /// loading failure here falls back to the ordinary `.latest` selection
    /// path, which independently returns to the live bottom and verifies the
    /// first batch. Foreground/chat identity failures still stop immediately.
    private func bestEffortPrefetch(goal: WeChatPrefetchGoal) throws -> Page? {
        do { return try prefetchHistory(goal: goal) }
        catch let error as WeChatAutomationError {
            let reason: String
            switch error {
            case .historyIncomplete: reason = "historyIncomplete"
            case .historyUnconfirmed: reason = "historyUnconfirmed"
            case .selection: reason = "selection"
            case .loading: reason = "loading"
            case .historyLoadingTimeout: reason = "historyLoadingTimeout"
            case .scrollStalled: reason = "scrollStalled"
            default: throw error
            }
            let previousExit = prefetchExit
            prefetchExit = "fallback-" + reason
            if steps.count < 200 {
                steps.append(["kind": "prefetch-fallback", "reason": reason,
                              "previousExit": previousExit, "target": goal.messages])
            }
            return nil
        }
    }

    /// One bounded warm-up sweep, with two navigation frames in memory.
    /// About 70% of a screen leaves overlap for measuring actual wheel gain.
    /// A complete screen change may estimate warm-up progress, NEVER message
    /// ordinals. The initial-window deadline is always finite.
    private func dragBack(goal: WeChatPrefetchGoal, loaded: Int, deadline: Double) throws -> PrefetchFrame {
        var frame = try prefetchFrame()
        var travelled = 0
        var lastProgress = clock()
        var top = WeChatHistoryTopProbe()
        while goal.needsMore(loadedSlots: max(loaded, travelled)) {
            try verifyChat()
            if clock() >= deadline { prefetchExit = "warmupBudget"; break }
            guard clock() - lastProgress < WeChatScrollPacing.maximumStallSeconds else {
                prefetchExit = "scrollStalled"
                break
            }
            progress(L10n.text("正在预加载聊天历史…"))
            let tallest = frame.rows.map(\.rect.height).max() ?? frame.list.rect.height
            let reach = WeChatScrollStep.reach(listHeight: frame.list.rect.height, tallestRow: tallest,
                                               gainMeasured: gainMeasured, reachFactor: 1)
            let delta = WeChatScrollStep.delta(reach: reach, gain: gain, ceiling: deltaCeiling)
            let before = frame
            try scroll(before.list.element, delta: delta, settle: gesturePause)
            frame = try prefetchFrame(after: before.signature)
            let step = WeChatPrefetch.burst(from: before.data, to: frame.data, gestures: 1,
                                            delta: delta, reach: Double(delta) * gain)
            if let points = step.pointsPerGesture {
                let measured = points / Double(delta)
                try updatePacing(gain: measured)
                if WeChatScrollStep.isPlausible(gain: measured) { gain = measured; gainMeasured = true }
            } else {
                // No overlap supplies no measured gain. It may estimate warm-up
                // distance, but cannot cancel an active loading deadline or
                // manufacture the two healthy measurements required for recovery.
                try updatePacing(gain: .nan)
            }
            if frame.signature != before.signature {
                lastProgress = clock()
                let sum = travelled.addingReportingOverflow(step.rows)
                travelled = sum.overflow ? Int.max : sum.partialValue
                prefetchRows = travelled
                _ = top.observe([], at: clock())
                continue
            }
            // First CHILD, not first visible bubble: virtual prefixes, an
            // oversized row above the edge and AXBusy all prevent a top proof.
            let first = frame.list.children.first.map(WCNode.init)
            let prefix = first.map { [historyRow($0)] } ?? []
            let edge = first.map { $0.rect.minY >= frame.list.rect.minY - 3 && $0.rect.minY < frame.list.rect.maxY } ?? false
            let busy = (wcAttribute(frame.list.element, "AXBusy") as? NSNumber)?.boolValue == true
            if top.observe(prefix, at: clock(), busy: busy, leadingEdgeVisible: edge) {
                prefetchExit = "clientHistoryStart"
                break
            }
        }
        return frame
    }

    /// End jumps through the loaded history immediately. Verified wheel
    /// bursts remain the fallback when native keyboard navigation is absent.
    private func returnToLatest(from start: Page) throws -> Page {
        let resuming = phase
        phase = "return-to-latest"
        defer { phase = resuming }
        var page = start
        if try focusList(page) {
            try navigationKey(119) // End
            page = try stablePage(timeout: 5)
            // Verify End actually focused the final child; a successful key
            // post alone does not establish that this is the latest message.
            // The final row can also be a timestamp or a "拍了拍" notice.
            // End has still reached the bottom when that row has focus and
            // the newest selectable message is visible above it.
            if let last = page.list.children.last, let focused = focusedNode(),
               CFEqual(last, focused.element), !focused.rect.intersection(page.list.rect).isNull,
               let newest = page.rows.last, page.canCheck(newest) { return page }
        }
        // Usually the list is already where this wants it — every batch anchor
        // comes through here — so the first burst is small enough to find that
        // out cheaply, and doubles only while there is still distance to cover.
        var burst = 2
        var idle = 0
        let deadline = clock() + 45
        while clock() < deadline {
            let before = page.signature
            for _ in 0..<burst {
                try scroll(page.list.element, delta: -WeChatScrollStep.maximumDelta, settle: WeChatScrollStep.minimumGesturePause)
            }
            page = try stablePage(timeout: 5)
            if page.signature == before {
                idle += 1
                if idle >= 2 { return page }
            } else {
                idle = 0
                burst = min(8, burst * 2)
            }
        }
        throw WeChatAutomationError.selection
    }

    /// Walk native row focus, not pixels. One Up crosses even a screen-height
    /// bubble; non-message rows (timestamps/system notices) are not counted.
    /// Wait only until that particular key has changed focus, never a fixed
    /// gesture delay. Count message rows without interpreting their contents.
    /// The traversal outcome: where the keyboard row ended, the rebound
    /// viewport, and how many messages it proved — fewer than `limit` when
    /// the conversation itself ran out above.
    private struct KeyboardArrival {
        let page: Page
        let tracked: WeChatViewport
        let count: Int
        let reachedConversationTop: Bool
        /// False when only the focused message was proved. The range control
        /// may still run; the next batch may not resume from this viewport.
        let pageSettled: Bool
    }

    /// A normal next-batch walk can prove EOF without selecting another row.
    /// It is caught only after at least one archive has already committed.
    private struct ReachedHistoryStart: Error {}
    private enum KeyboardTopResult { case top, moved(WCNode) }

    private func historyRow(_ node: WCNode) -> WeChatHistoryRow {
        let kind: WeChatHistoryRow.Kind
        if node.id == "virtual_cell" { kind = .unresolved }
        else if node.id == "chat_bubble_item_view", ["AXCheckBox", "AXStaticText"].contains(node.role) { kind = .message }
        else if node.role == "AXStaticText" { kind = .notice }
        else { kind = .unresolved }
        // Structured encoding avoids delimiter collisions; use the full digest
        // for matching. Only shortened hashes are written to diagnostics.
        let identity = (try? JSONEncoder().encode([node.id, node.role] + node.strings)).map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } ?? ""
        return WeChatHistoryRow(kind: kind, fingerprint: identity,
                                readable: node.readError == .success && !node.strings.isEmpty,
                                materialized: !node.rect.isEmpty, selected: node.selected)
    }

    private func sameKeyboardRow(_ lhs: WCNode, _ rhs: WCNode) -> Bool {
        CFEqual(lhs.element, rhs.element) && lhs.id == rhs.id && lhs.role == rhs.role && lhs.strings == rhs.strings
    }

    /// A key acknowledgement, not a count inferred from the number of keys.
    /// Every caller consumes the returned row exactly once, including when a
    /// delayed history fetch finishes during a top probe.
    private func movedKeyboardRow(from previous: WCNode, timeout: Double) throws -> WCNode? {
        let deadline = clock() + timeout
        var outsideSince: Double?
        repeat {
            try frontmost()
            if let next = focusedNode(), let list = settledList {
                switch listFocus(next, list: list) {
                case .outside:
                    // A click in the composer or the session list is not a
                    // different chat. Put focus back on the message list.
                    let now = clock()
                    if outsideSince == nil { outsideSince = now }
                    if now - (outsideSince ?? now) > 0.4 {
                        try refocusMessageList(list)
                        outsideSince = nil
                    }
                case .unsettled:
                    outsideSince = nil
                case .row(let row):
                    outsideSince = nil
                    if row.id != "virtual_cell", !row.rect.isEmpty, !sameKeyboardRow(row, previous) { return row }
                }
            }
            try pause(0.005)
        } while clock() < deadline
        return nil
    }

    /// Unlike stablePage, this reads the list and its prefix even when there
    /// are NO visible message bubbles. A long run of join notices is a valid
    /// navigation viewport, not a loading error. Unknown/virtual slots cannot
    /// establish the start, and off-screen new arrivals do not change a prefix.
    private func probeKeyboardTop(from previous: WCNode, keys: inout Int) throws -> KeyboardTopResult {
        let originalPhase = phase
        phase = "history-top-probe"
        defer { phase = originalPhase }
        var probe = WeChatHistoryTopProbe()
        for attempt in 0..<6 {
            try verifyChat()
            var verified = false
            guard let sample = try sampleList(verifiedHere: &verified), let focus = focusedNode() else {
                throw WeChatAutomationError.historyUnconfirmed
            }
            let row: WCNode
            switch listFocus(focus, list: sample.list.element) {
            case .outside:
                historyBoundaryLog = ["stage": "probe", "reason": "outsideList", "focusRole": focus.role, "focusID": focus.id]
                if let list = settledList {
                    try refocusMessageList(list)
                    try pause(0.2)
                    continue
                }
                throw WeChatAutomationError.focusChanged
            case .unsettled:
                _ = probe.observe([], at: clock())
                historyBoundaryLog = ["stage": "probe", "reason": "focusUnmaterialized", "attempt": attempt + 1]
                try pause(0.5)
                continue
            case .row(let resolved):
                row = resolved
            }
            guard let index = sample.list.children.firstIndex(where: { CFEqual($0, row.element) }),
                  index < 4096 else { throw WeChatAutomationError.historyUnconfirmed }
            if row.id == "virtual_cell" || row.rect.isEmpty {
                _ = probe.observe([], at: clock())
                historyBoundaryLog = ["stage": "probe", "reason": "focusUnmaterialized", "attempt": attempt + 1]
                try pause(0.5)
                continue
            }
            if !sameKeyboardRow(row, previous) { return .moved(row) }
            let prefixNodes = sample.list.children.prefix(index + 1).map(WCNode.init)
            let prefix = prefixNodes.map(historyRow)
            // Up can focus an oversized first row while its top is still far
            // off-screen. Reach that edge before treating quiet loading as EOF.
            let leadingEdgeVisible = prefixNodes.first.map {
                $0.rect.minY >= sample.list.rect.minY - 3 && $0.rect.minY < sample.list.rect.maxY
            } ?? false
            let busy = (wcAttribute(sample.list.element, "AXBusy") as? NSNumber)?.boolValue == true
            let reason = WeChatHistoryPrefix.judge(prefix, busy: busy, leadingEdgeVisible: leadingEdgeVisible)
            historyBoundaryLog = ["stage": "probe", "attempt": attempt + 1, "prefixRows": prefix.count,
                                  "reason": reason.rawValue, "focusRole": focus.role, "focusID": focus.id,
                                  "focusHash": textHash(focus.strings), "visibleBubbles": sample.rows.count, "leadingEdgeVisible": leadingEdgeVisible]
            let confirmed = probe.observe(prefix, at: clock(), busy: busy, leadingEdgeVisible: leadingEdgeVisible)
            steps.append(["kind": "history-probe", "attempt": attempt + 1, "reason": reason.rawValue,
                          "prefixRows": prefix.count, "visibleBubbles": sample.rows.count, "confirmed": confirmed])
            if confirmed { return .top }
            guard attempt < 5 else { break }
            try pause(1.0)
            try navigationKey(126)
            keys += 1
            if let moved = try movedKeyboardRow(from: previous, timeout: 0.35) { return .moved(moved) }
            // Give a cold list an independent chance to request older history.
            // Wheel events do not move the keyboard row; the next observation
            // still has to verify that, rather than assuming it.
            let gap = sample.list.rect.minY - (prefixNodes.first?.rect.minY ?? sample.list.rect.minY)
            let delta: Int32 = leadingEdgeVisible ? 60 : WeChatScrollStep.delta(reach: max(60, gap), gain: gain, ceiling: 250)
            try scroll(sample.list.element, delta: delta, settle: WeChatScrollStep.lengthened(gesturePause))
        }
        throw WeChatAutomationError.historyUnconfirmed
    }

    /// Walk the actual separator trail BACK to the last counted bubble. Do
    /// not count these Down keys as messages, choose a nearby bubble, compare
    /// stale coordinates, or declare a stalled static text to be EOF by itself.
    private func restoreHistoryEndpoint(focused: WCNode, lastMessage: WCNode,
                                        passedNotices: [WeChatHistoryRow], count: Int, keys: Int) throws -> KeyboardArrival {
        let endpoint = historyRow(lastMessage)
        let focus = focusedNode().flatMap { node -> WCNode? in
            guard let list = settledList else { return nil }
            if case .row(let row) = listFocus(node, list: list) { return row }
            return nil
        }
        guard count > 0, let focus, sameKeyboardRow(focus, focused),
              let plan = WeChatHistoryRewind(endpoint: endpoint, passedNotices: passedNotices),
              (passedNotices.last ?? endpoint) == historyRow(focus) else {
            throw WeChatAutomationError.historyUnconfirmed
        }
        var rewind = plan
        var current = focus
        let expected = rewind.remaining
        let deadline = clock() + min(60, max(8, Double(expected) * 0.25))
        while !rewind.isComplete {
            guard clock() < deadline else { throw WeChatAutomationError.historyUnconfirmed }
            try navigationKey(125)
            guard let next = try movedKeyboardRow(from: current, timeout: 0.7) else {
                throw WeChatAutomationError.historyUnconfirmed
            }
            let verdict = rewind.accept(historyRow(next))
            historyBoundaryLog = ["stage": "rewind", "expectedSteps": expected, "remaining": rewind.remaining,
                                  "countedMessages": count, "focusID": next.id,
                                  "focusRole": next.role, "focusHash": textHash(next.strings)]
            guard verdict != .mismatch else {
                steps.append(["kind": "history-rewind-rejected", "remaining": rewind.remaining, "counted": count])
                throw WeChatAutomationError.historyUnconfirmed
            }
            current = next
        }
        guard historyRow(current) == endpoint, current.role == "AXCheckBox",
              current.selected == (count == 1) else { throw WeChatAutomationError.historyUnconfirmed }
        noteKeyboardTarget(current, count: count, keys: keys)
        steps.append(["kind": "short-conversation", "via": "verified-notice-trail", "reached": count, "rewindKeys": expected])
        guard let looked = try probedPage(), let held = focusedNode(), historyRow(held) == endpoint else {
            throw WeChatAutomationError.historyUnconfirmed
        }
        return try focusedArrival(page: looked.page, focus: held, count: count, keys: keys,
                                  settled: looked.settled, reachedTop: true)
    }

    /// After the native share, the verified keyboard row is the previous
    /// batch's endpoint. Find exactly ONE older real message without relying
    /// on its being visible on the same screen. This also handles an exact
    /// multiple of 100: no next message is a clean finish, not a failed batch.
    private func nextKeyboardAnchor(after endpoint: WCNode) throws -> (index: Int, page: Page) {
        phase = "next-batch-keyboard"
        var previous = endpoint
        var keys = 0
        let deadline = clock() + 35
        while keys < 600, clock() < deadline {
            try navigationKey(126)
            keys += 1
            let next: WCNode
            if let moved = try movedKeyboardRow(from: previous, timeout: 2) { next = moved }
            else {
                switch try probeKeyboardTop(from: previous, keys: &keys) {
                case .top: throw ReachedHistoryStart()
                case .moved(let moved): next = moved
                }
            }
            if next.id == "chat_bubble_item_view" {
                // Returning to the old endpoint is not evidence of EOF.
                guard next.role == "AXStaticText", !CFEqual(next.element, endpoint.element) else {
                    throw WeChatAutomationError.historyUnconfirmed
                }
                let page = try stablePage()
                guard let index = page.rows.firstIndex(where: { CFEqual($0.element, next.element) && $0.strings == next.strings }) else {
                    throw WeChatAutomationError.historyUnconfirmed
                }
                steps.append(["kind": "next-keyboard-anchor", "keys": keys, "hash": textHash(next.strings)])
                return (index, page)
            }
            previous = next
        }
        throw WeChatAutomationError.historyUnconfirmed
    }

    private func keyboardRange(from start: Page, limit: Int, endpointFocus: Bool = false) throws -> KeyboardArrival? {
        guard try focusList(start), var first = focusedNode() else { return nil }
        steps.append(["kind": "keyboard-setup", "focusID": first.id, "role": first.role,
                      "selected": first.selected,
                      "focusIndex": start.list.children.firstIndex(where: { CFEqual($0, first.element) }) ?? -1,
                      "anchorIndex": start.list.children.firstIndex(where: { child in start.rows.contains(where: { $0.selected && CFEqual($0.element, child) }) }) ?? -1])
        // A native share rebuilds the list. Its current keyboard row can stay
        // on the previous batch's endpoint while the context menu selected
        // its neighbour. Align within this one fresh child array, including
        // separator rows, before starting the message count.
        if !first.selected,
           let anchor = start.rows.first(where: \.selected),
           let anchorIndex = start.list.children.firstIndex(where: { CFEqual($0, anchor.element) }),
           let focusIndex = start.list.children.firstIndex(where: { CFEqual($0, first.element) }),
           !first.rect.intersection(start.list.rect).isNull, abs(anchorIndex - focusIndex) <= 20 {
            // A resumed batch knows where that row must be: the previous
            // endpoint, just below this anchor with only separators between.
            // Anywhere else the anchor is not the boundary, and aligning to it
            // would skip or repeat messages without a word.
            if endpointFocus {
                guard first.id == "chat_bubble_item_view", focusIndex > anchorIndex,
                      start.list.children[(anchorIndex + 1)..<focusIndex].allSatisfy({ WCNode($0).id != "chat_bubble_item_view" }) else {
                    throw WeChatAutomationError.selection
                }
            }
            for _ in 0..<abs(anchorIndex - focusIndex) {
                try navigationKey(anchorIndex < focusIndex ? 126 : 125)
                let deadline = clock() + 0.5
                var next: WCNode?
                repeat {
                    try frontmost()
                    if let node = focusedNode(), !CFEqual(node.element, first.element) || node.strings != first.strings { next = node; break }
                    try pause(0.001)
                } while clock() < deadline
                guard let next else { throw WeChatAutomationError.selection }
                first = next
            }
        }
        guard first.selected, first.id == "chat_bubble_item_view", first.role == "AXCheckBox" else { return nil }
        phase = "keyboard-range"
        var previous = first
        var lastMessage = first
        var passedNotices: [WeChatHistoryRow] = []
        var count = 1
        let deadline = clock() + 35
        var keys = 0
        while count < limit {
            guard clock() < deadline, keys < 600 else { throw WeChatAutomationError.selection }
            try navigationKey(126)
            keys += 1
            var next: WCNode
            if let moved = try movedKeyboardRow(from: previous, timeout: min(2, max(0, deadline - clock()))) {
                next = moved
            } else {
                // No Page read here: the top can be an entire screen of system
                // notices. First prove the raw list boundary, THEN rewind the
                // separator trail and ask for a message-selection Page.
                steps.append(["kind": "keyboard-stall", "countedMessages": count, "keys": keys,
                              "passedNotices": passedNotices.count, "focusRole": previous.role, "focusHash": textHash(previous.strings)])
                do {
                    switch try probeKeyboardTop(from: previous, keys: &keys) {
                    case .top:
                        return try restoreHistoryEndpoint(focused: previous, lastMessage: lastMessage,
                                                          passedNotices: passedNotices, count: count, keys: keys)
                    case .moved(let moved): next = moved
                    }
                } catch WeChatAutomationError.historyUnconfirmed {
                    // Unsupported keyboard navigation may fall back only before
                    // any progress, and only if the original viewport survived.
                    if count == 1, passedNotices.isEmpty,
                       let fresh = try probedPage(), fresh.settled, fresh.page.signature == start.signature {
                        return nil
                    }
                    throw WeChatAutomationError.historyUnconfirmed
                }
            }
            guard let list = settledList else { throw WeChatAutomationError.focusChanged }
            switch listFocus(next, list: list) {
            case .row(let row): next = row
            case .unsettled, .outside:
                historyBoundaryLog = ["stage": "walk", "reason": "outsideList", "focusRole": next.role, "focusID": next.id]
                throw WeChatAutomationError.focusChanged
            }
            if next.id == "chat_bubble_item_view" {
                guard next.role == "AXCheckBox" else { throw WeChatAutomationError.selection }
                if next.selected {
                    // A wrap/focus reset is not proof that all older history was
                    // visited. Never relabel an arbitrary oldest visible row.
                    historyBoundaryLog = ["stage": "walk", "reason": "returnedToSelectedAnchor", "countedMessages": count]
                    throw WeChatAutomationError.historyUnconfirmed
                }
                count += 1
                lastMessage = next
                passedNotices.removeAll(keepingCapacity: true)
            } else {
                passedNotices.append(historyRow(next))
            }
            // Timestamps, system notices, cards and images are siblings of the
            // bubbles. They are not messages. Refusing every role except
            // static text aborted the walk before the range button ran, so a
            // short conversation — including a count of zero, which asks for
            // all of it — stopped in multi-select with nothing exported.
            previous = next
        }
        noteKeyboardTarget(previous, count: count, keys: keys)
        do {
            return try focusedArrival(page: try stablePage(), focus: previous, count: count, keys: keys, settled: true, reachedTop: false)
        } catch WeChatAutomationError.loading {
            let ordinal = count - 1
            guard let held = try repeatedFocus(focusMessage(previous, ordinal: ordinal), element: previous.element, samples: 3),
                  let once = try readablePage(), indexOfFocus(held, in: once) != nil else {
                throw WeChatAutomationError.selection
            }
            return try focusedArrival(page: once, focus: held, count: count, keys: keys, settled: false, reachedTop: false)
        }
    }

    /// The counted row, located either in a settled page or on the keyboard
    /// alone. `keyboardMessages` was already stored when the count was reached.
    private func focusedArrival(page: Page, focus: WCNode, count: Int, keys: Int, settled: Bool, reachedTop: Bool) throws -> KeyboardArrival {
        phase = "keyboard-arrived"
        observe(settled ? "keyboard-arrived" : "keyboard-focus", page)
        guard let index = page.rows.firstIndex(where: { CFEqual($0.element, focus.element) && $0.strings == focus.strings }) ?? indexOfFocus(focus, in: page) else {
            throw WeChatAutomationError.selection
        }
        guard page.rows[index].strings == focus.strings else { throw WeChatAutomationError.selection }
        steps.append(["kind": "keyboard", "messages": count, "keys": keys, "settled": settled,
                      "focusIndex": index, "labelMatch": true,
                      "focusedY": focus.rect.minY, "focusedHeight": focus.rect.height])
        let tracked = WeChatViewport(rows: page.data, anchorIndex: index, anchorOrdinal: count - 1)
        return KeyboardArrival(page: page, tracked: tracked, count: count, reachedConversationTop: reachedTop, pageSettled: settled)
    }

    /// After a nudge, prefer a settled page and keep a single reading when the
    /// list will not sit still. A missing list is a failed proof, not a cue to
    /// press the range control anyway.
    private func pageAfterScroll() throws -> Page {
        do { return try stablePage(timeout: 0.6) }
        catch WeChatAutomationError.loading {
            guard let once = try readablePage() else { throw WeChatAutomationError.selection }
            return once
        }
    }

    private func endpointIsSelected(ordinal: Int) -> Bool {
        guard let node = focusedNode(), node.selected, let saved = keyboardTarget else { return false }
        return WeChatFocusHold.identifies(focusMessage(node, ordinal: ordinal), as: saved)
    }

    /// The range control has been pressed. A settled page rebinds the next
    /// batch. A page that will not settle can still confirm that the focused
    /// message is now selected; that batch is exported and the walk stops.
    private func commitRange(page: Page, tracked: WeChatViewport, limit: Int, usedKeyboard: Bool, conversationEnded: Bool, pageSettled: Bool) throws -> Selection {
        var tracked = tracked
        var settled = pageSettled
        let confirmed: Page
        do {
            confirmed = try stablePage()
            settled = true
        } catch WeChatAutomationError.loading {
            settled = false
            guard let once = try readablePage() else { throw WeChatAutomationError.selection }
            confirmed = once
        }
        observe("after-range", confirmed)
        let pinned = pinKeyboardRow(&tracked, page: confirmed, ordinal: usedKeyboard ? limit - 1 : nil)
        if !pinned {
            do { try tracked.resume(confirmed.data) }
            catch {
                guard endpointIsSelected(ordinal: limit - 1) else { throw WeChatAutomationError.selection }
                return Selection(count: limit, checkpoint: try checkpoint(tracked, page: page, keyboardOrdinal: usedKeyboard ? limit - 1 : nil), reachedConversationTop: conversationEnded, boundaryConfirmed: false)
            }
        }
        guard let endpoint = tracked.index(of: limit - 1), confirmed.rows[endpoint].selected else { throw WeChatAutomationError.selection }
        if !settled { guard endpointIsSelected(ordinal: limit - 1) else { throw WeChatAutomationError.selection } }
        return Selection(count: limit, checkpoint: try checkpoint(tracked, page: confirmed, keyboardOrdinal: usedKeyboard ? limit - 1 : nil), reachedConversationTop: conversationEnded, boundaryConfirmed: settled)
    }

    /// The keyboard count is known and the page is not. Press 「选择到这里」 only
    /// when that label is showing and the endpoint has clearance. A cap, or a
    /// bubble flush with the top, gets a few viewport nudges. Nothing here
    /// sends an arrow key.
    private func finishFromFocus(page initial: Page, tracked initialTracked: WeChatViewport, limit: Int, conversationEnded: Bool) throws -> Selection {
        var page = initial
        var tracked = initialTracked
        guard var current = focusedNode() else { throw WeChatAutomationError.selection }
        let ordinal = limit - 1
        for attempt in 0..<WeChatFocusClearance.maximumAttempts {
            guard let index = tracked.index(of: ordinal) ?? indexOfFocus(current, in: page), page.rows.indices.contains(index) else {
                throw WeChatAutomationError.selection
            }
            let button = try rangeControl()
            noteRangeControl(button)
            let label = WeChatRangeControlLabel.parse(button?.strings ?? [])
            steps.append(["kind": "range-control", "state": label.rawValue, "rowY": Double(page.rows[index].rect.minY), "listTop": Double(page.list.rect.minY)])
            if label == .selectHere,
               tracked.canSelectRange(endingAt: ordinal, listTop: page.list.rect.minY, listHeight: page.list.rect.height, keyboardVerified: true),
               let button {
                observe("before-range", page)
                try press(button)
                rangeClicks += 1
                return try commitRange(page: page, tracked: tracked, limit: limit, usedKeyboard: true, conversationEnded: conversationEnded, pageSettled: false)
            }
            let flush = WeChatFocusClearance.olderNudge(rowY: page.rows[index].rect.minY, listTop: page.list.rect.minY) != nil
            guard label == .capped || flush else { break }
            guard let nudged = try nudgeOlder(from: current, ordinal: ordinal, list: page.list, forced: label == .capped, attempt: attempt) else {
                throw WeChatAutomationError.selection
            }
            current = nudged
            page = try pageAfterScroll()
            guard let idx = indexOfFocus(current, in: page) else { throw WeChatAutomationError.selection }
            tracked = WeChatViewport(rows: page.data, anchorIndex: idx, anchorOrdinal: ordinal)
        }
        throw WeChatAutomationError.selection
    }

    private func selectBatch(limit: Int, start: SelectionStart, latestPage: Page? = nil) throws -> Selection {
        defer { finishScrollSegment() }
        phase = "select-anchor"
        let anchorIndex: Int, anchorPage: Page
        var resumedFromKeyboard = false
        switch start {
        case .resume(let saved, let ordinal):
            phase = ordinal == 0 ? "time-boundary-anchor" : "next-batch-anchor"
            var page = try stablePage(), tracked = saved.viewport
            // Only a focused list reports its keyboard row, and the share sheet
            // may have taken focus with it. Focusing moves no row on 4.1.13.
            if saved.keyboardOrdinal != nil, try focusList(page) { page = try stablePage() }
            let owner = try window(of: page)
            observe("resume", page)
            let stillSelecting = page.rows.allSatisfy { $0.role == "AXCheckBox" }
            guard CFEqual(owner.element, saved.window), owner.rect == saved.windowRect,
                  stillSelecting || page.rows.allSatisfy({ $0.role == "AXStaticText" }) else { throw WeChatAutomationError.selection }
            // A sheet creates a new observation boundary. No cached AX message
            // handles survive it, and no search starts from an unknown position.
            // External sharing in WeChat 4.1.13 exits multi-select, and the
            // sender prefix disappears. New arrivals may also add or push out
            // visible rows. Reuse the remaining ordered context to continue
            // from the saved boundary, not from the current newest message.
            do { try tracked.resume(page.data, afterLeavingSelection: !stillSelecting) } catch { throw WeChatAutomationError.selection }
            // The previous batch left the keyboard row on its endpoint, one
            // message newer than this anchor. After sharing every photo reads
            // 图片 whoever sent it, and a scroll step over photos reads the same
            // as none; that row does not. The share itself moves nothing, so
            // here the row and the content must agree — if they do not, one of
            // those two premises is gone and neither can be trusted.
            var proof = saved.viewport
            var pinned = pinKeyboardRow(&proof, page: page, ordinal: saved.keyboardOrdinal, afterLeavingSelection: !stillSelecting)
            guard !pinned || proof.firstOrdinal == tracked.firstOrdinal else { throw WeChatAutomationError.selection }
            if !stillSelecting { ownsSelection = false }
            if pinned, !stillSelecting, ordinal > 0, saved.keyboardOrdinal == ordinal - 1,
               let endpoint = focusedNode() {
                let next = try nextKeyboardAnchor(after: endpoint)
                anchorIndex = next.index
                anchorPage = next.page
                resumedBatches += 1
                // Focus now belongs to the NEW anchor, not the old endpoint.
                resumedFromKeyboard = false
                break
            }
            var budget = NavigationBudget(deadline: clock() + 15, maximumSteps: 60)
            while true {
                try budget.observe(page)
                if let index = tracked.index(of: ordinal) {
                    let row = page.rows[index]
                    if row.rect.minY >= page.list.rect.minY + 4,
                       row.rect.minY + min(70, row.rect.height) <= page.list.rect.maxY - 4 {
                        // For next batch, the exact adjacent ordinal must be
                        // unchecked; a time trim instead reuses selected newest.
                        guard !stillSelecting || row.selected == (ordinal == 0) else { throw WeChatAutomationError.selection }
                        if ordinal > 0 {
                            guard let previous = tracked.index(of: ordinal - 1), previous == index + 1,
                                  !stillSelecting || page.rows[previous].selected else { throw WeChatAutomationError.selection }
                        }
                        observe("confirmed-anchor", page)
                        if stillSelecting { (anchorIndex, anchorPage) = try leaveSelection(page: page, index: index) }
                        else { anchorIndex = index; anchorPage = page }
                        resumedBatches += 1
                        resumedFromKeyboard = pinned && ordinal > 0
                        break
                    }
                }
                let delta: Int32
                if let index = tracked.index(of: ordinal) {
                    delta = page.rows[index].rect.midY < page.list.rect.midY ? 60 : -60
                } else {
                    // Small enough steps that the keyboard row stays on screen.
                    let step: Int32 = pinned ? 60 : 250
                    delta = ordinal > tracked.firstOrdinal ? step : -step
                }
                try scroll(page.list.element, delta: delta)
                page = try stablePage()
                if pinKeyboardRow(&tracked, page: page, ordinal: saved.keyboardOrdinal) { pinned = true; continue }
                do { try tracked.advance(page.data, older: delta > 0) } catch { throw WeChatAutomationError.selection }
            }
        case .latest:
            // This used to open with one -10_000 gesture. Measured twice on
            // 2026-09-07 against 4.1.13, WeChat clamps a gesture that large to
            // about 50 points — a single message — so it only ever looked like
            // it worked, because the list is normally already at the newest
            // message and the loop stopped on the first unchanged snapshot. A
            // user who had scrolled up first found it could not get home.
            let page: Page
            if let latestPage { page = latestPage }
            else { page = try returnToLatest(from: try stablePage()) }
            guard let latest = page.rows.last, page.canCheck(latest) else { throw WeChatAutomationError.selection }
            anchorIndex = page.rows.count - 1; anchorPage = page
        }
        let (newest, selectedPage) = try beginSelection(at: anchorIndex, in: anchorPage)
        phase = "select-range"
        // Every batch needs the exact first visible message before pressing
        // the range button. Track overlapping content and measured motion,
        // never AX child indices. The ZIP itself supplies all message content.
        var page = selectedPage
        guard let index = page.rows.firstIndex(where: \.selected) else { throw WeChatAutomationError.selection }
        var tracked = WeChatViewport(rows: page.data, anchorIndex: index)
        if limit == 1 { return Selection(count: 1, checkpoint: try checkpoint(tracked, page: page), reachedConversationTop: false, boundaryConfirmed: true) }
        var usedKeyboard = false
        var conversationEnded = false
        // A conversation with fewer messages than `limit` reports its own
        // count here; the selection below still ends at its first message.
        var limit = limit
        if let arrival = try keyboardRange(from: page, limit: limit, endpointFocus: resumedFromKeyboard) {
            page = arrival.page; tracked = arrival.tracked; usedKeyboard = true
            limit = arrival.count
            conversationEnded = arrival.reachedConversationTop
            // The conversation ran out on its only message. It is already the
            // selected anchor; there is no older row for the range button.
            if arrival.count == 1, arrival.reachedConversationTop {
                return Selection(count: 1, checkpoint: try checkpoint(tracked, page: page), reachedConversationTop: true, boundaryConfirmed: true)
            }
            if !arrival.pageSettled {
                return try finishFromFocus(page: page, tracked: tracked, limit: limit, conversationEnded: conversationEnded)
            }
        } else {
            // Setting AXFocused may itself scroll in another Qt version.
            // Rebind before using the wheel fallback's initial ordinal.
            page = try stablePage()
            let selected = page.rows.indices.filter { page.rows[$0].selected }
            guard selected.count == 1, let anchor = selected.first,
                  try checkedMessage(page.rows[anchor]) == newest else { throw WeChatAutomationError.selection }
            tracked = WeChatViewport(rows: page.data, anchorIndex: anchor)
        }
        phase = "select-range"
        var unchanged = 0
        // This batch's viewport nudges. The run-wide recovery log must not
        // spend them: the fourth batch of 100 is pinned on the top edge too.
        var nudgeAttempts = 0
        // Backed off by half whenever a step outruns the viewport tracker.
        var reachFactor = 1.0, overshoots = 0
        var budget = NavigationBudget(deadline: clock() + 35, maximumSteps: 120)
        func capped(_ button: WCNode?) -> Bool {
            button?.strings.contains { $0.filter { !$0.isWhitespace } == "最多选择100条" } == true
        }
        while true {
            try budget.observe(page)
            let tallest = page.rows.map(\.rect.height).max() ?? page.list.rect.height
            var delta = WeChatScrollStep.delta(
                reach: WeChatScrollStep.reach(listHeight: page.list.rect.height, tallestRow: tallest,
                                              gainMeasured: gainMeasured, reachFactor: reachFactor),
                gain: gain, ceiling: deltaCeiling
            )
            if let target = tracked.index(of: limit - 1) {
                let row = page.rows[target]
                // A short interval at the live bottom cannot be scrolled to
                // the top range button. WeChat's native Shift-click selects
                // the visible interval in one action, including quoted rows.
                if unchanged > 0, limit < 100, let newestIndex = tracked.index(of: 0),
                   target < newestIndex, page.canCheck(row), page.canCheck(page.rows[newestIndex]) {
                    try click(CGPoint(x: row.rect.minX + 22, y: row.rect.midY), modifiers: .maskShift)
                    shiftRangeClicks += 1
                    page = try stablePage()
                    observe("after-shift-range", page)
                    do { try tracked.resume(page.data) } catch { throw WeChatAutomationError.selection }
                    guard page.rows.indices.filter({ page.rows[$0].selected }) == Array(target...newestIndex) else { throw WeChatAutomationError.selection }
                    return Selection(count: limit, checkpoint: try checkpoint(tracked, page: page), reachedConversationTop: conversationEnded, boundaryConfirmed: true)
                }
                // Qt's range button excludes a row flush against its top
                // edge. Native Up aligns exactly there; give it the same
                // small inset as the wheel locator before pressing range.
                if tracked.canSelectRange(endingAt: limit - 1, listTop: page.list.rect.minY,
                                          listHeight: page.list.rect.height, keyboardVerified: usedKeyboard),
                   let button = try rangeControl() {
                    // With the row above cut by the top edge, WeChat counts from
                    // the row taken as the endpoint and still finds more than
                    // this batch. The one-point nudge below cannot change that;
                    // it used to run the budget out a point at a time. A row
                    // above that is whole is WeChat's start instead, and the
                    // nudge does fix that.
                    if capped(button) {
                        noteRangeControl(button)
                        // Keep the keyboard row. A few points toward older
                        // messages moves that bubble down off the edge; a Down
                        // key would make it the previous message.
                        if usedKeyboard, WeChatFocusClearance.allowsAnotherAttempt(nudgeAttempts) {
                            guard let focused = focusedNode(),
                                  let nudged = try nudgeOlder(from: focused, ordinal: limit - 1, list: page.list, forced: true, attempt: nudgeAttempts) else {
                                throw WeChatAutomationError.selection
                            }
                            nudgeAttempts += 1
                            page = try pageAfterScroll()
                            if let idx = indexOfFocus(nudged, in: page) {
                                tracked = WeChatViewport(rows: page.data, anchorIndex: idx, anchorOrdinal: limit - 1)
                            }
                            continue
                        }
                        if target == 0 || page.rows[target - 1].rect.minY < page.list.rect.minY {
                            try pause(0.15)
                            let again = try rangeControl()
                            noteRangeControl(again)
                            if capped(again) { observe("range-cap", page); throw WeChatAutomationError.selection }
                            continue
                        }
                    } else if WeChatRangeControlLabel.parse(button.strings) == .selectHere {
                        noteRangeControl(button)
                        observe("before-range", page)
                        try press(button)
                        rangeClicks += 1
                        return try commitRange(page: page, tracked: tracked, limit: limit, usedKeyboard: usedKeyboard, conversationEnded: conversationEnded, pageSettled: true)
                    }
                }
                if usedKeyboard, WeChatFocusClearance.olderNudge(rowY: row.rect.minY, listTop: page.list.rect.minY) != nil {
                    // Qt pins this keyboard row to the top and absorbs a nudge of
                    // a few points, so the range button never becomes usable and
                    // a three-try budget stops the batch. Ask for about one row.
                    // The scroll below still has to keep this same message in
                    // focus; a miss is the loop's ordinary overshoot, not a stop.
                    let points = WeChatFocusClearance.pinnedClearance(rowHeight: Double(row.rect.height))
                    delta = WeChatNudge.units(points: points, gain: gain, limit: WeChatFocusClearance.pinnedScrollLimit, maxUnits: 100)
                } else {
                    let distance = page.list.rect.minY + 8 - row.rect.minY
                    let amount = Int((distance / max(1, gain)).rounded())
                    delta = Int32(max(-250, min(250, amount == 0 ? (distance >= 0 ? 1 : -1) : amount)))
                }
            }
            let before = page
            try scroll(page.list.element, delta: delta, settle: gesturePause)
            page = try settledScrollPage()
            unchanged = page.signature == before.signature ? unchanged + 1 : 0
            guard unchanged < 3 else {
                // The list is not moving. That is either WeChat fetching more
                // history above, or the conversation's first message sitting
                // at the top of it. The first is temporary — a completed
                // fetch lets the next gesture move again — so confirm the top
                // before reading this as a short conversation. Confirmed, the
                // oldest row the tracker holds is the first message: degrade
                // the batch to what exists and let the range selection below
                // end on that row, exactly as it would have on the requested
                // one. `unchanged` keeps its count: the degraded endpoint is
                // on screen now, and the loop's own cap still bounds a
                // selection that keeps stalling.
                switch try confirmConversationTop(page, stalledSettled: true) {
                case .top(let atTop, _):
                    // `rows[0]` holds ordinal `firstOrdinal`, the conversation's
                    // first message now that the top is proven.
                    let existing = tracked.firstOrdinal + 1
                    if existing < limit {
                        steps.append(["kind": "short-conversation", "via": "wheel", "reached": existing])
                        conversationEnded = true
                        limit = existing
                        page = atTop
                        budget.forgivesRepeat = true
                        do { try tracked.resume(atTop.data) } catch { throw WeChatAutomationError.selection }
                        if existing == 1 {
                            return Selection(count: 1, checkpoint: try checkpoint(tracked, page: page), reachedConversationTop: true, boundaryConfirmed: true)
                        }
                        continue
                    }
                case .moved(let resumed):
                    // A slow load finished during the probe. Take the page it
                    // reached and keep walking; the tracker rebinds the same
                    // way it does after an ordinary scroll.
                    page = resumed
                    do { try tracked.advance(resumed.data, older: true) } catch { throw WeChatAutomationError.selection }
                    unchanged = 0
                    continue
                case .stuck:
                    break
                }
                throw WeChatAutomationError.historyUnconfirmed
            }
            // The keyboard row is this batch's endpoint. A burst of photos from
            // one sender reads the same whether the nudge moved the list or not,
            // and taking it as unmoved counted the batch past a hundred.
            if !pinKeyboardRow(&tracked, page: page, ordinal: usedKeyboard ? limit - 1 : nil) {
                do { try tracked.advance(page.data, older: delta > 0) }
                catch {
                    // The step outran the tracker: nothing in the new view is also
                    // in the old one. Scrolling back the same amount returns to a
                    // view the tracker still recognises, so a step that reached too
                    // far costs one extra step instead of the whole selection.
                    guard overshoots < 2 else { throw WeChatAutomationError.selection }
                    overshoots += 1
                    reachFactor = max(0.4, reachFactor / 2)
                    try scroll(page.list.element, delta: -delta)
                    page = try stablePage()
                    do { try tracked.advance(page.data, older: delta < 0) }
                    catch { throw WeChatAutomationError.selection }
                    continue
                }
            }
            let measured = abs(tracked.lastDisplacement / Double(delta))
            if steps.count < 200 {
                steps.append(["delta": Int(delta), "moved": Int(tracked.lastDisplacement.rounded()),
                              "gain": (measured * 100).rounded() / 100, "pause": (gesturePause * 100).rounded() / 100,
                              "ordinal": tracked.firstOrdinal, "want": limit - 1])
            }
            try updatePacing(gain: measured)
            if WeChatScrollStep.isPlausible(gain: measured) {
                gain = measured; gainMeasured = true
                reachFactor = min(1, reachFactor * 1.5)
            }
        }
    }

    /// The forward sheet, once it has finished arriving.
    ///
    /// Waited for rather than sampled: 取消 is up before the sheet has settled,
    /// and one look immediately after it has been seen to find no 确定 at all
    /// and call the layout unsupported for a sheet that was merely animating.
    ///
    /// 确定 must still be disabled. It enables the moment a recipient is
    /// selected, so requiring it off is also the check that nothing has been
    /// selected by accident before this clicks anything.
    private func recipientSheet(timeout: Double = 2) throws -> (WCNode, WCNode, WCNode) {
        let deadline = clock() + timeout
        repeat {
            let nodes = try scan()
            if let cancel = nodes.first(where: { $0.id == "cancel_btn" }),
               let confirm = nodes.first(where: { $0.id == "confirm_btn" }), !confirm.enabled {
                var current = cancel.element
                for _ in 0..<10 {
                    let node = WCNode(current)
                    if node.role == "AXSheet", node.rect.contains(cancel.rect), node.rect.contains(confirm.rect) { return (node, cancel, confirm) }
                    guard let parent = wcAttribute(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    current = parent as! AXUIElement
                }
            }
            try pause(0.04)
        } while clock() < deadline
        recordControlFailure("recipient-sheet")
        throw WeChatAutomationError.unsupportedLayout
    }

    /// Where 转发到其他应用 is, from the shape of the list it lives in.
    ///
    /// The row sits in the recipient list, below whatever promotions WeChat is
    /// showing and above the contacts. There is one promotion per companion app
    /// installed — 企业微信, WorkBuddy — so there may be none, one or two of
    /// them, and the row moves down by one strip for each. A fixed offset from
    /// the sheet could only ever match one of those: this machine has one
    /// promotion, macOS 26 with none put the row 125 points higher, and the old
    /// offset landed in the contact list, which is a click that selects a
    /// person rather than one that misses.
    ///
    /// What does hold across all three is the order and the labels. Promotions
    /// and the tab row carry no accessibility label; every contact carries its
    /// name. So the tab row is the last unlabelled row before the first labelled
    /// one, however many strips are stacked above it — checked against this
    /// machine, where it lands on exactly the point the old offset computed.
    ///
    /// Horizontally the row is 最近聊天 | 创建聊天 | 转发到其他应用 and this is
    /// the third of them, 245 points into the 320 the list is wide. That
    /// proportion does not move with the promotions; only the row does.
    private func externalShareRow(in nodes: [WCNode]) -> CGPoint? {
        guard let list = nodes.first(where: { $0.id == "sp_to_select_contact_list" }), !list.rect.isEmpty else { return nil }
        // Only the head of the list matters, and reading every contact would be
        // one cross-process read per person in the address book.
        let rows = list.children.prefix(12).map(WCNode.init)
            .filter { $0.role == "AXCheckBox" && !$0.rect.isEmpty }
            .sorted { $0.rect.minY < $1.rect.minY }
        guard let firstNamed = rows.firstIndex(where: { !$0.strings.isEmpty }), firstNamed > 0 else { return nil }
        let tabs = rows[firstNamed - 1]
        guard tabs.rect.width > 0, list.rect.contains(tabs.rect) else { return nil }
        return CGPoint(x: tabs.rect.minX + tabs.rect.width * 0.766, y: tabs.rect.midY)
    }

    /// Where 转发到其他应用 is, read off the sheet.
    ///
    /// WeChat draws this row itself: it is in neither of the two conversations
    /// this has been tried against, by role or by text, so there is nothing to
    /// press and nothing to measure from. It has to be looked at.
    ///
    /// It used to be a measured offset from the sheet's corner, which cost no
    /// permission and was only ever right by luck. What sits above the row is a
    /// stack of promotions for whatever else the user has installed — 企业微信,
    /// WorkBuddy — so the row moves down by one strip per promotion, and the
    /// developer's own machine happened to have exactly one. macOS 26 with none
    /// of them put the row 125 points above where the offset aimed, which on
    /// that layout is inside the recipient list: not a click that misses, a
    /// click that selects somebody. The sheet's outer size and its buttons stay
    /// where they were through all of it, so no check on the outline can tell
    /// the layouts apart.
    private func externalSharePoint(_ sheet: WCNode) throws -> CGPoint {
        guard CGPreflightScreenCaptureAccess() else { throw WeChatAutomationError.screenRecording }
        let started = clock()
        // The left column, down far enough to still contain the row when the
        // promotions above it are at their tallest. Each installed companion
        // app (企业微信, WorkBuddy) adds a strip of about 125 points, and two of
        // them push the row to roughly 330 — past the 269 this used to read,
        // which would have found nothing and reported an unsupported layout.
        // Reading more costs a few milliseconds; the recipient names it takes
        // in cannot be mistaken for the label being searched for.
        let crop = CGRect(x: floor(sheet.rect.minX), y: floor(sheet.rect.minY),
                          width: floor(sheet.rect.width * 0.45), height: floor(sheet.rect.height * 0.78))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xiaoai-archive-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("control.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(Int(crop.minX)),\(Int(crop.minY)),\(Int(crop.width)),\(Int(crop.height))", url.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try frontmost()
        try process.run()
        let deadline = clock() + 5
        while process.isRunning && clock() < deadline {
            do { try pause(0.04) } catch { process.terminate(); throw error }
        }
        if process.isRunning { process.terminate(); throw WeChatAutomationError.unsupportedLayout }
        guard process.terminationStatus == 0 else { throw WeChatAutomationError.unsupportedLayout }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // One fixed Chinese label. Latin script and the language model that
        // second-guesses words are both work for a phrase that is either there
        // exactly or is not the one being looked for.
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = false
        request.customWords = ["转发到其他应用"]
        try VNImageRequestHandler(url: url).perform([request])
        let matches = (request.results ?? []).filter { observation in
            observation.topCandidates(3).contains { $0.string.filter { !$0.isWhitespace } == "转发到其他应用" }
        }
        guard matches.count == 1, let match = matches.first,
              try recipientSheet().0.rect == sheet.rect else { throw WeChatAutomationError.unsupportedLayout }
        visualMilliseconds += (clock() - started) * 1000
        locator = "cropped-vision"
        return CGPoint(x: crop.minX + match.boundingBox.midX * crop.width, y: crop.minY + (1 - match.boundingBox.midY) * crop.height)
    }

    private func readyIDs(at ready: URL) throws -> Set<String> {
        var retries = 0
        while true {
            try check()
            do {
                return Set(try FileManager.default.contentsOfDirectory(at: ready, includingPropertiesForKeys: nil).map(\.lastPathComponent).filter { UUID(uuidString: $0) != nil })
            } catch {
                let cocoa = error as NSError
                let causes = [cocoa, cocoa.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
                // Foundation can wrap readdir's EINTR in NSFileReadUnknownError.
                // Retrying this read does not repeat any sharing UI action.
                guard retries < 3, causes.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EINTR) }) else { throw error }
                retries += 1
                receiptReadRetries += 1
                try pause(0.002)
            }
        }
    }

    private func nativeExport(ready: URL, shelfExtension: URL) throws -> URL {
        phase = "export"
        let exportStarted = clock()
        defer { exportSeconds += clock() - exportStarted }
        func ids() throws -> Set<String> {
            try readyIDs(at: ready)
        }
        let baseline = try ids()
        let failures = ready.deletingLastPathComponent()
            .appendingPathComponent(ShareFailure.directoryName, isDirectory: true)
        let failureBaseline = Set(try FileManager.default.contentsOfDirectory(at: failures, includingPropertiesForKeys: nil))
        let installed = Bundle(url: shelfExtension)
        guard installed?.bundleIdentifier == "dev.dukou.Dukou.Share", installed?.object(forInfoDictionaryKey: "DKShareAction") as? String == "shelf" else { throw WeChatAutomationError.missingShare }
        try press(try waitControl("合并转发"))
        // Qt's toolbar button can answer AXPress with success and leave the
        // multi-select bar where it is. 取消 belongs to the forward sheet, so
        // a bar that is still showing 合并转发 means the press did not happen.
        do {
            _ = try waitControl("取消", timeout: 1.5)
        } catch let error as WeChatAutomationError {
            guard case .control = error else { throw error }
            let nodes = try scan()
            guard let button = control("合并转发", in: nodes) else { throw error }
            let label = nodes.first {
                $0.role == "AXStaticText" && !$0.rect.isEmpty && $0.strings.contains("合并转发")
            }
            let rect = label?.rect ?? button.rect
            try click(CGPoint(x: rect.midX, y: rect.midY))
            _ = try waitControl("取消")
        }
        let sheetNodes = try scan()
        // Worth asking twice before falling back to geometry: whatever the row
        // is dressed as, being able to press it directly beats aiming at it.
        if let external = control("转发到其他应用", in: sheetNodes) ?? looseControl("转发到其他应用", in: sheetNodes) {
            locator = "accessibility"
            try press(external)
        } else if let row = externalShareRow(in: sheetNodes) {
            locator = "list-row"
            try click(row)
        } else {
            // Last resort, and the only path that costs a permission: the list
            // is not shaped the way any build so far has shaped it.
            // recipientSheet also asserts 确定 is still disabled, so a stray
            // selection would be caught before anything is clicked.
            let (sheet, _, _) = try recipientSheet()
            try click(try externalSharePoint(sheet))
        }
        // Never retry a possibly successful click. Verify the next UI state.
        try press(try waitControl("选择电脑中的应用"))
        var share: WCNode?
        let deadline = clock() + 4
        repeat {
            try frontmost()
            let menu = try scan()
            share = control("暂存到 xiaoai-archive", in: menu) ?? control("添加到 xiaoai-archive", in: menu) ?? control("Stash in xiaoai-archive", in: menu)
            if share != nil { break }
            try pause(0.02)
        } while clock() < deadline
        guard let share else { throw WeChatAutomationError.missingShare }
        try press(share)
        progress(L10n.text("正在等待微信导出文件…"))
        let receiptDeadline = clock() + 45
        repeat {
            let failureFiles = try FileManager.default.contentsOfDirectory(at: failures, includingPropertiesForKeys: nil)
            for file in failureFiles where file.pathExtension == "json" && !failureBaseline.contains(file) {
                let failure = try BatchManifest.decoder().decode(ShareFailure.self, from: Data(contentsOf: file))
                guard failure.action == .shelf else { continue }
                try FileManager.default.removeItem(at: file)
                throw failure
            }
            let candidates = try ids().subtracting(baseline)
            guard candidates.count <= 1 else { throw WeChatAutomationError.ambiguousReceipt }
            if let id = candidates.first {
                let directory = ready.appendingPathComponent(id)
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
                    exportCount += 1
                    // Close a remaining recipient sheet. External sharing may
                    // also exit multi-select; the next stage observes that
                    // transition and rebinds the saved ordered viewport.
                    if let cancel = try scan().first(where: { $0.id == "cancel_btn" }) { try press(cancel) }
                    return directory
                }
            }
            try pause(0.02)
        } while clock() < receiptDeadline
        throw WeChatAutomationError.receiptTimeout
    }

    private func restoreSelection() throws {
        try verifyChat()
        if let cancel = try scan().first(where: { $0.id == "cancel_btn" }) { try press(cancel) }
        if let cancel = control("取消多选", in: try scan()) { try press(cancel) }
        let deadline = clock() + 2
        while control("合并转发", in: try scan()) != nil && clock() < deadline { try pause(0.05) }
        guard control("合并转发", in: try scan()) == nil else { throw WeChatAutomationError.selection }
        ownsSelection = false
    }

    private func cleanup() {
        cleaningUp = true
        defer { cleaningUp = false }
        guard ownsSelection, (try? verifyChat()) != nil else { return }
        try? restoreSelection()
    }

    private func diagnostics(started: Double, outcome: String, count: Int) {
        let report: [String: Any] = ["schemaVersion": 9, "strategy": "native-keyboard-range", "at": ISO8601DateFormatter().string(from: Date()),
            "outcome": outcome, "phase": phase, "seconds": clock() - started, "messageCount": count,
            "navigationKeys": navigationKeys, "keyboardMessages": keyboardMessages, "keyboardTargetReached": keyboardTargetReached,
            "focusedMessage": focusedMessageLog, "snapshotRejectReason": snapshotRejectReason,
            "historyBoundary": historyBoundaryLog,
            "prefetchExit": prefetchExit, "pacingEvents": pacingEvents,
            "scrollPause": gesturePause, "scrollCeiling": Int(deltaCeiling),
            "stopReason": stopReason?.rawValue ?? "none",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "recoveryAttempts": recoveryAttempts, "rangeControlState": rangeControlState, "boundaryStopped": boundaryStopped,
            "scrolls": scrollCount, "scrollSeconds": scrollSeconds, "scanSeconds": scanSeconds, "scanCalls": scanCalls, "stableSeconds": stableSeconds, "exportSeconds": exportSeconds, "prefetchSeconds": prefetchSeconds, "prefetchRows": prefetchRows, "prefetchLoaded": prefetchLoaded, "scrollsByPhase": scrollsByPhase, "steps": steps, "clicks": clickCount, "rangeClicks": rangeClicks, "shiftRangeClicks": shiftRangeClicks, "exports": exportCount, "resumedBatches": resumedBatches, "keyboardPins": keyboardPins,
            "snapshots": snapshots, "receiptReadRetries": receiptReadRetries,
            "locator": locator, "visualMilliseconds": visualMilliseconds, "lastNodeCount": lastNodeCount,
            "scanTruncated": scanTruncated, "controlFailure": controlFailure ?? [:],
            "wechatVersion": app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "unknown"]
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/xiaoai-archive/WeChat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("latest.json"), options: .atomic)
        }
    }

    func capture(range: WeChatForwardRange, ready: URL, shelfExtension: URL, identifySelf: Bool = false, checkpoint: WeChatArchiveCheckpoint? = nil) throws -> WeChatCapture {
        guard range.unit == .messages else { throw WeChatAutomationError.timeRangeUnavailable }
        guard range.isValid else { throw WeChatAutomationError.selection }
        let started = clock()
        var count = 0, selectedCount = 0, outcome = "failed"
        defer { cleanup(); diagnostics(started: started, outcome: outcome, count: count) }
        progress(L10n.text("正在打开微信群聊…"))
        try openChat()
        let selfSender = identifySelf ? try currentAccountNickname() : nil
        // Plan once, outside the batch loop. Ordinary long exports warm only
        // a bounded initial window, so a multi-year chat can start producing
        // native ZIPs without first materialising its entire client history.
        // Incremental runs remain bounded by their existing 40-batch overlap.
        let latestPage: Page?
        if let goal = WeChatPrefetchPlan.goal(requestedMessages: range.value, incremental: checkpoint != nil) {
            latestPage = try bestEffortPrefetch(goal: goal)
        } else { latestPage = nil }
        var directories: [URL] = []
        var batchMessageCounts: [Int] = []
        var start = SelectionStart.latest
        var conversationEnded = false
        var reachedHistoryStart = false
        var chronological: [WeChatTranscriptRecord] = []
        var increment: WeChatIncrementCut?
        let maximumIncrementalBatches = 40
        while !conversationEnded {
            try verifyChat()
            let limit = checkpoint == nil
                ? (range.isUnlimited ? 100 : min(100, range.value - selectedCount))
                : 100
            // Prefetch returns to the live bottom. Doing it between batches
            // destroys the saved endpoint, and latestPage is not even consumed
            // by .resume. Only the initial batch may receive a warmed page.
            let warmPage = selectedCount == 0 ? latestPage : nil
            progress(L10n.format("正在选择消息 · 已导出约 %d 条", count))
            let selected: Selection
            do {
                selected = try selectBatch(limit: limit, start: start, latestPage: warmPage)
            } catch is ReachedHistoryStart {
                guard !directories.isEmpty, checkpoint == nil else { throw WeChatAutomationError.incrementUnconfirmed }
                reachedHistoryStart = true
                break
            } catch let error as WeChatAutomationError {
                // Keep and deliver committed batches, but never mark a partial
                // run as complete or advance an incremental checkpoint.
                switch error {
                case .historyUnconfirmed, .historyIncomplete, .selection, .loading, .historyLoadingTimeout, .scrollStalled:
                    guard !directories.isEmpty, checkpoint == nil else { throw error }
                    switch error {
                    case .loading, .historyLoadingTimeout: stopReason = .historyLoadingTimeout
                    case .scrollStalled: stopReason = .scrollStalled
                    default: stopReason = phase == "next-batch-anchor" ? .nextBatchAnchor : .rangeEndpoint
                    }
                    boundaryStopped = stopReason?.isBoundary == true
                    steps.append(["kind": "partial-capture", "batches": directories.count, "counted": selectedCount, "reason": stopReason?.rawValue ?? "unknown"])
                    break
                default: throw error
                }
                break
            }
            progress(L10n.format("已选中 %d 条消息，正在导出…", selected.count))
            let directory = try nativeExport(ready: ready, shelfExtension: shelfExtension)
            start = .resume(selected.checkpoint, ordinal: selected.count)
            phase = "archive"
            let exportedCount = try WeChatArchive.messageCount(directory: directory, cancellation: cancellation)
            let counted = ForwardArchiveName.reportedCount(parsed: exportedCount, fallback: selected.count) ?? selected.count
            steps.append(["kind": "archive", "selected": selected.count,
                          "messages": counted, "estimated": exportedCount == nil || exportedCount == 0,
                          "boundaryConfirmed": selected.boundaryConfirmed,
                          "parsedMismatch": exportedCount.map { $0 != selected.count } ?? false])
            directories.append(directory)
            batchMessageCounts.append(counted)
            // Selection controls navigation and when to stop. A parsed count
            // that differs from the selection describes the payload; it does
            // not discard the ZIP or start another pass over the same rows.
            // It also does not invent a resume point the viewport never proved.
            // A parsed zero is not the file's count: 0 in the form means the
            // whole conversation, and the name has to say how many were exported.
            selectedCount += selected.count
            count += counted
            if let checkpoint {
                guard let records = try WeChatArchive.records(directory: directory, cancellation: cancellation) else {
                    throw WeChatAutomationError.incrementUnconfirmed
                }
                // This batch is older than the ones already exported. The
                // archived tail is matched against the whole run, not one ZIP.
                chronological = records + chronological
                switch WeChatIncrement.assess(checkpoint: checkpoint, records: chronological) {
                case .keepCollecting:
                    if !selected.boundaryConfirmed || selected.reachedConversationTop || directories.count >= maximumIncrementalBatches {
                        throw WeChatAutomationError.incrementUnconfirmed
                    }
                case .ready(let cut):
                    increment = cut
                    steps.append(["kind": "increment", "drop": cut.dropPrefix, "retained": cut.retained, "overlap": cut.overlap])
                    conversationEnded = true
                case .uncertain:
                    throw WeChatAutomationError.incrementUnconfirmed
                }
            }
            let requestSatisfied = checkpoint == nil && !range.isUnlimited && selectedCount >= range.value
            if selected.reachedConversationTop { reachedHistoryStart = true }
            if checkpoint == nil, WeChatBatchBoundary.warnStoppedEarly(boundaryConfirmed: selected.boundaryConfirmed, reachedHistoryStart: selected.reachedConversationTop, requestSatisfied: requestSatisfied) {
                boundaryStopped = true
                stopReason = .rangeEndpoint
            }
            if checkpoint == nil {
                conversationEnded = !WeChatBatchBoundary.resumeNextBatch(boundaryConfirmed: selected.boundaryConfirmed, reachedHistoryStart: selected.reachedConversationTop) || requestSatisfied
            } else if selected.reachedConversationTop, increment == nil {
                throw WeChatAutomationError.incrementUnconfirmed
            }
        }
        phase = "complete"; outcome = (boundaryStopped || stopReason != nil) ? "stopped" : "exported"
        return WeChatCapture(directories: directories, batchMessageCounts: batchMessageCounts, messageCount: count, readSeconds: 0, captureSeconds: clock() - started,
                             selfSender: selfSender, boundaryStopped: boundaryStopped, stopReason: stopReason, reachedHistoryStart: reachedHistoryStart, increment: increment)
    }
}
