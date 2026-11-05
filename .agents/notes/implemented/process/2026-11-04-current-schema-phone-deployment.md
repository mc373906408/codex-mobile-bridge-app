# Agent Note: 当前存储结构手机端部署

Status: implemented

## Problem

用户要求将配套客户端部署到已连接手机。Lenovo L71091 上现有开发包仍使用 schema v2，而当前客户端只打开空库或 schema v3；服务端已切换全新数据库，原云登录和设备绑定也已失效。仅覆盖 APK 会留下启动失败的旧存储。

## Decision

手机部署使用 ARM64 debug APK，沿用开发签名及既有 debug 推送配置；实际 Flutter 3.47.8、Dart 3.13.7、Rust/Cargo 1.96.0、FRB 2.13.0，与构建快照核对一致。安装目标经型号、ABI、包名和安装元数据验证，为 Lenovo L71091、Android 13/API 33、`dev.waken.bridge_mobile`。ADB 覆盖安装成功后设备 APK 与构建包的 SHA256 均为 `4eacc9f66a279bda66a3300664ba637ff0368f9c1a3e8eec580d885151cff489`。

依据用户“尚未上线，历史数据库和已有绑定不需保留”的决定，对此 App 执行一次 `pm clear` 本地初始化，删除旧账号凭据、连接、草稿和推送同意。安装身份不经卸载重建，其他 App 不在操作范围。启动后的 SQLite（包含已提交 WAL 页）为 schema v3；没有加入兼容迁移。真实账号、配对和通知同意由用户重新完成，部署不自动注册或授权。此安装属于开发验收，不作为正式商店发布。

## 记录归属

检索现有 proposed/implemented/rejected 后没有手机部署过程记录。[当前存储格式](../simplification/2026-11-04-current-cloud-storage.md)持有拒绝旧 schema 的决定，[云状态修复](../bug-fix/2026-11-04-cloud-state-boundaries-and-legacy-removal.md)持有锁文件及 FFI 快照边界；本篇部分重叠并互链，全局架构省察不承担具体安装结果。

## Alternatives considered

- 保留 App 数据能延续安装身份和偏好，但实测为 v2 且对应服务端账号已重建，当前构建会明确拒绝旧库，因此按用户已确认的开发数据清理选择重新初始化。
- 卸载重装可以重建数据，但会改变安装身份且不是覆盖安装的必要步骤；采用签名匹配的 `install -r` 后对目标包执行数据初始化。
- 直接分发 release APK 更接近正式发布，但现有设备是 debug 签名且此任务是本地部署，使用同签名 ARM64 debug 包避免引入签名迁移。

## Testing

构建前后 345 个源码/配置文件哈希一致，锁文件/生成代码未升级；10 个 ARM64 原生库的 16 KB ELF 与 ZIP 对齐通过，APK v2 签名验证通过。与本机已配置的服务端 Master Secret 值进行字节扫描，APK 未包含服务端推送签名秘密，构建子进程也不接收该值。包大小 208346015 字节，构建用时约 522 秒。

`adb install -r` 返回 Success，设备 APK 哈希完全匹配，首次安装时间保持。清理目标 App 后启动 Activity 返回 ok，进程持续运行，启动日志未发现崩溃、未处理异常或原生库加载失败，SQLite v3 初始化成功。手机系统 curl 默认验证 TLS，访问 `https://bridge.waken.cloudns.be:8787/readyz` 和 capability 成功，确认自动目录、桌面权限及邮箱先验证再设密码的能力。此网络检查不等同于 App 登录、Noise 中继或真实推送送达。

证据、APK、脚本与构建/安装日志保存在 `D:/github/codex-mobile-bridge-app/.tmp/phone-deployment-20261104/`。原 5037 ADB daemon 在短命令退出后消失，因此任务采用单独 5038 后台 daemon 保持已配对设备连接；安装验证结束后停止任务 daemon。操作中没有读取或打印旧账号凭据，没有自动点击手机页面、同意隐私提示或授予设备配对。

## Consequences

手机当前运行与新服务端配套的存储和 FFI 契约，避免旧库阻止启动。目标 App 的旧账号、连接、草稿、偏好及通知同意已删除，需要重新注册/登录与登记设备，通知同意不自动恢复。此手机为 Android 13、4 KB 内存页，不能代替 16 KB 真机验证；真实端到端连接依赖更新后的桌面客户端、有效账号和桌面明确授权。本轮没有正式发布签名、iOS 安装、真实登录/配对/推送或 Git 提交推送。

随后[登录后隐藏服务器选择](../bug-fix/2026-11-04-server-selection-only-when-signed-out.md)使用同签名覆盖更新，保留当前 v3 数据与账号；本篇的一次性 v2 清理不适用于后续普通界面更新。

[后续修改同步手机](2026-11-05-verified-changes-to-phone.md)持有用户要求每轮 App 改动验证后更新测试手机的交付约定，沿用数据保留的覆盖安装方式。

[GitHub 发布流程](2026-11-04-github-mobile-release.md)使用独立 Android 发布签名，并提供明确标注的 iOS 待签名 IPA；不沿用本篇的开发签名身份。
