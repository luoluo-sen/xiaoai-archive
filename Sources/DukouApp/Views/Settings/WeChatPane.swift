import AppKit
import DukouCore
import SwiftUI

struct WeChatPane: View {
    @ObservedObject var forward: WeChatQuickForward
    @ObservedObject var authorization: AccessibilityAuthorization
    @ObservedObject var preferences: Preferences
    /// The amount field's own text, so a rejected keystroke can be taken back.
    @State private var amount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            // What stops a run is said before the form, not under it.
            if !authorization.isTrusted {
                Notice(text: L10n.text("微信转发需要辅助功能权限。"), tone: .warn) {
                    Button(L10n.text("开启权限")) { authorization.guideIfNeeded() }.buttonStyle(SettingsActionButtonStyle())
                }
            }
            WeChatInterfaceNotice(authorization: authorization)

            SettingsChoiceStrip(
                title: L10n.text("执行方式"),
                selection: Binding(get: { forward.batchMode }, set: forward.setBatchMode),
                choices: [
                    .init(id: false, title: L10n.text("单个群聊"), symbol: "bubble.left"),
                    .init(id: true, title: L10n.text("批量群聊"), symbol: "list.bullet"),
                ]
            )
            .disabled(editingDisabled)
            .accessibilityIdentifier("wechat.mode")

            chatListSection

            forwardContentSection

            SettingsSection(title: L10n.text("送到"), systemImage: "arrow.up.forward.app", spacing: Space.m) {
                QuickForwardDestinationPicker(
                    targetBundleIdentifier: forward.draft.targetBundleIdentifier,
                    targetName: forward.draft.targetName,
                    folder: forward.draft.destinationFolder,
                    applications: forward.applications,
                    pastePath: $forward.draft.pastePath,
                    markdown: $forward.draft.markdown,
                    onChooseApplication: forward.chooseTarget,
                    onChooseFolder: forward.chooseFolder,
                    onShowApplications: forward.showApplications,
                    onShowFolder: forward.showFolder,
                    onRefresh: forward.refreshApplications,
                    identifierPrefix: "wechat"
                )
            }.disabled(editingDisabled)

            if !forward.batchMode, forward.draft.destinationFolder == nil {
                QuickForwardPromptSection(preferences: preferences, surface: .wechat, chat: forward.draft.chat)
                    .disabled(editingDisabled)
            }

