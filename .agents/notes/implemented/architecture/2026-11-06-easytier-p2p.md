# Agent Note: 手机 EasyTier 直连与云授权结果

Status: implemented

## Problem

云连接业务当前依赖中继 WebSocket。需要 Android/iOS 应用内 P2P，且云暂时离线不误撤销已建立直连。

## Decision

共用桌面仓库维护的固定版本 Rust EasyTier 封装，以带源码摘要的本地快照参与移动构建，不要求系统 VPN。P2P 是已有云绑定的运行时传输，不改变 computer ID、密钥、草稿或配对。每路径独立 Noise 会话，新请求优先 P2P，在途写入不重放；显式权限失败撤销受影响路径，网络失败保留存活直连。新会话仍需在线校验。

前后台、退出账号和授权结果由统一连接管理器管理。显示实际传输及字节数；云目录 offline 不覆盖已验证的存活 P2P。Android/iOS 同批实现，iOS CI 构建与用户真机验收分别报告。

服务端主动发送作用于当前身份的 `access-v1` 信令，客户端核验最新状态后关闭失效路径。引导 RPC 支持平台证书校验的 WSS 管道复用既有 HTTPS origin，不使用上游跳过证书验证的 WSS 连接器。当前线上 origin 使用 8787 端口，客户端不能假设 443。CI 序列化测试每轮两个独立 store 竞争一次，避免单个 worker 连续执行二十次 fsync 导致另一方饥饿；总写入次数仍为四十，生产锁超时及单独的超时测试不变。

## 记录归属

[持久中继 v2](../../implemented/architecture/2026-11-05-persistent-relay-v2.md)及[应用架构审查](../../implemented/architecture/2026-11-04-app-architecture-and-scope-audit.md)部分重叠，保留原协议、持久身份和授权边界。本篇接管 P2P 路径和离线存活行为。检索未发现其他 EasyTier/P2P 提案，无完全重复或过时提案。

## Alternatives considered

- 外部 VPN 客户端减少集成工作，但不满足应用内自动接入。
- 云断开即停止直连简单，但违背用户确认的延迟撤销规则。
- 只实现 Android 风险较低，但用户明确要求 iOS 同批。

## Testing

真实 Go/Python/Rust 夹具通过线上 WSS 引导完成直连、20 MiB 下载和并发读取、未知写入不重放、云断开存活及恢复后撤销关闭。66 项 Rust 测试、Clippy 和 318 项 Flutter 测试已通过；两个真 FFI 测试在普通 Flutter 测试中按既有机制跳过，由原生 CI 单独执行。ARM64 Android 构建及 16 KiB 对齐已通过，最终手机签名、安装和 iOS 普通/cloud 构建以对应交付记录为准。无签名构建保留 Flutter/Xcode 的详细输出，避免通用签名提示遮蔽底层编译错误。iPhone 真机验收由用户执行，不以 CI 替代。

共享核心快照包含桌面的 `Cargo.lock`，在 Windows/macOS CI 中独立运行真实双节点测试，检查直连收发、引导丢失后的存活和接收端端口隔离。该测试使用用户态网络与临时端口，不操作用户账号或系统 VPN；宿主机互通仍不能代替 iPhone 的真实网络验收。

`netdev 0.31.0` 的 Darwin 后端引用了仅由 macOS libc 导出的 `RTAX_MAX`，导致 iOS Rust 编译失败。共享封装保存该依赖的 MIT 源码，对 iOS 补充 Apple `route.h` 规定的八槽常量；macOS 继续引用 libc，不改路由结构。Apple 官方头文件将 `SCNetworkInterfaceCopyAll` 及网卡描述访问器标为 iOS SPI，因此 iOS 省略可选显示信息并保留公开 `getifaddrs` 地址发现；产物检查拒绝主程序、扩展或框架残留这些内部符号。对应源码归档从已核验快照清单取文件，排除独立测试生成的 `target/`。

## Consequences

数据直连减轻中继带宽，运行状态和字节计数可核验实际路径。新增 Rust 依赖增加体积和首次构建时间。iOS 后台挂起、NAT 变化和设备省电可能终止连接，恢复新会话必须在线检查。上游 LGPL 许可随 App 展示，分发附对应源码及重建说明。真实设备耗电和各运营商打洞成功率尚不是既有回归可证明的结论。
