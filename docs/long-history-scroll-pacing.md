# 长历史预加载与滚动节奏：实现和核验

基线：`main` 的 `3f24a24d19bc7e9d9ea585f3b1e5497acb3957bb`，包含 `0d1a01a` 的贴边终点修复。需求见 [long-history-export.md](long-history-export.md)。本次不安装或运行应用，不操作真实微信。

## 实现

### 一次初始预加载

`WeChatPrefetchPlan` 将预加载目标和精确消息计数分开：普通采集条数为 0 时返回 `allHistory`；大于 100 时返回有限目标；1～100 条不预加载。`capture` 只在分批循环之前调用一次预加载，后续 `.resume` 不执行 Home/End 预加载往返。

全量预加载不再用 `Int.max` 伪装有限条数，也不受有限预加载的 180 秒总预算限制：只要有进展，就可以继续；单次持续加载/滚动受限仍有约 8 秒的有界等待，且始终可取消。有限条数仍有最多 180 秒的预加载预算，达到预算只结束暖机，不修改用户要求导出的消息数量。

Home 保持快速路径。它没有报告新增行时，用现有的 `probeKeyboardTop` 判断是更早内容出现、仍在加载，还是客户端暴露的历史起点。纯入群提示页面不必先变成普通消息页面。只有预加载前后回到最新消息；预加载结果不会替代选区引擎自己的条数和历史边界验证。

不支持键盘聚焦时，使用单向滚轮预加载。只保留前后两个导航帧，不缓存全部页面。预加载帧包含合法系统提示；无效读取不能复用上次的旧帧作为静止/到顶证据。

**增量例外：** 增量任务不预加载整段历史，否则 UI 的条数 0 会绕过最多 40 批的工作量限制。原有 40 批和序列重叠停止规则保留。

### 可恢复的降速

`WeChatScrollPacing` 保存一次受限之前的间隔和最大请求量。实测位移/请求量小于 0.4 时，仅临时降低最大请求量、加长短间隔；新状态的短间隔上限为 0.45 秒，连续受限的计时从第一次开始，不因重复输入而重置。

连续两次可信健康增益会恢复**受限前的原值**，而不是始终恢复成硬编码 520；预加载或这一批选区退出时也恢复，包括失败和取消。无重叠帧可以估计预加载距离，但不能伪造测得增益或清除仍在进行的受限计时。

普通、已测量增益的滚轮步长约为视口的 70%，保留至少 30% 的常规重叠。长气泡会进一步减小步长，超高气泡仍保留约三分之一屏的退路；尚未测得增益时仍从约 40% 屏起步。所有事件请求仍受 520 上限约束。70% 不是覆盖选区精确定位所需的小滚动，也不是实际性能测量结果。

### 原有选区合同

没有修改 `WeChatFocusHold.swift`、`WeChatFocusHoldTests.swift`、`WeChatHistoryBoundary.swift` 和原有 25 个历史边界场景。键盘逐条计数、系统提示不计数、贴边按约一行高度滚开、验证原焦点后按「选择到这里」、每批最多 100 条的路径保留。`nudgeAttempts` 仍是每批局部配额，不用运行级诊断数组消费第四批的预算。

### 部分保存和界面状态

停止原因通过 `WeChatExportStopReason` 区分下一批起点、当前批终点、历史加载超时、滚动受限恢复超时。不再把加载失败一概写成“下一批的起点无法确认”。已收到的普通归档批次继续交付；部分结果不替换归档检查点。增量未确认重叠/续接时仍不推进检查点。

保留 `main` 已有的每个群开始时清空 `error`，同时立即更新当前群的进行中状态；成功且无警告时明确清空警告。真实界面是否如预期刷新仍需本机验证。

## 不操作微信的验证

新增 `LongHistoryScenarios`，XCTest 入口和独立命令行入口使用同一组生产策略断言。测试预加载分支、跨批不预加载、增量限制、短时降速与恢复、长期健康步伐、超时、无效测量、70% 步长和贴边合同。

```bash
# 按 agent.md，CLT 的当前 SDK 存在 SwiftUI 宏问题时可用已有的 26.5 SDK。
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
mkdir -p .build/long-history-checks

swiftc -swift-version 6 -D LONG_HISTORY_STANDALONE \
  Sources/DukouCore/*.swift \
  Tests/DukouCoreTests/LongHistoryScenarios.swift \
  Scripts/check-long-history.swift \
  -o .build/long-history-checks/check-long-history
.build/long-history-checks/check-long-history

swiftc -swift-version 6 -D HISTORY_BOUNDARY_STANDALONE \
  Sources/DukouCore/WeChatHistoryBoundary.swift \
  Tests/DukouCoreTests/HistoryBoundaryScenarios.swift \
  Scripts/check-history-boundary.swift \
  -o .build/long-history-checks/check-history-boundary
.build/long-history-checks/check-history-boundary

python3 Scripts/check-scroll-regressions.py
swift Scripts/check-localizations.swift
swift build --product xiaoai-archive
swift test
git diff --check
```