            if !forward.batchMode, !forward.recent.isEmpty {
                SettingsSection(title: L10n.text("记住的群聊"), systemImage: "clock.arrow.circlepath", spacing: Space.m) {
                    ForEach(forward.recent) { preset in
                        HStack(spacing: Space.s) {
                            Button { forward.use(preset) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.chat).font(Typo.rowTitle).foregroundStyle(Theme.ink)
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(preset.range.title + " · " + (preset.destinationFolder?.path ?? preset.targetName) + " · " +
                                         (preset.destinationFolder != nil ? L10n.text("保存文件") : (preset.pastePath ? L10n.text("粘贴路径") : L10n.text("粘贴文件"))))
                                        .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(PlainPressButtonStyle(staticFeedback: true))
                            Button(L10n.text("再次执行")) { forward.start(preset) }.buttonStyle(SettingsActionButtonStyle())
                                .fixedSize()
                                .disabled(!preset.range.isAvailableForAutomation)
                            Button { forward.forget(preset) } label: { Image(systemName: "xmark") }
                                .buttonStyle(IconButtonStyle(size: SettingsControlMetrics.height, staticFeedback: true)).help(L10n.text("忘记这个群聊"))
                                .accessibilityLabel(Text(L10n.text("忘记这个群聊")))
                        }
                    }
                }.disabled(editingDisabled)
            }
        }
        .onAppear { forward.refreshApplications() }
    }

    private var forwardContentSection: some View {
        SettingsSection(title: L10n.text("转发内容"), systemImage: "bubble.left.and.bubble.right", spacing: Space.m) {
            if !forward.batchMode {
                FormRow(L10n.text("群聊")) {
                    HStack(spacing: Space.s) {
                        TextField(L10n.text("微信群名称"), text: $forward.draft.chat)
                            .textFieldStyle(SettingsTextFieldStyle())
                            .accessibilityIdentifier("wechat.chat")
                        Button(L10n.text("读取当前群")) { forward.readCurrentChat() }
                            .buttonStyle(SettingsActionButtonStyle())
                            .fixedSize()
                            .disabled(forward.isReadingChat || forward.isReadingChatList)
                    }
                }
                FormRow(L10n.text("范围")) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.s) {
                            Text(L10n.text("最近")).font(Typo.paneBody)
                            // A TextField will not take a correction back from its own
                            // binding while it has focus, so the field owns its text and
                            // the count follows it. Anything that is not a digit is
                            // removed on the keystroke that typed it.
                            TextField(L10n.text("范围数量"), text: $amount)
                                .textFieldStyle(SettingsTextFieldStyle(numeric: true, invalid: !forward.draft.range.isValid))
                                .multilineTextAlignment(.center)
                                .frame(width: min(176, max(64, CGFloat(amount.count) * 8 + 24)))
                                .accessibilityIdentifier("wechat.amount")
                                .disabled(forward.draft.range.unit != .messages)
                                .onChange(of: amount) { _, typed in
                                    let digits = WeChatForwardRange.digits(typed)
                                    if digits != typed { amount = digits }
                                    forward.setAmount(digits)
                                }
                                .onChange(of: forward.draft.range.unit) { _, _ in
                                    // Switching a legacy time preset to messages replaces
                                    // the amount from outside the field.
                                    amount = forward.amountText
                                }
                                .onChange(of: forward.draft.range.value) { _, value in
                                    // A remembered preset can replace the count without
                                    // changing units. Preserve empty or overflowing text
                                    // while editing; both already map to the invalid zero.
                                    if (Int(amount) ?? 0) != value { amount = forward.amountText }
                                }
                                .onAppear { amount = forward.amountText }
                            Text(forward.draft.range.unit.title)
                                .font(Typo.paneBody)
                                .accessibilityIdentifier("wechat.unit")
                            if forward.draft.range.unit != .messages {
                                Button(L10n.text("改用条数")) { forward.useMessageCount() }
                                    .buttonStyle(SettingsActionButtonStyle())
                                    .accessibilityIdentifier("wechat.useMessageCount")
                            }
                            Spacer(minLength: Space.s)
                            if let estimate = forward.draft.range.estimatedTimeTitle {
                                Text(estimate)
                                    .font(Typo.paneCaption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("wechat.estimate")
                            }
                        }
                        if forward.draft.range.unit != .messages {
                            Text(L10n.text("按时间选取暂未开放，请改用条数。"))
                                .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if forward.draft.range.isUnlimited {
                            Text(L10n.text("条数为 0 表示导出这个群从第一条到最新的全部消息。"))
                                .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle(L10n.text("增量采集"), isOn: $forward.draft.incremental)
                            .disabled(forward.isBusy)
                            .accessibilityIdentifier("wechat.incremental")
                        if forward.draft.incremental {
                            Text(L10n.text("从上次成功归档的末尾继续，只保存新消息。相同的分钟不会直接停。"))
                                .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !forward.draft.range.isValid {
                            Text(rangeValidationMessage)
                                .font(Typo.paneCaption).foregroundStyle(Theme.danger)
                        }
                    }
                }
            }
            FormRow(L10n.text("附带")) {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Toggle(L10n.text("图片"), isOn: $forward.draft.saveImages)
                            .accessibilityIdentifier("wechat.images")
                        Toggle(L10n.text("视频"), isOn: $forward.draft.saveVideos)
                            .accessibilityIdentifier("wechat.videos")
                        Toggle(L10n.text("HTML 预览"), isOn: $forward.draft.htmlPreview)
                            .help(L10n.text("解压后打开 index.html，按时间线查看聊天记录。"))
                            .accessibilityIdentifier("wechat.htmlPreview")
                        // WeChat exports a hundred messages at a time, so up
                        // to that there is one ZIP and nothing to merge; and
                        // a Markdown note is one note whatever this says.
                        if showsArchiveMerge, !forward.draft.savesMarkdown {
                            Toggle(forward.batchMode ? L10n.text("每群合并为一个 ZIP") : L10n.text("合并为一个 ZIP"), isOn: $forward.draft.mergeArchives)
                                .accessibilityIdentifier("wechat.mergeArchives")
                        }
                    }
                    .toggleStyle(SettingsChipToggleStyle())
                    if !forward.batchMode && forward.draft.recommendsMergingArchives {
                        Label(L10n.text("消息较多，建议合并以减少附件数量。"), systemImage: "lightbulb")
                            .font(Typo.paneCaption).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("wechat.mergeRecommendation")
                    }
                }
            }
        }.disabled(editingDisabled)
    }

    private var chatListSection: some View {
        SettingsSection(title: L10n.text("当前窗口列表"), systemImage: "list.bullet", spacing: Space.m) {
            HStack(spacing: Space.m) {
                Text(L10n.text("读取当前微信窗口中已加载的会话名称。"))
                    .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.text("读取窗口列表")) { forward.readCurrentChatList() }
                    .buttonStyle(SettingsActionButtonStyle())
                    .fixedSize()
                    .disabled(forward.isBusy || forward.isReadingChat || forward.isReadingChatList)
                    .accessibilityIdentifier("wechat.readChatList")
            }
            if forward.isReadingChatList {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在读取窗口列表…")).font(Typo.paneCaption)
                }
            }
            if let error = forward.chatListError {
                Notice(error, tone: .warn)
            }
            if let list = forward.chatList {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(L10n.format("%@ · %d 个已加载会话", listTitle(list.scope), list.entries.count))
                        .font(Typo.rowTitle)
                        .accessibilityIdentifier("wechat.chatListCount")
                    Text(L10n.format("已确认 %d 个群聊，另有 %d 个会话待确认。", list.confirmedGroupCount, list.unverifiedCount))
                        .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                    if forward.batchMode {
                        WeChatBatchControls(forward: forward)
                            .disabled(editingDisabled)
                        ForEach(forward.batchRows) { row in
                            WeChatBatchItemRow(forward: forward, row: row)
                                .disabled(editingDisabled)
                        }
                        Text(L10n.text("勾选即确认该会话为群聊；同名会话无法自动区分，请先在微信中确认名称唯一。"))
                            .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                    ForEach(list.entries) { entry in
                        HStack(alignment: .top, spacing: Space.m) {
                            Text(verbatim: entry.name)
                                .font(Typo.paneBody).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.isConfirmedGroup ? L10n.text("群聊（已确认）") : L10n.text("类型待确认"))
                                .font(Typo.paneCaption)
                                .foregroundStyle(entry.isConfirmedGroup ? Theme.positive : Theme.inkSecondary)
                                .fixedSize()
                        }
                        .padding(.vertical, Space.xs)
                    }
                    }
                    Text(L10n.text("仅当前打开会话的群聊类型可确认，其他会话不按名称猜测类型。"))
                        .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("其他会话请在微信中手动展开或滚动后重新读取。"))
                        .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if forward.batchMode, !forward.isReadingChatList {
                Text(L10n.text("先读取窗口列表，再勾选需要批量处理的群聊。"))
                    .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var editingDisabled: Bool {
        forward.isBusy || forward.isReadingChat || forward.isReadingChatList
    }

    private var showsArchiveMerge: Bool {
        if !forward.batchMode { return forward.draft.range.value > 100 }
        return forward.batchRows.contains { $0.isSelected && (forward.batchCount(id: $0.id) ?? 0) > 100 }
    }

    private func listTitle(_ scope: WeChatChatList.Scope) -> String {
        switch scope {
        case .conversations: L10n.text("普通会话")
        case .folded: L10n.text("折叠的聊天")
        }
    }

    private var rangeValidationMessage: String {
        guard forward.draft.range.unit == .messages else {
            return L10n.format("请输入 1–%d 之间的整数。", forward.draft.range.unit.maximum)
        }
        return !amount.isEmpty && Int(amount) == nil
            ? L10n.text("条数过大，请输入更小的数字。")
            : L10n.text("请输入大于或等于 0 的整数。")
    }
}

