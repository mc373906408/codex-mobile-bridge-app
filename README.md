# Bridge Mobile

[简体中文](#简体中文) | [English](#english)

## 简体中文

基于 Flutter + Rust 的原生移动客户端，用于连接你自己部署的
[codex-mobile-bridge](https://github.com/try2love/codex-mobile-bridge) 网关。
兼容基线为网关 v2.1.6，提交 `b6dde4da8ad4f083c66ab9f1f3770758d623af76`。
普通直连无需修改该兼容基线网关；云中继需要支持该协议的电脑网关和独立云服务。
本应用不是任意 RPC 或桌面 IPC 的转发代理。

### 功能特性

- 支持多台电脑、密码登录和一次性二维码配对。
- 支持 Codex、Claude Code/Cowork、DeepSeek 的聊天列表、搜索和分页历史记录。
- 根据网关声明的能力开放新建聊天、继续会话、发送消息、附件、审批、停止任务以及模型和推理强度选择。
- 通过 Rust 处理 Codex SSE/长轮询，以及桌面客户端的会话详情轮询。
- 提供本地草稿、应用内未读动态、中英文界面、浅色/深色主题和手机/平板布局。
- Android 自动后台系统通知：任务完成、等待确认提醒，支持测试通知和点击进入原聊天。
- 登录凭据保存在操作系统安全存储中；SQLite 用于保存配置、草稿和结果待核对的操作，不保存完整聊天归档。

普通连接直接访问所选网关；也可显式配置 hosted/selfhost 云账号并配对端到端加密中继，
配对仍须在原电脑网关本地确认。应用不存储模型 API 密钥，也不执行远程 HTML。
已加入云账号、配对和通知设置界面，以及 Android 生产 U-Push / iOS cloud flavor 的 APNs 接入代码；
原生签名、厂商实际送达和后台真机验收尚未完成，详见[云通知与验证边界](docs/cloud-notifications.md)。
Android 正式版/profile 默认不包含友盟 SDK；生产推送须构建时显式选择，并在设备上另行同意。
调试包的[联想 U-Push 测试](docs/umeng-push-test.md)仍是独立的手动实验，其同意不能授权生产云推送。
Android 二维码扫描使用随应用打包的识别模型，无需在设备上安装 Google Play Services。
FCM/独立 OEM 通道、终端/Git/文件工作台、编码客户端账号切换及客户端生命周期管理暂未支持。

**聊天和控制写操作绝不自动重发。** 超时或响应不明确时，操作会保留为待核对状态，重启后仍然有效。
请先在电脑端查看实际会话结果，再手动清除对应的待核对记录。

#### 选择和预览图片

点击聊天输入框旁的 **＋ → 相册图片**，通过系统图片选择器选择照片或截图；
支持任意附件的客户端还提供独立的“文件”入口。选中的图片会显示在输入框上方，
点击缩略图可放大、双指缩放，点击右上角的叉号可从草稿移除。
附件栏横向滚动，最多 8 个附件，每个不超过 20 MiB。

选择附件会先上传到当前网关，点击“发送”才提交消息。系统选图返回时，应用会等待
原聊天、原账号的连接恢复，不再静默丢弃图片；连接等待超时会提示重新选择。
已确认的上传即使切到后台也会保留到原草稿，未知结果不会自动重传。
PNG、JPEG、GIF、WebP 支持图片预览，不需要申请全盘文件访问权限。

#### 返回首页

点击左上角的桥形图标，可从聊天页、聊天列表或登录页返回“我的电脑”首页。
顶部只显示图标，不显示品牌文字。返回时会保存当前草稿并停止实时读取，
不会删除已保存的连接、登录凭据或待核对记录。草稿保存失败时会保留编辑器；
写操作尚未完成时，首页按钮不可用。
安卓后台通知自动监听，不会因返回首页而关闭。

#### 移除已保存的连接

在“我的电脑”首页，将网关卡片**从右向左滑动**，在弹窗中核对网关名称和地址后确认移除，
也可以取消并恢复卡片。普通点击仍用于连接；向右滑动不会删除。
移除操作只清除这条连接在手机上的登录凭据、草稿和待核对记录，
不会删除电脑上的网关或聊天。无需先登录网关即可移除已保存的连接。

#### Android 后台通知

后台任务通知随应用启动自动监听，不提供应用内开关或常驻通知的“停止监听”按钮，
旧版保存的关闭状态也不再生效。Android 13+ 首次启动会请求系统通知权限，允许后自动开始监听。
拒绝后不会在每次打开应用时重复弹窗；可在**设置 → 安卓通知 → 通知权限**中进入系统设置授权，
返回应用即自动恢复。可点“发送测试通知”检查手机通知栏；测试成功只证明本机通知可用，不代表网关事件已经送达。
两个系统通知类别分别用于任务动态和后台连接，请勿禁用任一类别。

- 直接读取已保存网关的 `/api/mobile/events`，不修改网关，不依赖 Google 服务或第三方推送账号。
  网关必须可达、登录有效，并已启用通知能力。
- 使用带常驻通知的前台服务，每轮结束约 12 秒后继续读取；网关超时会延长间隔。
  回到首页、后台或移除最近任务卡片不会主动停止监听，但系统仍可能回收进程。
- 首次连接或账号/事件流变化时只建立基线，不弹历史通知。权限恢复保留原有去重记录；断线恢复每轮每个网关最多提醒
  最近 10 条；本机通知路由最多保留 20 条。较早的动态仍可在应用内查看。
- 通知只显示通用事件类型和电脑名称，不复制聊天正文；锁屏公开版本不显示电脑名称。
  点击后重新验证网关身份和事件，才打开原提供商、原执行环境中的聊天，不自动发送或确认操作。
- 此模式持续联网并使用有超时保护的 CPU 唤醒锁，会增加耗电。可在“电池设置”中手动允许 Bridge
  后台运行；应用不会自动修改省电豁免。Doze、厂商省电限制、断网、强制停止或系统回收都可能延迟或中断提醒。
- 不承诺“杀进程也必达”，也不会在开机后自动启动。重新打开应用会在系统权限允许时自动恢复监听。
  系统通知权限和电池限制仍由安卓管理；移除网关会清除对应通知及本机去重记录。

### 开发环境

准确版本以 `toolchains.json` 为准：Flutter **3.47.8**、随附的 Dart **3.13.7**、
Rust/Cargo **1.99.1**，以及 Dart/Rust 两端的 flutter_rust_bridge **2.13.0**。
请使用仓库中的 `pubspec.lock`、`rust/Cargo.lock`、`.fvmrc` 和 `rust-toolchain.toml`，
不要在构建过程中自动升级到未固定的依赖版本。

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter --no-version-check --suppress-analytics pub get --enforce-lockfile
python scripts/check_toolchains.py
```

构建辅助脚本要求 Python 3.11+。Windows 上运行宿主机 Rust 测试，还需要安装带 C++
桌面开发工具链的 Visual Studio。请将 Flutter、Rust 和 Python 加入 PATH；
Android 辅助脚本会提供隔离的 Java/SDK 环境。

同一个工作目录中的 Flutter 测试、静态分析和构建应**依次执行，不要并行运行**，
因为它们共享生成的插件注册文件。并行执行调试/测试与发布构建，可能把仅供测试的集成插件带入发布包。
平台构建脚本刻意不使用 `--no-pub`：在当前固定的 Flutter 版本中，该参数还会跳过按构建模式
重新生成插件注册文件，导致后续发布构建残留调试集成插件。

#### Windows 构建 Android

```sh
python scripts/bootstrap_android.py --accept-licenses
python scripts/build_android.py
```

初始化脚本将经过 SHA-256 校验的 JDK 和命令行工具压缩包下载到 `.local/`，
并校验安装后的 SDK、NDK 和 CMake 文件，不替换其他项目的 SDK，也不修改全局 Flutter 配置。
下载进度日志位于 `.tmp/`。如需不带认证的本地 HTTP 代理，可通过 `HTTP_PROXY` 和
`HTTPS_PROXY` 设置；仓库不提交特定机器的代理配置。

构建脚本默认生成**未签名**的发布产物：

- `build/app/outputs/flutter-apk/app-release.apk`
- `build/app/outputs/bundle/release/app-release.aab`
- `build/reports/android/`：记录 SHA-256、所有打包 ELF 的 LOAD 段对齐、APK ZIP 对齐，
  以及 AAB 的 bundletool `PAGE_ALIGNMENT_16K` 检查结果。

16 KB ELF 检查覆盖两个 64 位 ABI 和所有 Rust 核心库变体。
旧版 32 位扫描依赖会明确记录为面向旧设备的仅支持 4 KB 对齐组件，不宣称其具备 16 KB LOAD 段对齐。

[2026-10-28 验证记录](docs/verification-2026-10-28.md) 列出了已测试产物和仍需完成的发布检查。
本地生成的 `build/app/outputs/flutter-apk/app-local-test.apk` 是可安装的发布模式测试副本，
**仅使用 Android 调试证书签名**，不是生产签名交付物。
构建脚本不会自动生成该测试副本，也不会用它悄悄替换未签名发布包。

如需可直接安装的开发调试包：

```sh
python scripts/build_android.py --format apk --debug --abi arm64-v8a
```

联想设备上的友盟测试只在调试包中使用 `UMENG_PUSH_APP_KEY` 和
`UMENG_PUSH_MESSAGE_SECRET` 环境变量；可选 `UMENG_PUSH_CHANNEL` 默认 `lenovo_test`。
旧版测试同意不会直接启用 SDK，需要在设备上重新同意 v2 说明。
App Master Secret 仅供服务端使用，不进入客户端；该调试实验不接入自动云补发链路。
请按[真机验证清单](docs/umeng-push-test.md)手动测试，构建成功不代表推送已送达。

生产云推送另需 `BRIDGE_ANDROID_PUSH=umeng`，以及通过安全构建环境注入的
`UMENG_PRODUCTION_APP_KEY`、`UMENG_PRODUCTION_MESSAGE_SECRET`；可选
`UMENG_PRODUCTION_CHANNEL`。该选择只影响 release/profile，不把联想 debug 测试同意迁移为生产同意。
客户端 Message Secret 与服务端 `UMENG_APP_MASTER_SECRET` 是不同凭据。
生产厂商库仍须逐项通过 ABI/16 KB、签名、隐私与真机验收，不能沿用历史 SDK-free 产物的结论。

正式发布签名需要同时提供 `BRIDGE_KEYSTORE_PATH`、`BRIDGE_KEYSTORE_PASSWORD`、
`BRIDGE_KEY_ALIAS` 和 `BRIDGE_KEY_PASSWORD` 四个环境变量。不要提交签名文件或密钥。
发布构建不会自动退回调试证书。详见[发布检查清单](docs/release-checklist.md)和
[分发说明](docs/distribution.md)。

#### 测试

```sh
python -m unittest discover -s scripts/tests -v
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo clippy --manifest-path rust/Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
flutter --no-version-check --suppress-analytics analyze
flutter --no-version-check --suppress-analytics test
python scripts/test_native.py
```

原生打包还有一项工具链回归测试：进入 `rust_builder/cargokit/build_tool/`，先运行
`dart pub get`，再运行 `dart run test/project_toolchain_test.dart`。
准确版本与锁定依赖构建的修复说明见该第三方目录中的 `LOCAL_PATCHES.md`。

未提供原生库路径时，常规 Flutter 测试会按设计跳过宿主机 FFI 冒烟测试。
`scripts/test_native.py` 会构建并加载真实原生库，验证异步 FFI、持久化、流取消和写操作至多执行一次。
测试数据均使用合成会话和凭据。

设备端测试还会验证打包后的 JNI 库和平台安全存储：

```sh
flutter test integration_test/native_startup_test.dart -d <device-id>
```

在 Windows 上准备 16 KB 模拟器工具，可运行 `python scripts/bootstrap_android.py --with-emulator`。
静态对齐检查通过，不代表 APK 已实际在 16 KB 设备上运行。
启动并明确选择设备后，运行 `python scripts/test_android.py --device <adb-serial>`，
验证其 16 KB 内存页大小并保存原生集成测试报告。
仅在测试常规 4 KB 设备时使用 `--page-size 4096`；它不能替代 16 KB 设备验证。

#### iOS

在安装了 Xcode 和 CocoaPods 的 macOS 上，准备相同版本的 Flutter/Rust 后执行：

```sh
flutter pub get --enforce-lockfile
rustup target add aarch64-apple-ios
flutter build ios --release --no-codesign
```

以上只生成未签名构建，不是可提交 App Store 的 IPA。iOS 15+、真实 iPhone 测试、
Apple 开发者账号、独立 Bundle ID、描述文件及签名仍需单独准备和验证。
Windows 上的测试不能证明 iOS 可用。

普通 iOS 构建没有 APNs/NSE 或共享预览 Keychain。选择 cloud flavor 前，复制公开模板
`ios/Cloud.example.xcconfig` 为忽略提交的 `ios/Cloud.local.xcconfig`，配置自己的 Bundle ID、
App Group、预览 Keychain 组和 Team，再使用 `flutter build ios --release --flavor cloud --no-codesign`。
该命令仍不签名；共享 Keychain、APNs 和扩展生命周期必须在最终签名产物上另行验收。
本地结构检查与 macOS Swift/C ABI 测试入口见[云通知说明](docs/cloud-notifications.md)。

### 项目结构

| 路径 | 职责 |
| --- | --- |
| `lib/app.dart`、`lib/ui/` | 原生界面组件与安全的聊天内容展示 |
| `lib/viewmodels/` | 选择状态版本、生命周期、草稿和待核对状态 |
| `lib/data/` | 仓储接口边界与操作系统安全存储 |
| `rust/src/adapters/` | Codex、Claude 和 DeepSeek 协议归一化 |
| `rust/src/transport.rs`、`rust/src/security.rs` | 认证、严格 URL 校验、TLS 和禁止自动重发 |
| `rust/src/persistence.rs` | 按账号隔离的本地状态与持久化写入意图 |
| `lib/src/rust/`、`rust/src/frb_generated.rs` | 自动生成的 FFI，需同步重新生成 |
| `rust_builder/cargokit/` | 随仓库维护的第三方原生构建集成，保留原始许可证 |

修改公开 Rust API 后，请运行 `flutter_rust_bridge_codegen generate` 同步生成绑定。
允许使用的协议和权限规则见 [docs/protocol.md](docs/protocol.md)。
CI 会检查版本固定情况、运行原生测试、构建 Android 产物，并定义独立的 macOS/iOS 未签名构建检查；
尚未执行的工作流不代表检查已通过。

### 许可证与隐私

项目使用根目录中的 MIT 许可证。原创桥形标志维护在 `assets/branding/bridge-mark.svg`，
`scripts/generate_icons.py` 使用 Pillow 重新生成各平台的 PNG/ICO 图标。
IBM Plex 字体许可证已保留，可在应用的开源许可页面查看。
请勿复用参考应用的签名身份或应用商店条目。

测试或分发前，请阅读[隐私与权限清单](docs/privacy.md)。该文件是开发者清单，
不是已定稿的法律文件或应用商店隐私政策。

---

## English

A native Flutter + Rust client for your own
[codex-mobile-bridge](https://github.com/try2love/codex-mobile-bridge) gateway.
Compatibility baseline: gateway v2.1.6, commit `b6dde4da8ad4f083c66ab9f1f3770758d623af76`.
Ordinary direct connections need no changes to that baseline gateway. Cloud relay
requires a protocol-capable desktop gateway and a separate cloud service. This app
is not an arbitrary RPC or desktop IPC proxy.

### What Is Included

- Multiple computers, password login, and single-use QR pairing.
- Codex, Claude Code/Cowork, and DeepSeek session lists, search, and paged history.
- Capability-gated creation, continuation, messages, attachments, approvals,
  interruption, and model/effort selection.
- Codex SSE/long polling and desktop-provider detail polling through Rust.
- Local drafts, an in-app inbox, English/Chinese, light/dark themes, and
  phone/tablet layouts.
- Automatic Android background notifications for task completion and confirmation
  requests, with a test action and authenticated conversation navigation.
- OS secure credential storage; SQLite for configuration, drafts, and uncertain
  operations, not complete conversation archives.

Ordinary connections access the selected gateway directly. An explicitly configured
hosted/selfhost account can also use the end-to-end encrypted relay; pairing still
requires approval on the original local desktop. No model API-key storage or remote
HTML execution is implemented.
Cloud account/pairing/settings UI, production Android U-Push integration, and an
iOS APNs cloud flavor now exist in source. Signing, actual vendor delivery, and
background device acceptance remain unverified; see [cloud notifications](docs/cloud-notifications.md).
Android release/profile remain vendor-SDK-free by default; production push requires
both a build-time opt-in and separate native device consent. The debug
[Lenovo-only U-Push trial](docs/umeng-push-test.md) remains a manual experiment and
cannot authorize production cloud push.
The QR scanner uses its bundled Android recognition model; Google Play Services
does not need to be installed on the user's device. FCM/separate OEM channels,
terminal/Git/file workbenches, coding-client account switching, and client lifecycle
management are deferred.

**Chat and control writes are never automatically replayed.** A timeout or ambiguous
reply leaves the operation pending review, even after restarting. Inspect the actual remote
conversation before explicitly clearing a pending operation.

#### Choose and Preview Images

Tap **+ > Photos** beside the composer to open the system image selector.
Clients that support arbitrary attachments also offer a separate **Files** entry.
Selected images appear above the composer: tap to enlarge/pinch-zoom, or use the
corner close button to remove one from the draft. The strip scrolls horizontally,
with a maximum of eight attachments and 20 MiB per file.

Selection uploads the attachment to the current gateway; only **Send** submits
the message. Returning from the system picker waits for fresh authority in the
original conversation/account instead of silently dropping the selection. A
connection wait timeout asks the user to reconnect and choose again. Acknowledged
uploads survive backgrounding in their original draft; uncertain writes are never
replayed. Preview supports PNG, JPEG, GIF and WebP without all-files permission.

#### Return Home

Tap the top-left bridge icon to return to the Computers screen from a conversation,
conversation list, or sign-in screen. The header shows the icon without a brand
title. Returning home saves the current draft and stops live reads without removing
saved connections, credentials, or pending-operation records. If the draft cannot
be saved, the editor stays open. The home button is disabled during a pending write.
Automatic Android notification monitoring continues on the home screen.

#### Remove A Saved Connection

On the Computers screen, swipe a gateway card **from right to left**. Confirm
the gateway name and address in the removal dialog, or cancel to restore the
card. A normal tap still connects; swiping right does not delete anything.
Removal clears that connection's saved credentials, drafts and pending records
on the phone, not the gateway or conversations on the computer. Sign-in is not
required to remove a saved connection.

#### Android Background Notifications

Task notifications start automatically with the app. There is no in-app toggle
or **Stop listening** action, and the old saved off setting is ignored on upgrade.
Android 13+ requests the OS notification permission on first startup, then starts
listening after a grant. Denial does not cause repeated prompts on every launch.
Grant it later through **Settings > Android notifications > Notification permissions**;
returning to the app restores listening automatically. **Send test notification**
checks the local notification channel only, not gateway event delivery. Keep both
task-activity and background-connection notification channels enabled.

- A foreground service reads `/api/mobile/events` directly from saved gateways.
  No gateway modification, Google services, or third-party push account is needed.
  Gateways must be reachable, authenticated, and advertise notifications.
- Another read starts about 12 seconds after each round finishes. Timeouts extend
  the interval. Returning home, backgrounding, or removing the recent-task card
  does not deliberately stop the listener; Android may still reclaim its process.
- Initial connections and account/stream changes establish a quiet baseline.
  Permission restoration preserves deduplication. Catch-up is limited to ten recent alerts per gateway per round, with
  at most twenty local notification routes. Older activity remains in the inbox.
- Notifications contain generic event labels and a computer name, not conversation
  bodies. The public lock-screen version omits the name. Taps recheck identity and
  the event before opening its original provider/environment; they never submit
  messages, approve requests, or activate a client automatically.
- Continuous networking and a timeout-bounded CPU wake lease consume extra battery.
  Battery settings are opened only on request; exemptions are not changed silently.
  Doze, OEM battery policies, disconnection, force-stop, and process reclamation can
  interrupt or delay delivery. This is not guaranteed kill-resistant cloud push.
- There is no boot receiver. Reopening the app automatically restores listening
  when Android permissions allow it. OS notification and battery controls still apply.
  Removing a gateway also clears its local notifications and deduplication state.

### Development

The exact baseline is in `toolchains.json`: Flutter **3.47.8**, its bundled Dart
**3.13.7**, Rust/Cargo **1.99.1**, and flutter_rust_bridge **2.13.0** on both sides.
Use the checked-in `pubspec.lock`, `rust/Cargo.lock`, `.fvmrc`, and
`rust-toolchain.toml`. Do not run a floating upgrade as part of a build.

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter --no-version-check --suppress-analytics pub get --enforce-lockfile
python scripts/check_toolchains.py
```

Python 3.11+ is required by the build helpers. Windows also needs Visual Studio
with the C++ desktop toolchain for host-side Rust tests. Put Flutter, Rust, and
Python on PATH; the Android helper supplies the isolated Java/SDK environment.
Run Flutter tests, analysis, and builds sequentially in a checkout: they share
generated plugin registration files. Concurrent debug/test and release commands
can insert the test-only integration plugin into a release build.
The build helpers deliberately do not pass `--no-pub` to platform builds: on
this pinned Flutter version that flag also skips mode-specific plugin
regeneration, leaving the debug integration plugin in a subsequent release.

#### Windows Android Build

```sh
python scripts/bootstrap_android.py --accept-licenses
python scripts/build_android.py
```

Bootstrap downloads SHA-256-checked JDK/command-line-tool archives into `.local/`
and verifies the installed SDK, NDK, and CMake files. It does not replace another
project's SDK or change global Flutter configuration. Download progress logs are
under `.tmp/`. An optional unauthenticated local HTTP proxy can be provided with
`HTTP_PROXY` and `HTTPS_PROXY`; no machine-specific proxy is committed.

The build helper creates **unsigned** release outputs by default:

- `build/app/outputs/flutter-apk/app-release.apk`
- `build/app/outputs/bundle/release/app-release.aab`
- `build/reports/android/`: SHA-256, all packaged ELF LOAD alignments, APK ZIP
  alignment, and the AAB's bundletool `PAGE_ALIGNMENT_16K` result.

The 16 KB ELF gate covers both 64-bit ABIs and every Rust-core variant. Legacy
32-bit scanner dependencies are explicitly recorded as 4 KB-only components for
older 32-bit devices; they are not claimed to have 16 KB LOAD alignment.

The [2026-10-28 verification record](docs/verification-2026-10-28.md) lists the
tested artifacts and remaining release gates. The locally produced
`build/app/outputs/flutter-apk/app-local-test.apk` is an installable release-mode
copy signed **only with the Android debug identity** for testing; it is not a
production-signed deliverable. The build helper does not create that test copy
or silently substitute it for an unsigned release.

For an installable development build:

```sh
python scripts/build_android.py --format apk --debug --abi arm64-v8a
```

Production cloud push is a separate release/profile opt-in: `BRIDGE_ANDROID_PUSH=umeng`,
with `UMENG_PRODUCTION_APP_KEY` and `UMENG_PRODUCTION_MESSAGE_SECRET` injected by a
secure build environment, plus optional `UMENG_PRODUCTION_CHANNEL`. Debug trial
credentials/consent do not carry over. The client Message Secret is not the server's
`UMENG_APP_MASTER_SECRET`. Vendor packaging must independently pass ABI/16 KB,
signing, privacy, and device gates; old SDK-free artifact results do not cover it.

Release signing is opt-in through `BRIDGE_KEYSTORE_PATH`,
`BRIDGE_KEYSTORE_PASSWORD`, `BRIDGE_KEY_ALIAS`, and `BRIDGE_KEY_PASSWORD`.
All four must be provided together. Never commit signing files or secrets.
Release builds do not silently fall back to a debug key. See
[release gates](docs/release-checklist.md) and [distribution](docs/distribution.md).

#### Tests

```sh
python -m unittest discover -s scripts/tests -v
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo clippy --manifest-path rust/Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
flutter --no-version-check --suppress-analytics analyze
flutter --no-version-check --suppress-analytics test
python scripts/test_native.py
```

Native packaging has an additional toolchain regression test: from
`rust_builder/cargokit/build_tool/`, run `dart pub get`, then
`dart run test/project_toolchain_test.dart`. See that vendored directory's
`LOCAL_PATCHES.md` for the exact-version and locked-build fixes.

The ordinary Flutter suite deliberately skips the host FFI smoke test when no
native library path is supplied. `scripts/test_native.py` builds and loads the
real library, then verifies async FFI, persistence, stream cancellation, and
at-most-once writes. All fixtures use synthetic conversations and credentials.

The on-device test additionally exercises the packaged JNI library and the
platform secure store:

```sh
flutter test integration_test/native_startup_test.dart -d <device-id>
```

For Windows 16 KB emulator tooling, use
`python scripts/bootstrap_android.py --with-emulator`. A static alignment report
does not establish that the APK has actually run on a 16 KB device.
With an already booted, explicitly selected device, run
`python scripts/test_android.py --device <adb-serial>` to verify its 16 KB page
size and save a native integration-test report. Use `--page-size 4096` only when
testing a conventional 4 KB device; it is not a substitute for the 16 KB gate.

#### iOS

On macOS with Xcode and CocoaPods, install the same Flutter/Rust versions, then:

```sh
flutter pub get --enforce-lockfile
rustup target add aarch64-apple-ios
flutter build ios --release --no-codesign
```

This produces an unsigned build, not an App Store IPA. iOS 15+, actual iPhone
testing, an Apple developer account, an independent bundle ID, provisioning,
and signing remain separate requirements. Windows tests cannot verify iOS.

Ordinary iOS has no APNs/NSE or shared preview Keychain. For the cloud flavor, copy
the public `ios/Cloud.example.xcconfig` to the ignored `ios/Cloud.local.xcconfig`,
configure your own bundle IDs, App Group, preview Keychain group, and Team, then run
`flutter build ios --release --flavor cloud --no-codesign`. This remains unsigned;
shared Keychain access, APNs, and extension lifetime need final signed-device
acceptance. Structural and macOS Swift/C ABI checks are documented in
[cloud notifications](docs/cloud-notifications.md).

### Structure

| Path | Responsibility |
| --- | --- |
| `lib/app.dart`, `lib/ui/` | Native widgets and safe conversation presentation |
| `lib/viewmodels/` | Selection generations, lifecycle, drafts, and pending state |
| `lib/data/` | Repository boundary and OS secure storage |
| `rust/src/adapters/` | Codex, Claude, and DeepSeek protocol normalization |
| `rust/src/transport.rs`, `security.rs` | Authentication, strict URLs, TLS, and no automatic replay |
| `rust/src/persistence.rs` | Account-scoped local state and durable write intentions |
| `lib/src/rust/`, `rust/src/frb_generated.rs` | Generated FFI; regenerate together |
| `rust_builder/cargokit/` | Vendored native build integration, with its original license |

Regenerate bindings with `flutter_rust_bridge_codegen generate` after changing
the public Rust API. The allowlisted protocol and authority rules are documented
in [docs/protocol.md](docs/protocol.md). CI checks the pins, runs native tests,
builds Android artifacts, and defines a separate unsigned macOS/iOS build gate;
an unexecuted workflow is not a passed gate.

### Licenses And Privacy

This project uses the root MIT license. The original bridge mark is maintained
as `assets/branding/bridge-mark.svg`; `scripts/generate_icons.py` regenerates its
platform PNG/ICO files with Pillow. IBM Plex font licenses are retained and
available in the app's open-source license screen. Do not reuse the reference
app's signing identity or store listing.

Read the [privacy and permission inventory](docs/privacy.md) before testing or
distribution. It is a developer inventory, not a finalized legal/store policy.
