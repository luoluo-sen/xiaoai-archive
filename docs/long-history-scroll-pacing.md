# 长历史渐进预热与滚动节奏：实现和核验

基线：`main` 的 `3f24a24d19bc7e9d9ea585f3b1e5497acb3957bb`，包含 `0d1a01a` 的贴边终点修复。需求与取舍见 [long-history-export.md](long-history-export.md)。本次不安装或运行应用，不操作真实微信。

## 目标变化

原实现把条数 0 解释成“先把客户端可见历史全部预加载，再开始第一批合并转发”。多年群聊会因此把最慢、最占微信内存且没有文件产出的阶段放在最前面；预加载失败时一个 ZIP 都没有。

本次改为：

- 全量和大于 100 条的普通任务，只在第一次选区前做一次**有界、可放弃的首窗预热**。
- 首窗最多按 3 个原生批次规划，即约 300 条；有限请求少于 300 条时按实际请求量规划。
- 预热内部预算最多 30 秒。预算耗尽、连续无进展或边界读数无法确认时，不把预热失败当作导出失败，而是回到正常的 `.latest` 选区路径。
- 首个 ZIP 不再依赖先证明客户端历史起点。超过首窗后，正式选区仍可能在冷历史边缘等待微信加载；已完成批次按现有部分保存规则保留。

30 秒是预热循环的预算，不是从打开群到首个 ZIP 的严格总时限。回到最新消息、辅助功能调用、原生选区和微信导出仍各有自己的有界等待。

## 实现

### 有界首窗策略

`WeChatPrefetchPlan` 是 `DukouCore` 中的纯策略：

| 请求 | 初始预热 |
| --- | --- |
| 条数 0 | 300 条目标，最多 30 秒 |
| 101～299 条 | 按请求量，最多 30 秒 |
| 300 条及以上 | 300 条目标，最多 30 秒 |
| 1～100 条 | 不预热 |
| 增量任务 | 不预热，保留最多 40 批的原限制 |
| 已完成至少一批 | 不再预热 |

目标包含原有安全余量，用于吸收系统提示和可见列表结构差异，但预热统计不等于导出条数。每条消息仍由后续键盘计数和原生选区证明。

预热仍只出现在批次循环之前。没有把初始 `Home/End` 往返移进后续批次，因为分享之后跨批返回最新消息会破坏上一批终点和续接锚点。

### 预热失败回退

`bestEffortPrefetch` 只把下列预热阶段错误降级为“没有暖页”：加载中、加载超时、滚动受限、历史读数无法确认、预热导航无法形成有效页。随后第一批走原有 `.latest` 路径，重新回到最新消息并验证可选消息。

前台应用变化、群聊身份变化、取消、缺少权限或其他控制错误仍立即停止，不会被预热回退掩盖。

回退会写入诊断，但不会把预热读到的位置当作归档进度，也不会伪造历史起点。

### Home 进展不再重复累计

旧逻辑把 Home 落点的绝对辅助功能子节点索引反复加到 `loaded`。Qt 虚拟前缀不变时，同一个索引也可能重复出现，因而被误判为持续获得新历史，反复重置无进展计时。

新增 `WeChatHomeLanding` 和 `WeChatHomeAdvance`：

1. 第一次可读 Home 落点只建立基线，不计为新增消息。
2. 只有后续落点的子节点索引变小，才把差值记作向更早历史取得的进展。
3. 相同或更大的索引不算进展；虚拟单元、空框、未贴顶和不可读节点只算待定。
4. 没有可靠进展时仍调用现有 `probeKeyboardTop`。探测不确定就结束预热并进入正常导出，而不是继续空转。

这套索引只用于控制预热节奏，不作为消息数量、边界或 ZIP 完整性的证据。

### 可恢复的滚动降速

保留 PR 原有的 `WeChatScrollPacing`：增益小于 0.4 时只对当前加载片段临时降低请求上限、增加短间隔；连续两次可信健康测量或当前片段结束后，恢复受限前的间隔和上限。普通已测量滚轮步长约为视口 70%，仍受单次 520 单位上限、长气泡重叠和超距回退约束。

### 原有选区与保存合同

以下行为未改变：

- 键盘逐条数消息，每批最多 100 条，系统提示不计数。
- 终点贴顶时按约一行高度滚开；焦点仍属于同一条消息才按“选择到这里”。
- 系统提示占满视口、单消息、100 的整数倍和跨批续接继续使用现有历史边界策略。
- 已经原生导出的 ZIP 在后续加载或边界失败时继续交付；普通部分结果不替换完整归档检查点。
- 增量未确认重叠时不推进检查点，最多 40 批。

