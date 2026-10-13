import AppKit
import Combine
import DukouCore

@MainActor
final class WeChatQuickForward: ObservableObject {
    @Published var draft: WeChatForwardPreset { didSet { stored.draft = draft; persist() } }
    @Published private(set) var recent: [WeChatForwardPreset]
    @Published private(set) var applications: [RunningApp] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isReadingChat = false
    @Published private(set) var isReadingChatList = false
    @Published private(set) var chatList: WeChatChatList?
    @Published private(set) var chatListError: String?
    @Published private(set) var batchMode = false
    @Published private(set) var batchAmountText = "100"
    @Published private(set) var batchRows: [WeChatBatchRow] = []
    @Published private(set) var status: String? {
        didSet { if isBusy, let status { hud.update(status: displayedStatus(status)) } }
    }
    @Published private(set) var error: String?
    @Published private(set) var elapsedSeconds: Double?

    private static let key = "wechatQuickForward.v1"
    private static let worker = DispatchQueue(label: "dev.dukou.wechat.accessibility", qos: .userInitiated)
    private let defaults: UserDefaults
    private var stored: WeChatForwardPreferences
    private let model: AppModel
    private let shelf: ShelfController
    private let runner: ActionRunner
    private let authorization: AccessibilityAuthorization
    private let preferences: Preferences
    private var cancellation: WeChatCancellation?
    private var lastFolder: URL?
    private var lastTarget: (id: String, name: String, pastePath: Bool)?
    private var statusExpiry: Task<Void, Never>?
    private var batchPrefix: String?
    private var observers = Set<AnyCancellable>()
    /// Only a full forward raises it. `readCurrentChat` is one AX read with no
    /// synthesized input, so there is nothing to keep the user's hands off.
    private let hud = AutomationHUD()
    /// Set by the app delegate, like `ActionRunner.openEntries`: a failure
    /// capsule over another app needs somewhere to send the user.
    var openSettings: ((SettingsTab) -> Void)?
    var otherAutomationIsBusy: () -> Bool = { false }
    var hudFrame: NSRect? { hud.frame }