private struct WeChatBatchControls: View {
    @ObservedObject var forward: WeChatQuickForward
    @State private var amount = ""

    private var amountIsValid: Bool { (Int(amount) ?? 0) >= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            FormRow(L10n.text("统一条数")) {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Text(L10n.text("每群最近")).font(Typo.paneBody)
                        TextField(L10n.text("范围数量"), text: $amount)
                            .textFieldStyle(SettingsTextFieldStyle(numeric: true, invalid: !amountIsValid))
                            .multilineTextAlignment(.center)
                            .frame(width: min(176, max(64, CGFloat(amount.count) * 8 + 24)))
                            .accessibilityIdentifier("wechat.batchAmount")
                            .onChange(of: amount) { _, typed in
                                let digits = WeChatForwardRange.digits(typed)
                                if digits != typed { amount = digits }
                                if digits != forward.batchAmountText { forward.setBatchAmount(digits) }
                            }
                            .onChange(of: forward.batchAmountText) { _, value in
                                if amount != value { amount = value }
                            }
                            .onAppear { amount = forward.batchAmountText }
                        Text(L10n.text("条消息")).font(Typo.paneBody)
                        Spacer(minLength: 0)
                        Button(L10n.text("应用到所选群")) { forward.applyBatchAmount() }
                            .buttonStyle(SettingsActionButtonStyle())
                            .fixedSize()
                            .disabled(!amountIsValid || forward.selectedBatchCount == 0)
                            .accessibilityIdentifier("wechat.applyBatchAmount")
                    }
                    if !amountIsValid {
                        Text(!amount.isEmpty && Int(amount) == nil
                             ? L10n.text("条数过大，请输入更小的数字。")
                             : L10n.text("请输入大于或等于 0 的整数。"))
                            .font(Typo.paneCaption).foregroundStyle(Theme.danger)
                    }
                    Text(L10n.text("单群条数留空时使用统一值；应用到所选群会清除单群条数，并重置这些群的执行状态。"))
                        .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Space.s) {
                Text(L10n.format("已选择 %d 个群聊", forward.selectedBatchCount))
                    .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                    .accessibilityIdentifier("wechat.batchSelectedCount")
                Spacer(minLength: 0)
                Button(L10n.text("全选")) { forward.selectAllBatchRows(true) }
                    .buttonStyle(SettingsActionButtonStyle())
                    .accessibilityIdentifier("wechat.batchSelectAll")
                Button(L10n.text("取消全选")) { forward.selectAllBatchRows(false) }
                    .buttonStyle(SettingsActionButtonStyle())
                    .accessibilityIdentifier("wechat.batchDeselectAll")
            }
        }
        .padding(.vertical, Space.s)
    }
}

