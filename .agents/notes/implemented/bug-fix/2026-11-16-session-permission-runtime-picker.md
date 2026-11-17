# Agent Note: 会话权限面板按原生运行时选择读取协议

Status: implemented

## Problem

App 打开权限时一律读取 `GET /api/sessions/:id/permissions`，而网关此读取仅供 Linux 权限检查与原生 CLI 使用。macOS／Windows 普通桌面会返回“此主机未启用 Linux 权限检查”，导致界面无法打开。输入栏也只显示“权限”，没有将 `permissionMode` 转为当前档位；旧选择列表缺少网页的说明与选中状态，且忽略保存结果里的 `confirmed`。

## Decision

`session_permissions.dart` 以当前授权快照开启居中 regular 玻璃弹窗，普通 Codex 桌面直接提供网关支持的 `ask`、`auto-review`、`full-access` 三档，行为与 `web/shell/app.js` 一致。只有 `access.runtime == cli` 或 `linuxPermissionChecks == true` 才读取权限能力接口；这些选项必须明确 `available == true` 才允许选择，不支持的项保留原因。其他 provider 继续读取其原生 `mode/options`，通过 Rust 原有 `/access` 映射写入，不套用 Codex 三档。

打开弹窗冻结完整会话、账号和 runtime，目录读取前刷新并核验身份；切换聊天、账号、连接或 runtime 后禁用旧面板。保存沿用 `SessionBusiness.write` 和 Rust 的即时身份检查、操作记录；Codex 请求携带 `expectedRuntime`，完全访问继续要求用户在产品中确认。点击当前已选项只关闭弹窗。保存开始后禁用重复提交和关闭，返回 `confirmed: false` 或写入异常时保留状态；刷新只重新读取，直到核验所选档位才显示成功，不自动重发权限修改。其他 provider 以返回 mode 或读后快照确认。

输入栏和聊天设置页共用权限名称映射与弹窗。面板展示三档说明、图标和勾选，关闭保留原聊天；中间内容可滚动以适配窄屏和大字号。玻璃材质与透明遮罩沿用[网页布局](../architecture/2026-11-15-web-client-ui.md)，不改变实际权限策略或降低后端检查。

## 记录归属

检索活跃笔记中的权限、运行时、弹窗与业务接入后，[原生网页业务接入](../architecture/2026-11-10-native-web-parity.md)部分重叠，继续持有写前身份和未知写入契约；[已认证聊天能力](2026-11-11-authenticated-chat-capabilities.md)部分重叠，继续以已授权网关的实际能力为准；[网页布局](../architecture/2026-11-15-web-client-ui.md)持有弹窗样式。本篇记录平台读取差异与保存确认，未吸收上述记录；其他命中属于系统通知、云访问或审批请求，不涉及会话权限预设。

## Alternatives considered

- 所有平台都读取权限目录能统一 App 代码，但普通桌面没有此读取协议；不能把读取错误当成能力关闭，也不应为了界面选择去改变网关协议。
- 让 Linux／CLI 直接显示可选三档可以跳过读取，但会掩盖运行时和组织策略限制，因此仍以服务端明确可用选项为准。
- 收到 HTTP 成功便关闭面板更及时，但 `applied` 和 `confirmed` 不等价；保留待确认并只读刷新，避免误报成功或重复修改。

## Testing

`test/session_permissions_test.dart` 覆盖普通桌面不调用 Linux GET、输入栏当前档位更新、CLI／Linux 能力禁用、完全访问取消与确认、runtime 切换时拒绝旧提交、未确认结果只读刷新及其他 provider 的 mode 契约。Skill 与权限专项共 20 项通过，完整 Flutter 回归 528 项通过、4 项条件原生跳过，静态分析无问题；浅深色弹窗截图和中英文窄屏大字号检查通过。

锁定依赖离线核验与 iOS 模拟器 Debug 构建通过。iPhone 18 Pro / iOS 27.2 覆盖安装沿用原签名身份，安装后首次启动前 5 个持久文件哈希不变；Runner、Debug dylib 与 Dart 内核安装哈希匹配构建包，启动成功。真实 macOS 桌面会话中权限面板正常打开，显示三档及“完全访问权限”勾选，关闭后回到原聊天；Skill 弹窗、实际搜索筛选与完成关闭也已检查。保存逻辑使用受控仓库测试，未切换用户真实聊天权限，其他原生 provider 的实际保存仍需对应环境核验。证据保存在忽略目录 `.tmp/skill-dialog-20261116/`。Android SDK、Java 配置和 ADB 不可用，Lenovo 真机未安装。

## Consequences

普通桌面的权限面板可直接打开，CLI／Linux 仍显示实际可用性。新增客户端协议分支需要随网页和网关同步；普通桌面的三档是否能真正应用仍由原生 owner 核验。待确认时用户可以读取最新状态，不能在同一面板重复提交；如果确认持续缺失，需要在桌面检查，而不是从发送成功推断权限已经生效。