    init(model: AppModel, shelf: ShelfController, runner: ActionRunner, authorization: AccessibilityAuthorization, preferences: Preferences, defaults: UserDefaults = .standard) {
        self.model = model; self.shelf = shelf; self.runner = runner; self.authorization = authorization; self.preferences = preferences; self.defaults = defaults
        stored = WeChatForwardPreferences.decode(defaults.data(forKey: Self.key))
        draft = stored.draft
        recent = stored.recent
        refreshApplications()
        runner.reservedFrame = { [weak self] in self?.hud.frame }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshApplications() }
                .store(in: &observers)
        }
    }

    var canRun: Bool {
        guard !isBusy, !isReadingChat, !isReadingChatList, !otherAutomationIsBusy(),
              draft.destinationFolder.map(\.isFileURL) ?? applications.contains(where: { $0.id == draft.targetBundleIdentifier }) else { return false }
        if !batchMode {
            return !WeChatForwardPreset.normalizedChat(draft.chat).isEmpty && draft.range.isAvailableForAutomation
        }
        let pending = batchRows.filter { $0.isSelected && $0.state != .completed }
        return !pending.isEmpty && pending.allSatisfy { batchCount(id: $0.id) != nil && uniqueBatchChat($0.chat) }
    }

    var selectedBatchCount: Int { batchRows.filter(\.isSelected).count }
    var canResumeBatch: Bool {
        batchRows.contains { $0.isSelected && ($0.state == .failed || $0.state == .cancelled) } ||
        (batchRows.contains { $0.isSelected && $0.state == .completed } &&
         batchRows.contains { $0.isSelected && $0.state == .waiting })
    }
    var startTitle: String {
        if !batchMode { return draft.destinationFolder == nil ? L10n.text("开始转发") : L10n.text("开始保存") }
        if canResumeBatch { return L10n.text("继续未完成的群聊") }
        return draft.destinationFolder == nil ? L10n.text("开始批量转发") : L10n.text("开始批量保存")
    }
    var progressStatus: String? { status.map(displayedStatus) }

    func setBatchMode(_ enabled: Bool) {
        guard !isBusy, !isReadingChat, !isReadingChatList else { return }
        batchMode = enabled
        error = nil; status = nil
    }

    func setBatchAmount(_ text: String) {
        guard !isBusy else { return }
        let digits = WeChatForwardRange.digits(text, preserveZero: true)
        guard digits != batchAmountText else { return }
        batchAmountText = digits
        for index in batchRows.indices where batchRows[index].countText.isEmpty {
            resetBatchRow(at: index)
        }
        error = nil
    }

    func batchCount(id: String) -> Int? {
        guard let row = batchRows.first(where: { $0.id == id }),
              let count = Int(row.countText.isEmpty ? batchAmountText : row.countText), count >= 0 else { return nil }
        return count
    }

    func setBatchSelected(id: String, selected: Bool) {
        guard !isBusy, let index = batchRows.firstIndex(where: { $0.id == id }) else { return }
        guard batchRows[index].isSelected != selected else { return }
        batchRows[index].isSelected = selected
        if selected { resetBatchRow(at: index) }
        error = nil
    }

    func setBatchCount(id: String, text: String) {
        guard !isBusy, let index = batchRows.firstIndex(where: { $0.id == id }) else { return }
        let digits = WeChatForwardRange.digits(text, preserveZero: true)
        guard digits != batchRows[index].countText else { return }
        batchRows[index].countText = digits
        resetBatchRow(at: index)
        error = nil
    }

    func selectAllBatchRows(_ selected: Bool) {
        guard !isBusy else { return }
        for index in batchRows.indices {
            batchRows[index].isSelected = selected
            if selected { resetBatchRow(at: index) }
        }
        error = nil
    }

    func applyBatchAmount() {
        guard !isBusy, let count = Int(batchAmountText), count >= 0 else { return }
        for index in batchRows.indices where batchRows[index].isSelected {
            batchRows[index].countText = ""
            resetBatchRow(at: index)
        }
        error = nil
    }

    func useBatchRow(id: String) {
        guard !isBusy, let row = batchRows.first(where: { $0.id == id }), let count = batchCount(id: id) else { return }
        batchMode = false
        draft.chat = row.chat
        draft.range = .init(unit: .messages, value: count)
        error = nil; status = nil
    }

    private func resetBatchRow(at index: Int) {
        batchRows[index].state = .waiting
        batchRows[index].detail = nil
    }

    private func uniqueBatchChat(_ name: String) -> Bool {
        let normalized = WeChatForwardPreset.normalizedChat(name)
        return !normalized.isEmpty && batchRows.filter {
            WeChatForwardPreset.normalizedChat($0.chat) == normalized
        }.count == 1
    }

    private func displayedStatus(_ message: String) -> String {
        batchPrefix.map { $0 + " · " + message } ?? message
    }
    func refreshApplications() {
        applications = RunningApp.current(excluding: [Bundle.main.bundleIdentifier ?? "dev.dukou.Dukou", WeChatAccessibility.bundleIdentifier, "com.apple.finder"])
    }
    func chooseTarget(_ id: String) {
        guard !isBusy, let app = applications.first(where: { $0.id == id }) else { return }
        var preset = draft
        preset.targetBundleIdentifier = app.id
        preset.targetName = app.name
        preset.destinationFolder = nil
        draft = preset
        error = nil
    }
    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = L10n.text("选择文件夹")
        panel.directoryURL = draft.destinationFolder
        guard panel.runModal() == .OK, let folder = panel.url, !isBusy else { return }
        save(to: folder)
    }
    private func save(to folder: URL) {
        if draft.destinationFolder == nil, !draft.targetBundleIdentifier.isEmpty {
            lastTarget = (draft.targetBundleIdentifier, draft.targetName, draft.pastePath)
        }
        var preset = draft
        preset.destinationFolder = folder
        preset.targetBundleIdentifier = ""
        preset.targetName = ""
        preset.pastePath = false
        draft = preset
        error = nil
    }
    /// The two halves of 送到. A preset holds one destination, so flipping
    /// between them would otherwise forget the other side each time; what was
    /// there is kept for as long as the window is, which is as long as anyone
    /// flips back and forth.
    func showApplications() {
        guard !isBusy, let folder = draft.destinationFolder else { return }
        lastFolder = folder
        var preset = draft
        preset.destinationFolder = nil
        if let lastTarget {
            preset.targetBundleIdentifier = lastTarget.id
            preset.targetName = lastTarget.name
            preset.pastePath = lastTarget.pastePath
        }
        draft = preset
        error = nil
    }
    func showFolder() {
        guard !isBusy, draft.destinationFolder == nil else { return }
        if let lastFolder { save(to: lastFolder) } else { chooseFolder() }
    }
    func use(_ preset: WeChatForwardPreset) { guard !isBusy else { return }; batchMode = false; draft = preset; error = nil }
    /// The amount field's text. Held as a count, shown as digits, and filtered
    /// on the way in so the field can never carry something the range cannot be
    /// made of. Empty reads as zero, which the form marks invalid rather than
    /// silently correcting.
    /// Zero stays visible as "0": it is the whole-conversation mode, not an
    /// empty field, and erasing it on the way out would make the field fight
    /// the user typing it.
    var amountText: String {
        draft.range.isUnlimited ? "0" : draft.range.value > 0 ? String(draft.range.value) : ""
    }
    func setAmount(_ text: String) {
        guard !isBusy else { return }
        draft.range.value = Int(WeChatForwardRange.digits(text, preserveZero: true)) ?? 0
    }
    func useMessageCount() {
        guard !isBusy else { return }
        draft.range = .init(unit: .messages, value: 100)
        error = nil; status = nil
    }
    func forget(_ preset: WeChatForwardPreset) {
        stored.recent.removeAll { $0.id == preset.id }
        recent = stored.recent
        persist()
    }
    private func persist() { if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) } }

    func readCurrentChat() {
        guard !isBusy, !isReadingChat, !isReadingChatList, !otherAutomationIsBusy() else { return }
        authorization.refresh()
        guard authorization.isTrusted else { authorization.guideIfNeeded(); return }
        isReadingChat = true; error = nil
        Task {
            defer { isReadingChat = false }
            do {
                let chat: String = try await withCheckedThrowingContinuation { continuation in
                    Self.worker.async { continuation.resume(with: Result { try WeChatAccessibility.currentChat() }) }
                }
                draft.chat = chat
            } catch { self.error = error.localizedDescription }
        }
    }

    func readCurrentChatList() {
        guard !isBusy, !isReadingChat, !isReadingChatList, !otherAutomationIsBusy() else { return }
        chatList = nil
        chatListError = nil
        batchRows = []
        authorization.refresh()
        guard authorization.isTrusted else {
            chatListError = WeChatChatListReader.Failure.permissionRequired.localizedDescription
            return
        }
        isReadingChatList = true
        Task {
            defer { isReadingChatList = false }
            do {
                let result: WeChatChatList = try await withCheckedThrowingContinuation { continuation in
                    Self.worker.async { continuation.resume(with: Result { try WeChatChatListReader.read() }) }
                }
                chatList = result
                batchRows = result.entries.map { WeChatBatchRow(id: $0.id, chat: $0.name, isConfirmedGroup: $0.isConfirmedGroup) }
            } catch {
                chatListError = error.localizedDescription
            }
        }
    }

    func cancel() {
        // The HUD stays clickable for its fade-out, which starts before
        // `isBusy` clears. Without this, a late click on 取消 overwrote the
        // final status with 「正在停止…」 for a run that had already finished.
        guard isBusy, cancellation != nil else { return }
        cancellation?.cancel()
        status = L10n.text("正在停止…")
    }

    func start(_ saved: WeChatForwardPreset? = nil) {
        guard !isBusy, !isReadingChat, !isReadingChatList, !otherAutomationIsBusy() else { return }
        if let saved { batchMode = false; draft = saved }
        refreshApplications()
        if batchMode {
            guard canRun else {
                error = L10n.text("请勾选名称唯一的群聊，填写有效条数，并选择输出位置。")
                return
            }
            let jobs = batchRows.filter { $0.isSelected && $0.state != .completed }.map { row in
                var preset = draft
                preset.chat = WeChatForwardPreset.normalizedChat(row.chat)
                preset.range = .init(unit: .messages, value: batchCount(id: row.id)!)
                preset.incremental = false
                return (id: Optional(row.id), preset: preset)
            }
            startJobs(jobs)
            return
        }
        guard draft.range.unit == .messages else {
            status = nil
            error = WeChatAutomationError.timeRangeUnavailable.localizedDescription
            return
        }
        guard canRun else {
            error = L10n.text("请填写群名和有效范围，并选择一个正在运行的应用或文件夹。")
            return
        }
        if draft.incremental, preferences.archiveCheckpoints.checkpoint(for: draft.chat) == nil {
            error = WeChatAutomationError.incrementNeedsBaseline.localizedDescription
            return
        }
        var preset = draft
        preset.chat = WeChatForwardPreset.normalizedChat(preset.chat)
        startJobs([(id: nil, preset: preset)])
    }

    private func startJobs(_ jobs: [(id: String?, preset: WeChatForwardPreset)]) {
        let first = jobs[0]
        authorization.refresh()
        guard authorization.isTrusted else { authorization.guideIfNeeded(); return }
        guard model.inbox != nil else { error = InboxError.inboxUnavailable.localizedDescription; return }
        let targetPID: pid_t?
        if first.preset.destinationFolder != nil {
            targetPID = nil
        } else {
            guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: first.preset.targetBundleIdentifier).first else { return }
            targetPID = target.processIdentifier
        }
        let token = WeChatCancellation()
        cancellation = token
        isBusy = true; error = nil; elapsedSeconds = nil
        let opening = first.preset.destinationFolder == nil ? L10n.text("等待开始微信转发…") : L10n.text("等待开始保存微信记录…")
        status = opening
        // The previous run's failure capsule is in the corner this is about to
        // take, and 再次执行 is usually clicked while it is still standing there.
        runner.dismissNotice()
        // Up before the first synthesized event, not when the automation gets
        // around to WeChat: the run may sit in `enqueueExclusive` behind a
        // share, and the seconds where nothing appears to be happening are
        // exactly the ones where the user reaches for the mouse.
        hud.show(status: opening) { [weak self] in self?.cancel() }
        let requestedAt = Date()
        runner.enqueueExclusive { [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            var activeID: String?
            var deferredIntake = false
            var completed = 0
            defer {
                self.hud.hide()
                if deferredIntake { self.model.resumeIntake(); self.shelf.resumePresentation() }
                self.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
                self.cancellation = nil
                self.isBusy = false
                self.batchPrefix = nil
                self.expireStatus()
            }
            do {
                try token.check()
                guard Date().timeIntervalSince(requestedAt) <= BatchIntent.freshnessWindow else { throw WeChatAutomationError.focusChanged }
                self.model.deferIntake(); self.shelf.suspendPresentation(); deferredIntake = true
                for (index, job) in jobs.enumerated() {
                    try token.check()
                    activeID = job.id
                    if let id = job.id {
                        self.updateBatchRow(id: id, state: .running, detail: nil)
                        self.batchPrefix = L10n.format("第 %d/%d 个群 · %@", index + 1, jobs.count, job.preset.chat)
                    }
                    let result = try await self.run(job.preset, targetPID: targetPID, requestedAt: Date(), token: token)
                    if let id = job.id { self.updateBatchRow(id: id, state: .completed, detail: result) }
                    completed += 1
                    activeID = nil
                }
                if first.id != nil {
                    self.batchPrefix = nil
                    self.status = L10n.format("批量完成 · 本次已处理 %d 个群聊", completed)
                }
                if let folder = first.preset.destinationFolder { NSWorkspace.shared.open(folder) }
            } catch is CancellationError {
                if let id = activeID { self.updateBatchRow(id: id, state: .cancelled, detail: L10n.text("已收到的文件保留在暂存架。")) }
                self.status = L10n.text("已取消，已收到的文件保留在暂存架。")
            } catch {
                if let id = activeID { self.updateBatchRow(id: id, state: .failed, detail: error.localizedDescription) }
                let prefix = self.batchPrefix.map { $0 + "：" } ?? ""
                self.status = nil
                let message = prefix + error.localizedDescription
                self.error = message
                self.hud.hide()
                self.runner.notify(
                    L10n.format("快捷微信转发失败：%@", message),
                    action: ToastPresenter.Action(title: L10n.text("打开设置")) { [weak self] in self?.openSettings?(.wechat) }
                )
            }
        }
    }

    private func updateBatchRow(id: String, state: WeChatBatchState, detail: String?) {
        guard let index = batchRows.firstIndex(where: { $0.id == id }) else { return }
        batchRows[index].state = state
        batchRows[index].detail = detail
    }

    /// A finished run's summary is news for a few seconds, not a fixture: the
    /// bar it is shown in is pinned, and left alone the line would stand there
    /// until the next run in place of the warning that belongs before one. A
    /// failure is `error`, which stays until something is changed.
    private func expireStatus() {
        statusExpiry?.cancel()
        let shown = status
        statusExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, !self.isBusy, self.status == shown else { return }
            self.status = nil
            self.elapsedSeconds = nil
        }
    }

    /// One capture-to-delivery operation. The caller owns queue lifetime and
    /// receives errors before it can begin the next conversation.
    private func run(_ preset: WeChatForwardPreset, targetPID: pid_t?, requestedAt: Date, token: WeChatCancellation) async throws -> String {
            try token.check()
            guard Date().timeIntervalSince(requestedAt) <= BatchIntent.freshnessWindow else { throw WeChatAutomationError.focusChanged }
            guard let inbox = model.inbox else { throw InboxError.inboxUnavailable }
            if preset.destinationFolder == nil {
                guard let targetPID, NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier == preset.targetBundleIdentifier else {
                    throw AutoPaste.Failure.didNotBecomeActive(name: preset.targetName)
                }
            }
            let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/DukouShare.appex")
            let checkpoint = preset.incremental ? preferences.archiveCheckpoints.checkpoint(for: preset.chat) : nil
            let capture: WeChatCapture = try await withCheckedThrowingContinuation { continuation in
                Self.worker.async {
                    continuation.resume(with: Result {
                        if let folder = preset.destinationFolder { try QuickForwardFolderDelivery.validateFolder(folder) }
                        try token.check()
                        let engine = try WeChatAccessibility(chat: preset.chat, cancellation: token) { [weak self] message in
                            DispatchQueue.main.async { self?.status = message }
                        }
                        return try engine.capture(range: preset.range, ready: inbox.ready, shelfExtension: extensionURL,
                                                  identifySelf: preset.htmlPreview, checkpoint: checkpoint)
                    })
                }
            }
            try token.check()
            let reader = InboxReader(inbox: inbox)
            if let cut = capture.increment, cut.retained == 0 {
                let gathered = capture.directories.reversed().compactMap { reader.batch(at: $0) }
                for batch in gathered { try reader.markConsumed(itemIDs: Set(batch.items.map(\.id)), in: batch.id) }
                let note = L10n.text("没有新消息。检查点未改动。")
                status = note
                return note
            }
            guard capture.messageCount > 0 else {
                throw WeChatAutomationError.noMessages
            }
            var originals = capture.directories.reversed().compactMap { reader.batch(at: $0) }
            var counts = Array(capture.batchMessageCounts.reversed())
            let archivedRecords = Self.chronologicalRecords(in: originals.flatMap { $0.items.map(\.url) })
            guard !originals.isEmpty, originals.count == capture.directories.count, originals.count == counts.count,
                  originals.allSatisfy({ $0.items.count == 1 }) else { throw WeChatAutomationError.invalidArchive }
            if let cut = capture.increment {
                let trimmedURL: URL = try await withCheckedThrowingContinuation { continuation in
                    Self.worker.async {
                        continuation.resume(with: Result {
                            try WeChatExportArchive.trim(originals, dropPrefix: cut.dropPrefix, chat: preset.chat, in: inbox,
                                                         exportedAt: requestedAt, checkCancellation: token.check)
                        })
                    }
                }
                guard let trimmed = reader.batch(at: trimmedURL) else { throw WeChatAutomationError.invalidArchive }
                for batch in originals { try reader.markConsumed(itemIDs: Set(batch.items.map(\.id)), in: batch.id) }
                originals = [trimmed]
                counts = [cut.retained]
            }
            let merging = (preset.mergeArchives || preset.savesMarkdown) && originals.count > 1
            let removingMedia = !preset.saveImages || !preset.saveVideos
            let repackaging = merging || preset.htmlPreview || preset.savesMarkdown || removingMedia
            status = preset.savesMarkdown ? L10n.text("正在生成 Markdown…") : preset.htmlPreview ? L10n.text("正在生成 HTML 预览…")
                : merging ? L10n.text("正在合并聊天记录…") : removingMedia ? L10n.text("正在整理聊天记录…") : L10n.text("正在整理文件名…")
            let preparedDirectories: [URL] = try await withCheckedThrowingContinuation { continuation in
                Self.worker.async {
                    continuation.resume(with: Result {
                        try WeChatExportArchive.prepare(originals, chat: preset.chat, fallbackCounts: counts,
                                                        mergeArchives: preset.mergeArchives, htmlPreview: preset.htmlPreview, markdown: preset.savesMarkdown,
                                                        saveImages: preset.saveImages, saveVideos: preset.saveVideos, in: inbox, selfSender: capture.selfSender, exportedAt: requestedAt,
                                                        checkCancellation: token.check)
                    })
                }
            }
            let batches = preparedDirectories.compactMap { reader.batch(at: $0) }
            guard batches.count == preparedDirectories.count, batches.allSatisfy({ $0.items.count == 1 }) else { throw WeChatAutomationError.invalidArchive }
            // Once the prepared ZIPs exist, show their receipts on cancellation.
            // The native inputs remain recoverable in history with their bytes.
            if repackaging {
                for original in originals { try reader.markConsumed(itemIDs: Set(original.items.map(\.id)), in: original.id) }
            }
            try token.check()
            let urls = batches.flatMap { $0.items.map(\.url) }
            let destinationName = preset.destinationFolder?.path ?? preset.targetName
            if let folder = preset.destinationFolder {
                status = L10n.format("正在保存到 %@…", destinationName)
                let _: [URL] = try await withCheckedThrowingContinuation { continuation in
                    Self.worker.async {
                        continuation.resume(with: Result {
                            try preset.savesMarkdown
                                ? QuickForwardFolderDelivery.saveUnpacked(urls, to: folder, checkCancellation: token.check)
                                : QuickForwardFolderDelivery.save(urls, to: folder, checkCancellation: token.check)
                        })
                    }
                }
            } else {
                guard let targetPID else { throw AutoPaste.Failure.didNotBecomeActive(name: preset.targetName) }
                status = L10n.format("正在粘贴到 %@…", preset.targetName)
                // Read from WeChat's own receipts: a merged ZIP's combined TXT
                // no longer parses into dated records. Left as they were, the
                // receipts have just been renamed, and `batches` has the names.
                let natives = (repackaging ? originals : batches).flatMap { $0.items.map(\.url) }
                let span = await Task.detached { WeChatNativeArchive.span(of: natives) }.value
                let prompt = preferences.promptAttachment(for: .wechat, chat: preset.chat, span: span)
                let plan = PastePlan.make(urls: urls, pathOnly: preset.pastePath, prompt: prompt?.text)
                try await AutoPaste.pasteIntoRunning(pid: targetPID, bundleIdentifier: preset.targetBundleIdentifier, displayName: preset.targetName,
                                                   plan: plan, checkCancellation: token.check)
                if let prompt, let span { preferences.chatMemory.advance(preset.chat, prompt: prompt.id, to: span.end) }
            }
            if let cut = capture.increment, let archivedRecords, archivedRecords.count >= cut.dropPrefix {
                let added = Array(archivedRecords.dropFirst(cut.dropPrefix))
                if added.count == cut.retained, !added.isEmpty {
                    preferences.archiveCheckpoints.advance(preset.chat, by: added)
                }
            } else if capture.increment == nil, let archivedRecords {
                preferences.archiveCheckpoints.replace(preset.chat, with: archivedRecords)
            }
            // Delivery has committed. A late cancellation must not strand
            // saved files without their receipt or remembered destination.
            // Initialising only our own receipts above leaves other arrivals
            // untouched. When intake resumes those still receive their actions.
            var savedOutcome = true
            for batch in repackaging ? originals + batches : batches {
                do {
                    try reader.markConsumed(itemIDs: Set(batch.items.map(\.id)), in: batch.id)
                    try reader.recordOutcome(BatchOutcome(kind: .delivered, at: Date()), targetName: destinationName, for: batch.id)
                    try reader.recordChatName(preset.chat, for: batch.id)
                } catch { savedOutcome = false }
            }
            stored.recordSuccess(preset)
            recent = stored.recent
            if batchPrefix == nil { draft = stored.draft }
            else { stored.draft = draft }
            persist()
            let summary: String
            let shownCount = capture.increment?.retained ?? capture.messageCount
            let requested = preset.range.isUnlimited || preset.incremental ? nil : preset.range.value
            let historyNote = WeChatBatchBoundary.finishedShort(requested: requested, actual: shownCount, historyStartProved: capture.reachedHistoryStart)
                ? L10n.text(" · 聊天记录已到开头") : nil
            let boundaryNote = capture.boundaryStopped ? L10n.text("已保存已导出的记录。下一批的起点无法确认，已停止。") : nil
            let warning: String?
            if preset.destinationFolder != nil {
                // The folder's name, not its path: the bar has one line, and
                // the folder itself opens beside it.
                let folderName = preset.destinationFolder.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent } ?? destinationName
                summary = (preset.savesMarkdown
                    ? L10n.format("已保存 Markdown 笔记到 %@ · 约 %d 条消息", folderName, shownCount)
                    : L10n.format("已保存 %d 个 ZIP 到 %@ · 约 %d 条消息", urls.count, folderName, shownCount))
                    + (historyNote ?? "")
                let notes = [boundaryNote, savedOutcome ? nil : L10n.text("文件已保存，但部分记录状态未能保存。")].compactMap { $0 }
                warning = notes.isEmpty ? nil : notes.joined(separator: "\n")
            } else {
                summary = L10n.format("已向 %@ 粘贴 %d 个 ZIP · 约 %d 条消息", preset.targetName, urls.count, shownCount) + (historyNote ?? "")
                let notes = [boundaryNote, savedOutcome ? nil : L10n.text("粘贴已完成，但部分记录状态未能保存。")].compactMap { $0 }
                warning = notes.isEmpty ? nil : notes.joined(separator: "\n")
            }
            status = summary
            if let warning { error = warning }
            return summary + (warning.map { "\n" + $0 } ?? "")
    }

    /// Oldest batch first. Nil when any ZIP cannot be read as messages: a
    /// checkpoint must not be built from a partial timeline.
    private static func chronologicalRecords(in urls: [URL]) -> [WeChatTranscriptRecord]? {
        var records: [WeChatTranscriptRecord] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "zip",
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let parsed = try? WeChatNativeArchive.transcript(data)?.records else { return nil }
            records += parsed
        }
        return records
    }
}
