# Agent Note: 云连接恢复、通知撤回与旧配对接口清理

Status: implemented

## Problem

[全局省察](../../implemented/architecture/2026-11-04-app-architecture-and-scope-audit.md) 的 A1–A4 已由真实 FFI 复现：重新授权无法越过本地阻断，预览存储阻断聊天，撤回通知遗漏禁用设备，新建聊天记录跨账号可见。手动配对公开入口与自动发现并存，掩盖了这些接口条件；构建夹具和 HTTP origin 规则也未同步。

## Decision

业务连接、只读证明核验、通知资格缩减分别验证自身前提；预览故障只影响通知。待核实创建由当前认证客户端按账号查询，并在标记前再次核对同一账号。Server 撤回入口只要求手机自身有效且拥有目标绑定，保持启用的严格条件。App 的手动申请/撤回/确认接口和生成 FFI 中的对应入口已移除，自动发现直接使用服务器分配的 binding ID。

[连接等待与设备重连](2026-11-05-connecting-conversation-list.md)规定已保存身份的设备在刷新或锁屏恢复后等待当前授权检查，而不重复弹出首次连接窗口；本篇的原生阻断和迟到结果校验仍是业务访问前提。

## 权限、状态与持久化

- `_open(verificationOnly: true)` 只由配对证明/状态读取调用，`_call` 的业务路径仍拒绝 blocked。查询结果同时核对 client 身份、账号 enabled 与 generation；迟到结果不能恢复被再次关闭的连接。目录或密钥核验失败会先封锁 repository，再清除界面权限。
- `_savePreview` 单独记录通知存储失败，业务认证成功仍可返回；聊天入口显示通知存储警告，云通知等待预览恢复。Android 和 iOS 使用精确、含 scheme 的 HTTP/HTTPS origin，拒绝默认端口冗余、大小写/凭据/路径/query 等不规范形式；不存在 HTTPS 自动降级。
- 推送控制器保存当前账号的全部已保存 binding；业务读和启用 endpoint 仍要求有效连接，关闭 endpoint 用独立 `cloudWithdrawPush`，不建立 Noise 业务通道。关闭失败单独显示未确认，重试每原生状态版本最多六次；退出账号仍停止这类工作。Server 在事务内核验自己的手机/账号/会话及目标所有权，取消 queued/leased 任务；禁用、对端退出、对端撤销或服务到期不阻止缩减权限。此处原有“用户单独开启且恢复访问不恢复已撤回 consent”的前提由[云登录默认通知](2026-11-05-cloud-notifications-on-login.md)按用户要求取代；权限缩减、账号隔离及不补发历史事件仍成立。
- 创建待核实记录从 `LocalDatabase` 无账号接口移至已认证 `BridgeClient`；SQL 同时过滤 computer 与 scope 中的账号身份。UI 持有记录的 `accountIdentity`，标记时重新认证并比较；切换身份后不能核实对方记录。历史记录不删除，未知写入不重放。

## 兼容清理边界

清除 App 的 `PreparedRelay`、手动 gateway 列表、`prepareRelay/requestRelay/cancelRelay/confirmRelay`、相关 account 方法、Rust API 和生成绑定。保留自动目录、加密证明、取消发现以及本地直连配对。原先为旧 `request_attempted` 保留的读取迁移，已由[当前存储格式](../simplification/2026-11-04-current-cloud-storage.md)取代：凭据只接受完整当前字段，SQLite 直接创建当前表，旧格式明确拒绝。

用户随后明确桌面也要清理且旧开发数据无需保留，三端协同删除了剩余手动入口和旧配对表。Server 也移除旧邮箱激活接口并从当前 schema 初始化。原先保留跨端兼容的理由是其他消费者仍有调用；现在调用方、服务端和测试一起更新，不再保留这条执行路径。

## 构建和测试入口

`prepare_build.py` 是显式升级 SDK、依赖和重新生成 FFI 的入口。Android/iOS 打包及 CI 调用 `verify_build_snapshot.py`，强制 pub/Cargo lockfile，记录 SDK 版本与应用、Rust、CocoaPods、生成 FFI、Cargokit lockfile 哈希；iOS 使用 `pod install --deployment`。Cargokit 的 Windows/POSIX runner 使用自身审定 lockfile，不再在缓存失效时升级临时 runner 包。

这不等于跨机器二进制位级可复现：SDK 仍按 stable 策略选择，报告记录实际版本；签名、平台工具和最终产物还需要各自验证。Windows 测试夹具保留 home 定位变量，不再因清空环境而在检查目标条件前失败。真实 repository 回归加入 `test_native.py`，使用合成密钥、临时 SQLite 与随机回环端口，不访问真实账号。

## Alternatives considered

- 直接清除本地 blocked 能快速恢复，但在加密证明重新核验前会打开业务入口；采用只读核验权限，成功后再恢复连接。
- 只修 Server 能接受关闭请求，但 App 会先把设备移出工作列表，故两端一起修。
- 删除当前账号切换后的未知操作能避开状态冲突，但损害核实证据，因此当前格式内保留记录并按账号隔离。旧开发格式曾选择读取迁移以保留身份；用户撤销这一前提后的取舍由当前存储格式笔记单独持有。

## Consequences

连接恢复、通知撤回和聊天操作各自持有足够小的权限，预览故障不再使控制链路不可用；账号查询范围与创建写入范围一致。代价是专用核验/撤回接口及其并发校验需要持续维护，真实 FFI 测试比纯 fake 更依赖宿主编译工具。六次撤回失败后仍是未确认，重新打开应用会重新尝试，不能宣称已删除厂商持有的数据。清除旧 App API 要求发布时同步生成 Dart/Rust 绑定，不能混用旧 DLL。

## Testing

验证日志和改动前副本位于本机 `D:/github/.codex-tools/architecture-fixes-20261104/`，正式回归保存在仓库测试目录。真实 FFI 覆盖关闭后恢复、迟到响应、错误账号撤回、预览失败与恢复、关闭后撤回、跨账号创建记录，以及既有写入不重放烟测。Server 使用单独的 PostgreSQL 18.1 回环实例，覆盖四种访问丧失状态、跨手机/账号、调用方会话失效和 queued/leased 取消。Android 编译覆盖默认及推送 opt-in 源集，并运行本地单元测试。

最终收尾日志位于 `D:/github/.codex-tools/architecture-closeout-20261104/`：Flutter 292 项（含真实 FFI）、Rust 核心 62 项、Python 辅助 68 项通过；静态分析、clippy、FFI 生成、快照校验与 Android 两种源集编译/单元测试通过。过期 FFI 夹具已移除旧字段，旧格式拒绝由独立 Rust 测试覆盖。

iOS origin 与 Swift 测试源码同步，Windows 仅运行 Xcode 源码图检查，未执行 Swift/Xcode、签名设备或真实推送验收；没有生产部署、安装或提交推送。

用户随后要求的 [ARM64 手机部署](../process/2026-11-04-current-schema-phone-deployment.md)已完成；该记录持有实际 APK 哈希、覆盖安装、旧库初始化与启动验证，不将开发机测试外推为真实账号或推送验收。