`check-scroll-regressions.py` 是 **独立断言补充检查，不是 XCTest**。它在 `.build` 生成副本，复用现有 FocusHold、ScrollStep、Prefetch 测试方法，保留真实断言，仅移除 XCTest 的导入和基类；不修改原测试文件。遇到未知断言、异步测试签名或测试生命周期方法会失败，不会静默忽略。完整工具链仍应执行 `swift test`。

### 实际结果

在连接的 arm64 Mac 上使用 Apple Swift 6.4 和本机已有的 macOS 26.5 SDK 实际执行：

| 检查 | 结果 |
| --- | --- |
| 新增长历史策略场景 | **31/31 通过**，独立入口执行真实生产策略 |
| 原有历史边界场景 | **25/25 通过**，原场景与生产边界代码未修改 |
| 既有 FocusHold / ScrollStep / Prefetch 测试方法 | **30/30 通过**：13 + 7 + 10；独立断言运行器，不是 XCTest |
| 全部 DukouCore Swift 6 模块编译 | **通过** |
| 最终导航引擎 + WeChatArchive + AutoPaste 联合类型检查 | **通过**，真实源码，无桩替代 |
| `swift build --product xiaoai-archive` | **通过**，包括最终改动后的再次完整产品构建；未打包、签名、安装或打开应用 |
| 中英文资源校验 | **通过** |
| `git diff --check` 和源码合同检查 | **通过** |
| 完整 `swift test` | **未能执行测试**：本机 CLT 缺少 XCTest，在已有 BatchStagingTests 的模块导入处失败 |
| 真实微信点击、滚动、分享、最终 ZIP | **未执行**，留给下面的本机验收 |

独立断言运行器初版生成 Swift 的闭括号有误，已修正并重新执行至 30/30 通过。首次本地化校验还指出 main 中已有的四个废弃会话列表文案；确认源码已无引用后，在两种语言中同时清理，最终校验通过。构建仍有 CLT 搜索路径和既有弱/强捕获警告，不将其隐瞒为零警告构建。

源码合同检查确认：签名/Bundle ID/安装配置、Inbox、MIT 声明、FocusHold 实现及测试、原有 25 个历史边界场景未修改；预加载调用仅一处且在批次循环外；增量 40 批限制和每批 `nudgeAttempts` 仍在。没有提交生成的测试副本、构建日志或诊断原文。

## 新诊断

`schemaVersion = 9`。仅源码更新不会替换已经安装的应用。

| 字段 | 用途 |
| --- | --- |
| `prefetchExit` | `notRequested`、`goalReached`、`warmupBudget`、`clientHistoryStart` 或加载失败原因 |
| `pacingEvents` | 最多 32 条降速/恢复事件，含阶段、批次、间隔、上限及实际可测增益 |
| `scrollPause` / `scrollCeiling` | 任务收尾时的节奏；临时受限状态应已恢复 |
| `stopReason` | `nextBatchAnchor`、`rangeEndpoint`、`historyLoadingTimeout`、`scrollStalled` 或 `none` |
| `boundaryStopped` | 真正的起点/终点验证失败；不是所有部分保存的总称 |

预加载发现的 `clientHistoryStart` 只描述当前客户端暴露的历史，不能证明服务器历史已完全同步，更不能单独宣布全量导出成功。读取失败、未知前缀或持续受限仍会安全停止。

## 本机微信验收：尚未执行

| 场景 | 需观察的结果 |
| --- | --- |
| 全量超过 300 条 | 进入第四批并继续；贴边先滚开再选择，不能强按按钮 |
| 几千条，含长文/大图 | 先预加载一次；补历史短暂受限后恢复，不再全程使用 300 上限或接近 0.9 秒间隔 |
| 连续多个群 | 上一群红字不留在下一群进行中状态；每群独立初始化节奏 |
| 纯入群提示顶部、仅 1 条消息、100 的整数倍 | 仍能正确收尾，没有虚构下一批 |
| 加载长时间不响应 | 超时停止；已经收到的 ZIP 保留，错误说明与边界失败不同 |
| 增量 | 未找到可信重叠时不推进检查点，最多 40 批 |

安装由用户按 `agent.md` 原流程执行，保持原签名和唯一的 `/Applications/xiaoai-archive.app`。本修改不触碰签名、Bundle ID、安装路径、收件箱、微信数据库或微信安装包；没有加入 `pelican-bicycle.html` 或原始诊断。
