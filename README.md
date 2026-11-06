# Bridge Mobile

[English](README.en.md)

在手机上连接自己的电脑，查看 AI 编程任务、继续聊天、处理审批和接收提醒。
AI 工具仍在电脑上运行，App 不会替代桌面网关。

## 能做什么

- 查看 Codex、Claude Code/Cowork、DeepSeek 的聊天列表和历史记录。
- 发送消息、添加图片或文件、处理审批、停止任务；具体功能由桌面网关决定。
- 保存多台电脑连接和本地草稿，支持中英文、浅色/深色主题。
- 支持直连，以及可选的端到端加密云中转。

## 界面与导航

底部使用“电脑 / 聊天 / 设置”三个标签，采用黑白灰与系统蓝、浅深色主题和苹果 Liquid Glass 方向的导航材质。切换标签保留当前电脑、聊天和草稿；再次选择当前已连接电脑直接回到原上下文。连接中可点击取消，其他电脑仍通过原有授权和连接流程进入。

手机聊天详情隐藏底栏，返回后回到聊天列表；宽屏显示列表与详情双栏。用户消息采用气泡，助手长文本、代码、工具活动和审批分别呈现。设置提供外观、语言、通知、云服务、隐私同意和开源许可。放大字体、高对比度、减少动态效果以及 iOS 减少透明度会调整展示。

## 开始使用

1. 在电脑上安装并启动[桌面网关](https://github.com/mc373906408/codex-mobile-bridge)，确认要使用的 AI 工具已配置好。
2. 使用云连接时，点击 App 首页云端卡片进入云服务中心，登录[官方云服务](https://bridge.waken.cloudns.be:8787/)。同账号在线设备会自动出现在首页，无需请求配对或选择配对目标。首次核对两端安全码一致后，在原电脑打开这台手机的“允许连接”开关。
3. 获准后在手机选择电脑和聊天，即可查看任务或继续对话；不会自动进入聊天。首次注册请在桌面端完成，App 暂不提供注册入口。

本地直连无需云账号或部署云服务：点击首页与云端并列的“添加直连”，填写网关地址，使用网关密码登录或配对链接连接。手机必须能访问该网关地址。

首页首屏并列提供云端和直连入口，云端保留主按钮与优先位置。登录后，首页云端按钮显示“进入云端”，云服务中心只管理登录、退出与服务器设置。手机在前台自动同步当前服务器、当前账号的电脑；首页只显示在线云设备，连接权限与在线状态仍独立。离线记录与已验证密钥会保留，上线后卡片自动重新出现；未登录或设备目录无法确认时，首页不显示缓存的云设备。本地直连不受云端在线状态影响。在线但待允许的电脑仍可查看设备信息与安全码。云电脑不提供删除或左滑移除，桌面关闭“允许连接”会保留密钥，之后可直接重新开启；本地直连仍可删除。“设置 → 云服务中心”也可进入同一页面。自部署用户可以切换到自己的 [Server](https://github.com/mc373906408/codex-mobile-bridge-server)，须与桌面端使用同一地址；切换前需明确退出当前账号。登录只发现设备，不自动授予连接权限。自动发现需要匹配版本的服务端、桌面端与 App。

## 安装与构建

支持 Android 8+ 和 iOS 15+。安装包见 [Releases](https://github.com/mc373906408/codex-mobile-bridge-app/releases/latest)：

- **Android**：下载 `bridge-mobile-v0.2.0-android.apk` 后安装，沿用 0.1.0 的独立发布签名。
- **iOS**：下载 `bridge-mobile-v0.2.0-ios-unsigned.ipa`，使用自己的 Apple ID/开发者签名，通过侧载工具签名后安装。IPA 未签名，不能直接点击安装；目前不提供 TestFlight。

中继升级要求、安装方式和校验文件见 [0.2.0 发布说明](docs/releases/v0.2.0.md)。

### Windows 构建 Android 测试版

先安装 Flutter stable、Rustup 和 Python 3.11+，并加入 PATH；Windows 还需 Visual Studio 的 C++ 构建工具。
构建脚本验证现有依赖锁文件并记录工具链快照，不自动升级 SDK 或重新生成 FFI。
需要更新依赖时，先显式运行 `python scripts/prepare_build.py`，审查并验证产生的改动后再构建。

```sh
git clone https://github.com/mc373906408/codex-mobile-bridge-app.git
cd codex-mobile-bridge-app
python scripts/bootstrap_android.py --accept-licenses
python scripts/build_android.py --format apk --debug
```

安装生成的 `build/app/outputs/flutter-apk/app-debug.apk`。
这是调试签名的测试包，不是正式发布包。正式签名和其他构建方式见[分发说明](docs/distribution.md)。

iOS 构建需要 macOS、Xcode 和 CocoaPods，安装到 iPhone 还需配置 Apple 签名。详见[分发说明](docs/distribution.md#ios)。

## 使用提醒

- Android 后台提醒需要系统通知权限，省电设置、断网或强制停止可能导致延迟；不保证每条通知必达。
- 云推送还需服务端配置和用户同意，当前接入状态见[云通知说明](docs/cloud-notifications.md)。
- 发送或审批结果不明确时，App 不会自动重发。请先在电脑端核对，避免重复执行。
- 云账号的服务天数兑换目前在桌面端完成，App 不提供兑换入口。

## 更多说明

- [隐私与权限](docs/privacy.md)
- [云连接与通知](docs/cloud-notifications.md)
- [签名与发布检查](docs/release-checklist.md)
- [App 全局架构与范围省察](.agents/notes/implemented/architecture/2026-11-04-app-architecture-and-scope-audit.md)

许可证：[MIT](LICENSE)。