private struct WeChatBatchItemRow: View {
    @ObservedObject var forward: WeChatQuickForward
    let row: WeChatBatchRow
    @State private var count = ""

    private var countIsValid: Bool { count.isEmpty || (Int(count) ?? 0) >= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.m) {
                Toggle(isOn: Binding(
                    get: { row.isSelected },
                    set: { forward.setBatchSelected(id: row.id, selected: $0) }
                )) {
                    Text(verbatim: row.chat)
                        .font(Typo.paneBody)
                        .lineLimit(2).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("wechat.batchRow." + row.id + ".selected")
                TextField(forward.batchAmountText.isEmpty ? L10n.text("统一条数") : forward.batchAmountText, text: $count)
                    .textFieldStyle(SettingsTextFieldStyle(numeric: true, invalid: !countIsValid))
                    .multilineTextAlignment(.center)
                    .frame(width: 88)
                    .help(L10n.text("单群条数，留空使用统一条数。"))
                    .accessibilityLabel(Text(L10n.format("%@ 的消息条数", row.chat)))
                    .accessibilityIdentifier("wechat.batchRow." + row.id + ".count")
                    .onChange(of: count) { _, typed in
                        let digits = WeChatForwardRange.digits(typed)
                        if digits != typed { count = digits }
                        if digits != row.countText { forward.setBatchCount(id: row.id, text: digits) }
                    }
                    .onChange(of: row.countText) { _, value in
                        if count != value { count = value }
                    }
                    .onAppear { count = row.countText }
                Text(L10n.text("条消息")).font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                Button(L10n.text("设为单群")) { forward.useBatchRow(id: row.id) }
                    .buttonStyle(SettingsActionButtonStyle())
                    .fixedSize()
                    .accessibilityIdentifier("wechat.batchRow." + row.id + ".single")
            }
            HStack(alignment: .top, spacing: Space.m) {
                Text(row.isConfirmedGroup ? L10n.text("群聊（已确认）") : L10n.text("类型待确认"))
                    .foregroundStyle(row.isConfirmedGroup ? Theme.positive : Theme.inkSecondary)
                Text(row.state.title).foregroundStyle(stateColor)
                    .accessibilityIdentifier("wechat.batchRow." + row.id + ".state")
                if let detail = row.detail {
                    Text(detail).foregroundStyle(stateColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .font(Typo.paneCaption)
            if !countIsValid {
                Text(Int(count) == nil
                     ? L10n.text("条数过大，请输入更小的数字。")
                     : L10n.text("请输入大于或等于 0 的整数。"))
                    .font(Typo.paneCaption).foregroundStyle(Theme.danger)
            }
        }
        .padding(.vertical, Space.s)
    }

    private var stateColor: Color {
        switch row.state {
        case .waiting, .cancelled: Theme.inkSecondary
        case .running: Theme.accent
        case .completed: Theme.positive
        case .failed: Theme.danger
        }
    }
}

/// Says that this WeChat account shows Dukou no controls before the form is
/// filled in, rather than after a run has failed on it. Shared by both quick
/// forward panes; silent whenever WeChat cannot be judged.
struct WeChatInterfaceNotice: View {
    @ObservedObject var authorization: AccessibilityAuthorization
    @State private var isHidden = false

    var body: some View {
        Group {
            if isHidden { Notice(WeChatAutomationError.interfaceHidden.localizedDescription, tone: .warn) }
        }
        .task(id: authorization.isTrusted) { await probe() }
        // Logging in to WeChat, or switching accounts, happens over there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await probe() }
        }
    }

    private func probe() async {
        isHidden = await Task.detached { WeChatAccessibility.interfaceVisibility() == .hidden }.value
    }
}