本次没有实现跨批局部预热或自动重启微信。要做这两项，必须先证明能从已归档边界可靠往返；不能复用会回到最新消息的初始预热函数。

## 资源边界

本程序仍只保留有限导航帧、诊断步骤和检查点，不缓存整段聊天正文。首窗限制减少的是首文件之前主动拉取的历史量和最长无产出预热，不保证微信进程内存有界。微信是否保留已访问的文字、图片和视频缓存由微信自己决定。

## 不操作微信的验证

在连接的 arm64 Mac 上，使用 Apple Swift 6.4 和本机 macOS 26.5 SDK 执行：

| 检查 | 结果 |
| --- | --- |
| 渐进长历史策略场景 | **35/35 通过**；覆盖首窗上限、30 秒预算、Home 单调进展、降速恢复、70% 步长和贴边合同 |
| 原有历史边界场景 | **25/25 通过**；生产边界代码和原场景未修改 |
| 原 FocusHold / ScrollStep / Prefetch 测试方法 | **30/30 通过**；独立断言运行器，不是 XCTest |
| 中英文资源校验 | **通过** |
| `git diff --check` | **通过** |
| `swift build --product xiaoai-archive` | **通过**；有既有 CLT 搜索路径和闭包捕获警告，不是零警告构建 |
| 完整 `swift test` | **受阻**；Command Line Tools 无法解析 `XCTest`，在既有 `BatchStagingTests.swift` 导入处失败 |
| 真实微信点击、加载、选择、分享和最终 ZIP | **未执行** |

复现：

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
mkdir -p .build/progressive-history-checks

swiftc -swift-version 6 -D LONG_HISTORY_STANDALONE \
  Sources/DukouCore/*.swift \
  Tests/DukouCoreTests/LongHistoryScenarios.swift \
  Scripts/check-long-history.swift \
  -o .build/progressive-history-checks/check-long-history
.build/progressive-history-checks/check-long-history

swiftc -swift-version 6 -D HISTORY_BOUNDARY_STANDALONE \
  Sources/DukouCore/WeChatHistoryBoundary.swift \
  Tests/DukouCoreTests/HistoryBoundaryScenarios.swift \
  Scripts/check-history-boundary.swift \
  -o .build/progressive-history-checks/check-history-boundary
.build/progressive-history-checks/check-history-boundary

python3 Scripts/check-scroll-regressions.py
swift Scripts/check-localizations.swift
git diff --check
swift build --product xiaoai-archive
swift test
```

## 诊断

`schemaVersion = 9` 保持不变。新增或调整的预热记录：

| 记录 | 用途 |
| --- | --- |
| `prefetch-plan` | 首窗目标、带余量目标和预算 |
| `prefetch-home.bestIndex` | Home 已确认的最小子节点索引，仅用于诊断进展 |
| `prefetch-fallback` | 预热为何放弃并回到正常导出 |
| `prefetchExit = fallback-*` | 预热错误已降级，不代表导出本身失败 |

原有 `pacingEvents`、`scrollPause`、`scrollCeiling`、`stopReason` 和 `boundaryStopped` 保留。诊断不记录聊天正文。

## 本机微信验收：尚未执行

| 场景 | 需观察的结果 |
| --- | --- |
| 条数 0、几年历史 | 不再要求先滑到历史起点；首窗到预算或无法确认后进入第一批选区，尽早产生首个有效 ZIP |
| 重复 Home 落点 | `bestIndex` 不变时不能持续增加 `prefetchLoaded` 或无限重置无进展计时 |
| 全量超过 300 条 | 第四批及以后允许再次遇到冷历史边缘；已完成 ZIP 必须保留，失败说明应区分加载与边界 |
| 几千条且含长文/大图 | 临时受限后恢复步长和间隔；同时记录微信内存峰值，不能把首窗限制误称为微信缓存上限 |
| 纯入群提示顶部、仅 1 条消息、100 的整数倍 | 仍正确收尾，不虚构下一批 |
| 批量多个群 | 上一群警告不留在下一群进行中状态，每群重新初始化节奏 |
| 增量 | 不执行全历史预热；未找到可信重叠时不推进检查点，最多 40 批 |

安装和真实验收仍按 `agent.md` 执行，保持原签名、Bundle ID 和唯一的 `/Applications/xiaoai-archive.app`。本次没有读取微信数据库、解密、注入、修改微信安装包或提交诊断原文。
