# Bridge Mobile

[English](README.en.md)

在手机上连接自己的电脑，查看 AI 编程任务、继续聊天、处理审批和接收提醒。
AI 工具仍在电脑上运行，App 不会替代桌面网关。

## 能做什么

- 查看 Codex、Claude Code/Cowork、DeepSeek 的聊天列表和历史记录。
- 发送消息、添加图片或文件、处理审批、停止任务；具体功能由桌面网关决定。
- 保存多台电脑连接和本地草稿，支持中英文、浅色/深色主题。
- 支持直连，以及可选的端到端加密云中转。

## 开始使用

1. 在电脑上安装并启动[桌面网关](https://github.com/mc373906408/codex-mobile-bridge)，确认要使用的 AI 工具已配置好。
2. 在 App 中添加电脑，填写网关地址，再使用网关密码登录或扫描配对二维码。
3. 选择电脑和聊天，即可查看任务或继续对话。

直连不需要部署云服务，但手机必须能访问电脑的网关地址。
需要云中转时，先在桌面端和 App 配置同一个 [Server](https://github.com/mc373906408/codex-mobile-bridge-server) 地址，再由原电脑批准手机配对；仅登录同一账号并不能完成配对。

## 安装与构建

支持 Android 8+ 和 iOS 15+。目前尚无正式 Release 安装包，可自行构建测试版；后续版本见 [Releases](https://github.com/mc373906408/codex-mobile-bridge-app/releases)。

### Windows 构建 Android 测试版

先安装 Flutter stable、Rustup 和 Python 3.11+，并加入 PATH；Windows 还需 Visual Studio 的 C++ 构建工具。
构建脚本会更新 stable SDK 和依赖，建议使用独立的开发环境。

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

许可证：[MIT](LICENSE)。
