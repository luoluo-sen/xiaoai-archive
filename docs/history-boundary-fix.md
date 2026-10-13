# 系统提示占满屏幕时的历史边界修复

## 基线与证据

基于 `b525561db82b4d659f57a7ab7c60f3e52e6cc2d6`。本次读取到的最新应用诊断时间为 `2026-10-13T05:39:59Z`：微信 4.1.13，阶段 `keyboard-range`，耗时约 8.523 秒，221 次导航键，0 次导出、0 次范围选择点击，`keyboardTargetReached = false`，快照拒绝原因为 `noRows`。这里只记录排障元数据，不提交原始诊断、群名或聊天正文。

`noRows` 不是“这个聊天没有消息”，而是当前视口没有 `chat_bubble_item_view`。连续入群提示和时间分隔可以占满一屏；它们仍是合法的导航行。

## 原来的失败链路

1. 键盘向上逐行导航，只对真实消息计数。
2. 到达只剩系统提示的视口后，向上键停住。
3. `keyboardTopArrivalAfterTextStall` 仅发送一次 Down，并假设下一行就是最后一条已计数消息；连续提示使这个假设不成立。
4. 恢复失败后又调用 `stablePage/readablePage`。二者需要普通消息气泡，因此该视口会被拒绝，连顶部确认逻辑都无法完成。
5. 原函数还要求 `count > 1`，排除了只有一条真实消息的聊天。

另一个独立缺陷：全量任务在每批之间调用 `prefetchHistory`，该函数最终回到最新消息，破坏上一批保存的视口和键盘断点；`.resume` 又不会使用传入的预加载页面。

## 修改内容

- **导航状态与选区页面分离。** 顶部探测直接读取消息列表、当前焦点和焦点之前的前缀，允许可见气泡数为零。不全局放宽 `stablePage`，选区操作仍需要它自己的验证。
- **有界的顶部证据。** 等待并发送额外 Up/向上滚动探测；要求可读取、没有未物化/未知前缀、前面没有更早的真实消息、列表不忙、首行上边缘可见，且至少三次一致观察横跨两秒。前缀变化、读取失败、虚拟焦点和加载状态会阻止或重置确认。探测时出现更早的行交回正常导航，不能当成历史结束。
- **按真实路径回退。** 记录最后一条已计数消息之后实际跨过的提示序列，逐行反向验证，直到原消息。保留重复提示的次数；不要求旧坐标相同，不额外增加消息计数，不把“下一个方便选中的气泡”当成终点。匹配使用结构化字段的完整 SHA-256，日志仅保留缩短哈希。
- **支持单消息和短尾批。** 顶部可以停在消息本身，也可以停在任意长度的系统提示序列。已经选中的唯一消息不再被 `count > 1` 排除。
- **不把焦点回到已选锚点当作 EOF。** 返回已选消息可能是焦点重置，不能凭这个现象宣布全部历史已采集。
- **跨批次不回到最新。** 只允许第一批使用预加载页面。在上一批键盘断点经过现有窗口/上下文验证后，逐行寻找恰好一条更早的真实消息作为新锚点。遇到经过验证的顶部时结束，不要求创建一个不存在的下一批，覆盖历史条数恰好为 100 的整数倍的情况。
- **保留已提交结果。** 后续选区出现特定边界错误时，普通归档交付已完成的批次并标记不完整；不吞掉用户取消或前台切换错误。增量采集在未匹配旧检查点且无法安全续接时仍停止，不推进检查点。
- **诊断升级到 schema 8。** 新增 `historyBoundary`、应用版本与构建号，以及 `keyboard-stall/history-probe/short-conversation/next-keyboard-anchor/partial-capture` 等记录。真实消息计数与导出计数仍分开。

## 自动回归检查

生产策略位于 `Sources/DukouCore/WeChatHistoryBoundary.swift`。同一组 25 个场景由 XCTest 和不依赖 XCTest 的命令行入口共同调用，没有用另一套“测试版算法”替换生产实现。

仅安装 Command Line Tools 时也可运行：

