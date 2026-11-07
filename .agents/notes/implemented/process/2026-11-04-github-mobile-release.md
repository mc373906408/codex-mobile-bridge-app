# Agent Note: GitHub APK 与 IPA 发布流程

Status: implemented

## Problem

用户要求 GitHub 0.1 下载包。现有工作流只有未签名 APK/AAB 和 Runner.app，Android 包不能直接安装，iOS 也没有 Apple 签名配置。最近一次 CI 在 Windows Flutter 首次启动输出和 macOS Rust 组件下载阶段失败，无法直接把既有 artifact 当作发布包。

## Decision

版本由 `pubspec.yaml` 统一提供；当前发布版本为 `0.2.0+2`，GitHub tag 为 `v0.2.0`。Android 和 iOS 均继承同一版本及构建号，升级继续使用已有发布签名。Native Client 工作流接受显式 publish 调度或版本 tag；两个平台全部检查成功后，发布任务才汇总同一提交的包，生成 SHA256 清单，先上传草稿附件再公开 Release。发布任务单独持有 contents:write，构建任务保持只读。

Android 使用独立、持久化的发布密钥和 GitHub Actions secrets，缺少任一签名配置立即失败。普通 CI 构建保持未签名；发布 APK 须通过 apksigner、包名/版本与已有原生库对齐检查，证书摘要随构建报告公开。密钥和密码只在仓库外的受限本地目录及 GitHub secrets 保存，后续升级继续使用同一密钥。

iOS 使用 macOS 构建普通版本，保留 Payload 结构和执行权限，将 IPA 明确命名为 `ios-unsigned.ipa`，供用户自行签名。发布说明、README 和构建报告均声明不能直接安装，不把无签名压缩包当作已签名导出。原有 `build_ios.py` 的签名导出失败仍直接失败，不回退为未签名包。Apple 证书、配置描述文件或 TestFlight 可用后再增设正式签名分发决定。

cloud CI 同样输出 `ios-cloud-unsigned.ipa`，通过 `package_release.py ios --flavor cloud` 复用现有打包流程，`ios-cloud-for-user-signing-<commit>` 下载项包含 IPA、源码许可包和 `ios-cloud-build.json`。报告绑定源码提交、哈希、主程序标识、扩展数量及共享组配置；完整保留通知扩展，并检查主程序和扩展入口的执行权限。由 dyld 加载的 `App.framework/App` 在真实 Flutter 构建中为 0644，保留原权限，不将框架误判为缺少可执行入口。普通和 cloud 输入互斥，不能把普通包改名冒充 cloud；cloud 包版本须与扩展和 pubspec 一致。本次不新增 Apple 凭据或声称可免签安装，最终签名须使用与团队、APNs、App Group、共享 Keychain 配置匹配的主程序和扩展描述文件。

首版分发普通 SDK-free Android 与普通 iOS；云中转仍可用，不隐式启用开发推送凭据或未配置的 APNs 扩展。Flutter 在机器可读检查前完成首次启动，Rust setup 预装 rust-src，避免并行编译触发组件安装竞争。依赖锁文件和 FFI 快照沿用审定版本。

Android 原生回归先执行 Flutter `build apk --release --config-only`，由当前 Flutter 生成 Gradle wrapper 与 local.properties 后再直接运行 Gradle。新 checkout 没有这些被忽略的文件；仅在已构建工作区测试会掩盖缺失。初始化与 Gradle 都使用已剥离真实推送和签名凭据的环境。

iOS 使用 GitHub `macos-26-intel` 构建机。`macos-latest` 当前指向 ARM64，实测出现容量不足且多次调度后取消，官方 runner-images 列出同代 Intel 镜像可用。Intel 仍交叉编译 ARM64 iPhone 包，Swift/Rust 宿主接口测试按实际宿主选择 x86_64。Rust cache 在后续检查失败时也保存成功编译的缓存，重跑仍执行完整检查。

Cargokit 的 `.dill` 放在构建目录，启动时显式传入构建工具自身的 package_config.json；Android linker 包 URI 使用实际存在的 `build_tool.dart` 并检查解析结果。否则新 runner 的 kernel 执行时 `Isolate.resolvePackageUri` 返回 null，本机历史环境可能掩盖问题。回归把真实 kernel 编译至独立临时目录，验证在那里能解析现有 linker wrapper。

宿主 FFI 检查把原生库构建、Flutter 锁文件依赖准备和测试执行分成三个具名阶段，分别保留耗时及结果。Flutter 测试使用 `--no-pub`，每个用例限制 60 秒，包含启动和编译的测试进程限制 300 秒；原生构建限制 1200 秒，依赖准备限制 300 秒。失败不重试、不跳过，阶段 JSON 和测试事件 JSONL 随 CI 上传，旧事件在运行前清除。手动 `native_ffi_only` 调度仅执行 Windows/macOS 两个原生 FFI 用例文件，便于定点验证；正式发布仍要求完整检查。

