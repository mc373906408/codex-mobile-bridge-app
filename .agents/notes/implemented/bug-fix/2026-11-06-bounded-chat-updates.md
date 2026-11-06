# Agent Note: 长会话实时更新只读有界页面

Status: implemented

## Problem

用户报告长聊天持续出现“请求或响应数据超过安全大小限制”，错误条还把导航和正文向下挤。代码定位到首屏使用有界 timeline，但 watch 仍读 `/events` 或 `/poll`；网关两条旧路由调用 `bridge.view` 序列化整段会话，达到 App 8 MiB 防护后会反复失败。手机实际只用 SSE 事件名或丢弃 poll 的 state，再读取当前页面，这些大响应没有产品价值。

## Decision

后续用户明确要求移除 JSON 响应 8 MiB 限制，取代决定见[取消 JSON 响应上限](2026-11-07-remove-json-response-cap.md)。本篇继续持有 changes、分页与悬浮提示；下文保留原先阈值的测试结果属于该轮验证。

Codex watch 使用已有 `/changes` 的 host、after、epoch、start 等参数等待当前窗口变化，再读取受大小限制的 timeline 快照。delta 只作为刷新信号，不能授予操作权限。404/405/501 或无 epoch 的旧网关退到每三秒读取 timeline，不再退回全量事件。成功的短等待有 250 ms 最低间隔；错误沿用退避，取消、身份与未知写入约束不变。删除只用于旧订阅的 SSE 解码器，保留传输响应、附件、请求体及密码学上限。

错误条使用页面内悬浮层，显示和关闭不改变导航、滚动区、输入框坐标；可关闭、向辅助功能播报，不自动清除未知写入。文案区分“读取聊天时更新客户端/网关”与附件问题，不将所有大小错误归因于用户附件。

## 记录归属

检索响应、恢复、订阅和错误记录后，[原生玻璃](../architecture/2026-11-06-native-clear-glass.md)部分重叠，仅共享页面层级；[架构省察](../architecture/2026-11-04-app-architecture-and-scope-audit.md)与[响应完成](2026-11-04-relay-response-completion-and-recovered-errors.md)继续持有认证、未知写入和读取错误归属；[读取恢复提案](../../proposed/bug-fix/2026-11-05-cloud-chat-recovery-and-notice-scope.md)继续持有恢复语义。本篇不重写这些决定，没有需要归档记录。

## Alternatives considered

- 调大 8 MiB 阈值能暂时容纳更多历史，但会继续增长、放大手机内存和流量负担；改用已有有界接口。
- 让 SSE 解码器跳过大 payload 可减少客户端内存，但仍传输完整会话，旧 poll 回退也会失败；停止请求两条旧接口。
- 修改网关 SSE 的既有 wire shape 可以压缩响应，但影响网页客户端并要求同步部署；复用现有 `/changes`。

## Testing

Rust 回归 68 项通过、1 项跨语言 P2P 专用夹具依既有条件跳过。新增 9 MiB 旧响应夹具断言 SSE/poll 宣告下均只请求 changes 与分页；保留远程 host 与游标，delta 的错误 host/account 不会被授予 authority。401 停止订阅，取消不发送停止命令，旧网关有限频率回退，8 MiB JSON 拒绝仍生效。Flutter 全量 354 项通过、2 项原生入口依既有条件跳过；错误显示/关闭时输入框、标题、滚动区坐标和滚动偏移完全相同，并验证可点击关闭。没有放宽现有 JSON、附件或中继帧限制。

Android 构建和同签名安装证据见[原生玻璃](../architecture/2026-11-06-native-clear-glass.md)。安装后打开用户截图对应的远程长会话，在约一分钟内采集五次 UI 树；三次包含完整标题和可编辑输入区，均无大小错误或历史离线提示，另外两次 UI 树不完整，不计作成功证据。最终真机截图显示正常内容与输入区，当前进程无启动/布局异常。采样不代表所有网络情形或 iPhone 真机已验收。

## Consequences

实时更新传输量不再随完整会话持续增长，错误提示也不再改变当前阅读位置。旧网关回退有最多三秒读取延迟；极端 metadata 或单条异常内容仍可能超过防护，不能宣称所有大小错误均已消失。当前截图没有设备网络日志，根因由完整读取链路及合成复现证明，真实 iPhone 验证仍需单列。