```bash
mkdir -p .build
swiftc -swift-version 6 -D HISTORY_BOUNDARY_STANDALONE \
  Sources/DukouCore/WeChatHistoryBoundary.swift \
  Tests/DukouCoreTests/HistoryBoundaryScenarios.swift \
  Scripts/check-history-boundary.swift \
  -o .build/check-history-boundary
.build/check-history-boundary
```

安装了可用的完整 Xcode 工具链时运行完整测试：

```bash
swift test
```

已运行的命令行回归结果：**25/25 通过**。覆盖无气泡视口、0/1/220 条分隔、重复提示保留次数、错误气泡/选中状态、加载中的虚拟前缀、读取失败、时间与观察次数门槛、延迟出现的旧消息、超高首行和精确批次边界。

另已通过以下**真实生产源码**检查，没有用桩对象替代导航引擎：整个 `DukouCore` 的 Swift 6 模块编译，以及 `WeChatAccessibility.swift`、`WeChatArchive.swift`、`AutoPaste.swift` 的 Swift 5 模式联合类型检查。`git diff --check` 也通过。

```bash
mkdir -p .build/history-verification
swiftc -emit-module -parse-as-library -swift-version 6 \
  -module-name DukouCore -application-extension -enable-testing \
  -emit-module-path .build/history-verification/DukouCore.swiftmodule \
  Sources/DukouCore/*.swift
swiftc -typecheck -swift-version 5 -I .build/history-verification \
  Sources/DukouApp/WeChat/WeChatAccessibility.swift \
  Sources/DukouApp/WeChat/WeChatArchive.swift \
  Sources/DukouApp/AutoPaste.swift
```

这些检查在 Apple Swift 6.4 / arm64 Mac 的当前 SDK 上执行，证明上述源码可编译、类型正确；不替代完整 GUI 应用构建、所有目标系统版本验证或真实微信操作验收。

本机首次 `swift test` 被缺少 XCTest 阻断；完整 `swift build` 在未修改的 SwiftUI 界面源码处报 `SwiftUIMacros.StateMacro` 插件缺失。不能把核心场景通过写成“全套测试通过”或“应用端到端通过”。

## 真实微信验收（尚未执行）

在使用原有固定签名身份打包、安装此分支之后进行；本修复未修改 `Project.plist`、Bundle ID、权限配置、用户的现有应用或聊天数据。

| 场景 | 验收结果 |
| --- | --- |
| 截图中的全量群聊，顶部只有入群提示 | 先确认顶部，再穿过提示回到已计数消息，导出实际尾批；不能因 `noRows` 直接失败 |
| 只有 1 条真实消息，之前有多条提示 | 正常导出 1 条，不再要求大于 1 条 |
| 实际 99/100/101/200/201 条消息，范围为全部 | 实际条数与原生文件核对；完整批次精确衔接，100 的整数倍不产生虚构尾批 |
| 导出时有新消息、重复图片、重复文本 | 不跳回实时底部；无法确认边界时安全停止，不能静默漏选或重复 |
| 顶部暂时加载、首行高于视口 | 不把首次不动或“没有可见气泡”当成完成 |
| 第二批失败、取消、切换群聊 | 已收到文件保留；状态明确区分部分成功、取消与完整结束 |
| 增量任务未找到旧检查点 | 不宣称增量成功，不更新检查点 |

检查新的 `~/Library/Logs/xiaoai-archive/WeChat/latest.json` 中 `schemaVersion` 是否为 **8**。仍为 7 表示运行的不是本修复中的诊断实现；仅更新 GitHub 源码不会替换已经安装的应用。

## 保留的限制

这里确认的是当前微信客户端通过界面实际暴露的历史起点，不是微信服务器全部历史的证明。未知节点、持续加载、失去消息身份或窗口变化仍会拒绝继续。没有稳定的全局消息 ID 时，内容指纹本身也不是唯一身份，所以修复保留了键盘路径、消息顺序、窗口身份与选中状态的联合校验。

本分支需要真实微信验收后再作为稳定版发布，不应仅为了消除红色错误提示而放开这些校验。
