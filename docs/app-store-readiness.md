# App Store 审核准备

本文件是提交材料草稿，尚未执行签名构建或提交审核。功能与实际测试结果以[逐项验收矩阵](web-parity.md)为准。原生界面本身不等于满足审核要求。

## 产品与执行边界说明

Codex Mobile Bridge App 为用户已配对的电脑提供原生会话、项目、文件、Git、终端及任务管理。手机通过已授权网关访问电脑；命令、编码工具和终端进程都在电脑执行。HTML 和 Mermaid 仅用于隔离内容预览，不持有网关凭据或业务桥。

云账号在 App 中仅支持登录、登录态管理及退出。注册与激活码兑换在桌面客户端完成。编码工具的已保存账号管理是电脑上既有工具的管理能力，和云账号注册不同。审核说明须如实包含该功能，不把它隐藏成只读登录页。

直连、P2P 和加密云中转是通往已配对电脑的不同网络路径。最终提交说明须与发行配置一致，说明中转服务的用途、认证配对方式和失去连接后的错误表现；不把尚未上线的云服务描述成可用。

## 原生功能演示脚本

在专用可丢弃测试项目中录制，避免使用个人聊天、生产仓库和真实密钥。录像需要使用最终签名版本；桌面 HTTP 合成夹具不能代替审核演示。

1. 打开“电脑”，展示配对电脑、可用实例和连接状态，再进入聊天列表。
2. 展示来源筛选、项目分组和归档列表，打开一条带历史的测试会话。
3. 展示 Markdown、代码复制、公式、文件变更卡和消息引用；发送预设无副作用请求。
4. 展示模型/思考强度、可选审批决定和一个测试问题；执行仅写入测试目录的获准任务。
5. 打开文件工作台，预览源码、图片、PDF、HTML/Mermaid；完成一次文件保存和分享。
6. 在测试仓库演示 Git 状态、暂存、提交及历史；在电脑端执行 `echo` 等测试终端命令，并展示尺寸变化和停止。
7. 展示原生显示设置、返回/键盘行为和宽屏并排。演示断线提示与恢复；需发送的通知只发给专用测试设备。

保存视频、设备型号、系统版本、构建号、包哈希和测试日期，关联矩阵中的实际结果。材料应涵盖主功能，不能只展示登录。

## 审核环境交接表

以下信息由实际部署和签名环境产生。不得将密码、恢复码或生产凭据写入仓库。

| 项目 | 提交前需具备的事实 | 当前状态 |
| --- | --- | --- |
| iOS 发行包 | 普通/cloud 配置构建、签名、真机启动及数据升级证据 | 当前 Windows 环境无法完成，未收到 Mac/签名设备接入 |
| 测试账号 | 专用已开通测试账号，完整可执行登录流程，审核期间持续有效 | 未配置；通过 App Store Connect 的审核信息安全提供 |
| 测试电脑 | 常在线、独立测试用户、预装获许可工具、合成项目与可丢弃 Git 仓库 | 未配置 |
| 网络与配对 | 从审核设备可访问的网关/中转，完整配对步骤和失效恢复说明 | 云服务尚未上线；不可填写虚构地址 |
| 数据与权限 | 仅测试数据，文件边界和终端范围明确，保留全部正常审批 | 待部署后验收 |
| 联系与支持 | 可用支持网址、隐私政策、审核期间联系人和故障处理方式 | 提交前核对正式地址与人员 |
| 演示视频 | 使用最终发行构建执行上方流程，展示电脑端执行位置 | 未录制 |
| 隐私材料 | 按实际启用推送 SDK、服务器数据处理及系统权限核对声明 | 参照 `privacy.md`，发行配置确定后复核 |

审核凭据放入 App Store Connect 的 Review Notes/账号字段；不依赖审核者使用开发者私人电脑或私人账户。若最终产品需要特殊配对步骤，提供逐步说明和持续可用的测试电脑。演示模式不能擅自替代可用环境。

## 审核规则复核记录

2026-11-10 从 Apple 官方[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)读取规则。提交前应再次核对当时条文与最终产品形态；下述是需要审核确认的适用性问题，不是通过承诺。

- **2.1**：提交的功能和后台须完整可用，登录产品需要审核可用的演示账号或经批准的替代方式。
- **4.2**：说明原生功能和实用价值，不能仅以使用 Flutter 排除最低功能要求。
- **4.2.7**：特定软件的远程镜像有自有主机、局域网和主机侧执行/账号管理等限制。当前原生 API 客户端和云中转形态不能直接宣称符合此条；需如实呈现架构，由最终审核判断适用分类。
- **3.1.1 / 3.1.3**：核对付费数字服务和跨平台权益规则。把注册与兑换放到桌面不自动获得 IAP 豁免；3.1.3(f) 的免费伴随应用例外有具体范围，不能泛化到所有开发工具。审核包不加入未确认的购买引导。

因此目前仍不能标记“可提交/审核通过”。发布条件包括可用审核环境、iOS 签名真机验证，以及最终商业模式和远程访问形态的规则核对。

## Review Notes 内容草稿

发布时填入实际账号、连接步骤、设备要求和视频链接后再使用以下描述，不将占位内容提交：

> This app provides native project, conversation, file, Git, and terminal interfaces for a computer paired and authorized by the user. Coding tools and commands execute on that computer. The app's HTML and Mermaid views are isolated, read-only content previews. Cloud accounts support sign-in and session management in the app; registration and activation-code redemption take place in the desktop client. Saved coding-tool accounts on the paired computer can be viewed and switched subject to gateway capabilities and confirmations. Please use the dedicated review account and test computer supplied in App Review Information. The network paths and any paid service entitlements are described in the accompanying final configuration notes.

这段说明必须随最终功能和发行配置修订，不宣称 Apple 已认定产品类别或接受付费方式。
