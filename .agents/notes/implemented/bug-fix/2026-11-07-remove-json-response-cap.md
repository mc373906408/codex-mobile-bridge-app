# Agent Note: 按用户要求移除 JSON 响应 8 MiB 限制

Status: implemented

## Problem

用户在了解 8 MiB 是客户端人为设定的单次响应阈值后明确要求“把这个删掉”。有界变化与分页已避免实时下载完整历史，但 JSON 解码器仍独立拒绝超过 8 MiB 的合法响应，和本次要求不符。

## Decision

通用网关 JSON 解码删除 `MAX_JSON`，直接完整读取响应字节再解析 JSON。带 Content-Length 和未知长度的分块响应都不再触发这一阈值，也不改为更大的数字。HTTP 状态处理、有效 JSON 对象要求、请求超时、身份和操作授权保持原行为。Codex 的有界 changes 与分页刷新继续使用。

`bounded_bytes` 仍服务于附件下载和独立云账户 API；附件、中继传输、请求体、密码学帧等各自的大小约束不属于用户本次指明的 JSON 8 MiB 限制，不在这次更改。

## 记录归属

检索 MAX_JSON、8 MiB、单次响应和有界更新笔记后，[长会话更新](2026-11-06-bounded-chat-updates.md)部分重叠，本篇明确取代其保留 8 MiB 的决定；它的分页更新、未知写入与悬浮提示规则继续成立。[原生玻璃](../architecture/2026-11-06-native-clear-glass.md)无关，保持原决定。没有完全吸收或需要归档的记录。

## Alternatives considered

- 保留 8 MiB 并只依靠分页，可以预先约束单次内存占用，但用户明确要求取消此阈值，不能继续保留。
- 将阈值提高到更大的常数，修改较小，但仍是人为限制，不能满足“删掉”的要求。

## Testing

Rust 全量测试 70 项通过、1 项跨语言 P2P 专用夹具按既有条件跳过。回归覆盖 HTTP 返回 9 MiB 的合法 JSON、没有 Content-Length 的多字节分块 JSON 超过 8 MiB，以及大体积非法 JSON 继续按协议错误拒绝；分页更新、认证、未知写入与中继回归均通过。笔记树、格式、归档校验通过。

按[手机交付规则](../process/2026-11-05-verified-changes-to-phone.md)已构建 Android ARM64 debug APK，10 个原生库的包装、页对齐和 zipalign 检查通过。构建前后 242 个源文件哈希一致，APK 对应源码 `0bd1f4ec77333bae451adaa5128be07162b7e613`，SHA-256 为 `e573acf5899da37ac219826028f27f8d19bc527c9eacb5245084276d24f9abb9`。证书 SHA-256 为 `79cc12dccddc4606767c48dca5668b9a26cfc7b334275ef555a0ab606ac55797`，与上轮已验证安装一致。

构建前后检查 USB 与无线调试均未发现测试手机，原地址拒绝连接，因此本轮未覆盖安装，也没有宣称设备哈希与启动已验收。设备恢复连接后仍须重新核实身份、当前签名、包哈希与启动。构建证据保存在忽略目录 `.local/remove-json-cap-delivery/`。

本提交的 [CI](https://github.com/mc373906408/codex-mobile-bridge-app/actions/runs/42311055826) 已启动；2026-11-07 07:26（UTC+8）复核时 Swift ABI 检查通过，Windows、普通版与云服务版 macOS/iOS 构建仍在运行，尚无本轮最终结果；没有 iPhone 真机验收。

## Consequences

合法 JSON 响应不再仅因超过 8 MiB 被客户端拒绝，分页实时读取继续降低常规传输量。单次响应会完整进入内存，取消这一额外阈值后，实际占用取决于响应大小及 JSON 解析；本次遵循用户选择，不宣称整个传输链路没有其他独立约束。