手动 `swift_policy_only` 模式只执行普通 Swift 策略与真实 Rust 预览 ABI 门禁，用于[锁文件首次创建修复](../bug-fix/2026-11-06-ios-lock-first-creation.md)等原生问题的定点验证。它与 `native_ffi_only` 同时为真时优先执行 Swift；任何定点模式都不执行公开发布，完整打包需将两个选项都关闭。完整、FFI 和 Swift 模式使用各自的并发组，定点验证不取消正在运行的完整打包。

## 记录归属

检索 proposed/implemented/rejected 的发布、签名、APK、IPA 与工具链记录后：[手机部署](2026-11-04-current-schema-phone-deployment.md)只持有开发签名安装，部分重叠并互链；[云状态边界](../bug-fix/2026-11-04-cloud-state-boundaries-and-legacy-removal.md)持有依赖快照契约，本篇沿用；[架构省察](../architecture/2026-11-04-app-architecture-and-scope-audit.md)的发布缺口作为背景，不被本篇等同于真机验收。没有同主题过时提案需要归档。

[后续修改同步手机](2026-11-05-verified-changes-to-phone.md)规定每轮 App 修改的测试手机覆盖安装；本篇继续持有独立发布签名和公开下载流程，不把开发安装等同于公开发布。

## Alternatives considered

- 直接上传现有 CI 包最省步骤，但未签名 APK 无法安装，Runner.app 也不是 IPA，不能满足下载用途。
- 复用 debug 签名能覆盖现有测试手机，但会把开发身份变成公开发行身份，后续更新依赖开发机调试密钥，因此建立独立持久发布密钥。
- 等待 Apple 签名再发布能提供更完整的 iOS 安装体验，但当前没有证书或描述文件；提供诚实标注、可供用户签名的 IPA，同时让 Android 先具备直接安装能力。
- cloud 继续只上传 `.app.zip` 可以保留编译检查，但用户需要 IPA 交给安装或签名工具，因此复用同一打包器提供标准 Payload 结构和独立 cloud 报告；不能只改压缩包后缀。
- ARM64 macOS 与 iPhone 架构一致，宿主构建通常更快，但当前 GitHub 资源排队最终取消；采用官方同代 Intel 构建机，保留 iPhone 目标架构和全部接口/打包检查。
- 整个 Flutter 进程统一限制 60 秒能快速结束卡死，但会把首次启动、依赖解析和测试编译当作用例运行时间；仅无限延长进程又会隐藏卡死。因此准备阶段单独执行，用例和整个进程分别保留有界超时。

## Testing

发布脚本回归覆盖缺少签名、普通 CI 隔离签名、临时密钥清理、tag 与版本不一致、跨提交产物、缺少平台及篡改包拒绝。正式发布还执行仓库的 Python、Rust、Flutter、宿主 FFI、Android 打包、Swift/C ABI 与普通/cloud iOS 编译门禁。实际工作流成功、产物摘要与发布链接以 GitHub 对应 run 和 Release 为准。

2026-11-07 的 cloud IPA 打包调整通过 84 项 Python 脚本测试和 iOS cloud 静态契约检查，新增用例验证普通/cloud 互斥、扩展存在、扩展执行权限、版本不符拒绝、独立报告与哈希，以及保留 0644 的 dyld 框架。使用[界面源码 e306c4f 的 CI](https://github.com/mc373906408/codex-mobile-bridge-app/actions/runs/42314503834)已成功编译的 cloud 产物生成本机待签名 IPA：源 artifact `13550618918` 的 SHA-256 与 GitHub 元数据一致；添加 Payload 层后逐项校验字节和 ZIP 权限元数据完全不变，主程序、扩展和私有网络符号检查通过。IPA SHA-256 为 `13a357bea91cc0e23d57bd5b9fe4cdc0fd51781deb7b4ddabf213e7486763bf0`，文件与来源收据在 `.local/ios-cloud-delivery/`，下载目录另有同内容副本。该来源 run 的普通/cloud iOS 和 Swift 任务成功，但 Windows P2P 断引导节点测试遇到 ConnectionReset 失败，因此不能宣称整个 run 成功或据此触发正式 Release。此次仅修改打包工具和下载说明，App 运行代码与已编译 cloud 产物一致；没有签名、安装或 APNs 真机验收结果。

本地普通 release APK/AAB 已通过原生库与对齐检查，APK 发布证书 SHA256 为 `e0855b725569510207939b3d344196303ebb68171a8c8579ea197888360e99c7`。GitHub 第一轮 macOS 检查含普通 IPA 打包及 cloud 编译通过；后续最终版本须保持相同提交来源，不混用不同提交的构建报告。

## Consequences

用户获得有固定签名身份的 Android APK 与明确用途的 iOS IPA，可核对每个平台的来源和 SHA256。维护者必须备份 Android 发布密钥；丢失会妨碍后续原地升级。已有 debug 安装不能直接覆盖成正式签名。iOS 自行签名仍有账号、设备、有效期及工具限制，不等同于免配置安装；本流程没有消除真机与商店验收缺口。
