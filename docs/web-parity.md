# 桌面 Web 与原生 App 功能验收

基线：桌面 `6057778a`。全部功能以网关实际能力为准，云注册/兑换留在桌面；本文件记录实际交付证据，不把接口接入等同于页面完成。

| 模块 | Web/HTTP 来源 | App 交付与验证 |
| --- | --- | --- |
| 客户端与独立实例 | clients、codex/entries、family + entry | 原生入口、完整身份与管理接口已实现；实际四客户端组合待验 |
| 会话与项目 | sessions、projects、organization、delete | 列表、创建、管理与账号隔离状态已实现；真实客户端管理待验 |
| 输入与任务 | send、queue、catalog、settings、goal、compact | 结构化发送、引用、设置与控制已实现；实时任务组合待验 |
| 审批与问答 | respond、权限、async questions、skip | 可选决定完整回传、计划确认和跳过已实现；真实请求种类待验 |
| 完整消息与引用 | timeline/detail、message-action、审查和文件链接 | 分页详情、原生卡片、代码/公式、引用和阅读位置已实现 |
| 文件工作台 | workspace、preview、download、upload | 文件与预览入口、分段续传、ZIP、平台保存已实现；设备恢复/预览待验 |
| Git | workspace/git-* | 原生面板与真实临时仓库 HTTP＋FFI 契约通过 |
| 终端及派生任务 | terminal、side-chat、subagents | 原生终端与任务入口已实现；真实 PTY、IME 与后台恢复待验 |
| 账号、通知与设置 | accounts、notifications、cli-access、network-adaptation | 普通/WSL 账号、通知模板、显示和传输设置已实现；真实切换/送达待验 |

目标验收维度：默认/独立实例、APP/CLI/WSL/SSH、直连/P2P/加密中转；未知写入和过期身份；v3→v5 数据升级；大文件 Range/ETag；预览隔离；前后台/返回/键盘/中英文/大字体；Android 覆盖安装和 iOS 编译/签名真机分别记录。下列“待验”仍是未关闭项，不表示功能已完成全矩阵验收。

## 逐项矩阵（2026-11-10）

云服务尚未正式上线，用户允许破坏性接口调整；不为旧云协议增加兼容分支。手机草稿、连接和未知操作仍按已批准计划保留。账号管理复用现有账号 ID、客户端实例和网关状态版本，不另建配置文件指纹机制。

Web 入口路径以桌面 `web/features/` 为根，`shell/app.js` 以 `web/` 为根。下表“已接”只说明存在实现，仍需适用客户端、环境、传输和平台的验收。会话接口按 provider 加 `/api/sessions/{id}/` 或 `/api/desktop-sessions/{family}/` 前缀。电脑管理的实际原生入口是连接电脑后“设置 → 电脑功能与设置”，其中包含客户端、账号、WSL、CLI、通知和网络设置。

| ID | 功能 | Web 入口 / 接口 | 能力与确认 | App 入口 | 证据与缺口 |
| --- | --- | --- | --- | --- | --- |
| I01 | 四工具与默认实例 | clients/client-navigation.js; /api/clients | family/启用状态 | 电脑→实例 | 已接；真实四工具待验 |
| I02 | 独立实例与完整身份 | clients/client-lifecycle.js; entry | 实例存在且 family 一致 | 会话列表 | Rust 隔离测试通过；真实实例待验 |
| I03 | APP/CLI/WSL/SSH | clients/desktop-sessions.js; sessions/list | 原环境可读；禁止回落 local | 列表→来源 | 环境隔离单测通过；WSL 属于 family 的环境，管理页单列开关；实际环境组合待验 |
| I04 | 启用/停用 | clients/client-lifecycle.js; POST clients | enabled/手动绑定限制 | 客户端菜单 | 已接；待验 |
| I05 | 初始化/重连/重试 | clients/client-lifecycle.js; clients/reconnect | canInitialize/canReconnect/retryable | 客户端菜单 | 已接；实际客户端待验 |
| I06 | 退出/强制关闭 | clients/client-lifecycle.js; clients | canQuitDesktop/canForceQuit；二次确认 | 客户端菜单 | 字段已补；实际退出待验 |
| I07 | 连接模式 | clients/client-lifecycle.js; connectionModes | available/configured | 客户端菜单 | 按网关清单选择；待验 |
| I08 | CLI 释放 | accounts/cli-access.js; cli-connections | 授权范围与回执 | 电脑设置→CLI | 已接每 2 秒被动轮询、前后台暂停及迟到响应丢弃；实际释放待验 |
| I09 | 增量存储迁移 | chat/composer-drafts.js; drafts.options | 默认旧作用域不变 | Rust Store v3→v5 | 事务与隔离测试通过；Lenovo 真实 v3→v5 保留 1 电脑/6 草稿/1 操作记录 |
| I10 | 全链路通用 HTTP 转发 | relay/protocol.py; Noise/P2P/旧共享中继/云网页 | 删除接口与方法清单；保留鉴权、CSRF、配对及业务边界 | Rust transport/relay | 真实 HTTP/WebSocket 回归通过；桌面、Lenovo 与远端均已更新，手机重新读取真实列表通过；完整传输与 iOS 矩阵待验 |
| I11 | 账号变化/迟到响应 | accounts/accounts.js; accounts/current | 账号 ID＋实例＋已有状态版本 | GatewayBusiness | 真实 HTTP＋FFI 拒绝旧写入/迟到读取通过 |
| S01 | 搜索/分页 | chat/list-sync.js; sessions/list | 当前 provider/entry | 聊天列表 | 已接；真实分页待验 |
| S02 | 来源筛选 | clients/desktop-sessions.js; sessions | availableSources | 聊天列表 | 动态来源贯通 Rust→实际生成 FFI→Dart；Flutter 回归通过 |
| S03 | 项目分组/归档列表 | chat/session-menu.js; sessions | 原生项目、归档支持 | 聊天列表 | 已接；页面待验 |
| S04 | 置顶 | chat/session-menu.js; pin | 客户端支持且状态新鲜 | 聊天菜单 | 已接；操作前刷新当前状态，真实客户端待验 |
| S05 | 已读/未读 | chat/list-sync.js; 本地状态 | 新活动失效、账号隔离 | 聊天菜单 | 账号＋活动版本标记、最多四个并发被动核验、迟到保护测试通过 |
| S06 | 改名 | chat/session-menu.js; rename | 客户端实际能力 | 聊天菜单 | 已接；端到端待验 |
| S07 | 归档/恢复 | chat/session-menu.js; archive | 停止任务及子任务确认 | 聊天菜单 | 已接当前状态刷新与确认；真实客户端待验 |
| S08 | 删除范围确认 | chat/session-menu.js; GET/POST delete | scope/version/retry | 聊天菜单 | 已接；并发范围变化待验 |
| S09 | 聊天分支 | chat/message-actions.js; fork/message-action | forkable/原生 ID | 消息菜单 | 已接；端到端待验 |
| S10 | 原生项目/分区归属 | chat/session-menu.js; organization | available/expectedId | 聊天菜单 | 选择与网关允许的 bridge-owned 创建已接；原生只读项目不开放伪创建 |
| S11 | 目录浏览/登记/创建目录 | shell/app.js; projects/browse/register | 环境、路径、信任边界 | 新建聊天 | 真实 HTTP＋FFI 登记通过；各环境待验 |
| S12 | 创建聊天/无项目 | shell/app.js; projects/create | createRequiresMessage/环境 | 新建聊天 | 结构化目录、无项目选项已接；真实创建待验 |
| S13 | 创建模型/思考强度 | clients/desktop-sessions.js; create-models | 目录版本与 manual 能力 | 新建聊天 | 已接；真实模型目录待验 |
| S14 | 项目授权 | shell/app.js; projects/trust | 支持 trust 且明确确认 | 创建前面板 | 已接；待验 |
| C01 | 普通发送/运行中补充 | chat/modes.js; send | canSend/steer/controlToken | 输入区 | 既有 Rust 协议测试通过；新字段待验 |
| C02 | 排队/撤回 | chat/message-management.js; queue | queue/version | 任务设置 | 已接；并发变化待验 |
| C03 | 模型/思考强度/手动模型 | clients/desktop-sessions.js; catalog/settings | 会话和目录共同授权 | 模型设置 | 目标会话已绑定；DeepSeek manual 限制待核对 |
| C04 | Fast | chat/fast-mode.js; settings | provider/model/fastTier | 模型设置 | 已接；实际目录待验 |
| C05 | 权限与提升确认 | chat/permissions.js; permissions/access | 返回可选 preset | 任务设置 | 已接；所有确认路径待验 |
| C06 | Skill/Plugin | chat/attachments.js; catalog/send | 当前客户端及模式支持 | 任务设置 | 已接；各客户端协议待核对 |
| C07 | 文件引用/附件 | chat/attachments.js; workspace/info/uploads | 路径/账号/总数限制 | 输入区/文件菜单 | 已接；跨实例与限额待验 |
| C08 | 消息引用/移除 | chat/composer-quotes.js; 草稿 | 完整正文与消息来源 | 消息菜单/选文页 | 结构化可移除引用、选文引用、持久化及去重测试通过 |
| C09 | Plan/Goal/预算控制 | chat/modes.js; goal/* | 模式和附件限制 | 任务设置 | 已接；预算/暂停/恢复待验 |
| C10 | 上下文用量/压缩 | chat/activity.js; compact | 压缩能力和状态 | 任务设置 | 原生用量展示和压缩已接；真实运行状态待验 |
| C11 | 草稿持久化 | chat/composer-drafts.js; drafts.options | Skill/引用/模式完整隔离 | Rust Store | 迁移测试及同签名覆盖安装通过，6 条既有草稿旧字段逐项相同 |
| C12 | 未知写入/手动核对 | chat/message-actions.js; 操作记录 | 不得自动重放 | 聊天/管理核对入口 | 操作与授权身份事务保存、不重放及跨云账号拒绝单测通过；管理核对入口已接 |
| A01 | 命令/文件审批 | shell/app.js; respond | availableDecisions 全部保留 | 审批页面 | Widget 验证可选决定、数值请求 ID 与请求版本原样回传；实际请求组合待验 |
| A02 | 权限审批 | shell/app.js; respond | 精确权限和 scope | 审批页面 | 已接；各客户端形状待核对 |
| A03 | Computer Use/MCP | clients/desktop-sessions.js; respond | 请求类型、schema、能力 | 审批页面 | 已接；完整请求覆盖待验 |
| A04 | 同步/异步问题/跳过 | shell/app.js; respond | 完整问题、可选回答与 skip | 审批页面 | 已接；跳过必须收到 skipped 回执，多问题/过期真实请求待验 |
| A05 | 执行计划/反馈 | chat/modes.js; respond | 反馈非空不直接执行 | 审批页面 | 按钮互斥已修；真实 Plan 待验 |
| A06 | 过期审批/长文本 | chat/timeline.js; request state | 请求 ID 与版本一致 | Rust/审批页面 | 40,000 字符保留单测通过；端到端待验 |
| M01 | 完整历史/正文/复制 | chat/timeline.js; timeline/detail | epoch/version/分页 | 聊天/全文页 | 真实 HTTP＋FFI 详情分页通过；完整复制经过版本核验 |
| M02 | 代码高亮/代码复制 | chat/timeline.js; 本地渲染 | 完整代码块 | RichMessageText | 渲染/复制测试与浅深色截图通过；移除重复复制按钮 |
| M03 | 数学公式 | chat/timeline.js; 本地渲染 | 解析失败回退 | RichMessageText | 已接；字体/布局待验 |
| M04 | Mermaid | chat/timeline.js; 随包资源 | 无外网/业务权限 | 隔离预览 | 已接；隔离样本/设备待验 |
| M05 | 工具截图/图片附件 | chat/attachments.js; 授权图片接口 | 正确账号/实例/ID | 消息附件 | 已接；各来源待验 |
| M06 | 文件变更卡/差异 | chat/timeline.js; fileSummary/workspace | 摘要不得请求不存在的详情 | 消息区 | 原生 fileSummary 卡、文件引用与差异入口已接，内容测试通过 |
| M07 | 审查卡/后续操作 | clients/desktop-sessions.js; review/follow-up | 返回动作与限制 | 消息区 | 指令解析与原生审查/后续动作卡已接，内容测试通过 |
| M08 | 编辑/编辑分支 | chat/message-actions.js; message-action | latestUserTurnId/version | 消息菜单 | edit-fork 已修；失败草稿待验 |
| M09 | 阅读位置 | chat/activity.js; 本地状态 | 完整身份/流更新 | 聊天区域 | 按账号＋会话保存位置、切换恢复与流更新保持已接；真实设备长列表待验 |
| F01 | 目录/搜索/隐藏/分页 | workspace/workbench.js; workspace | 工作目录边界 | 工作台→文件 | HTTP＋FFI 目录通过；Lenovo 真实网关读取 D:\github 目录通过，其他交互待验 |
| F02 | 上传/进度 | workspace/file-actions.js; workspace/upload | 20 MiB/路径/账号 | 文件→上传 | 上传进度与下载暂停状态已分离；真实设备大文件待验 |
| F03 | 下载/续传/ETag | workspace/downloads.js; download | Range/If-Range/强 ETag | 文件→下载 | 真实 HTTP＋FFI 分段与变化拒绝通过 |
| F04 | 目录 ZIP | workspace/downloads.js; download?archive=1 | 目录边界与压缩限制 | 目录→下载 | 真实 HTTP＋FFI ZIP 头通过；内容/设备待验 |
| F05 | 系统保存/分享 | workspace/downloads.js; 系统 API | 平台权限 | 文件菜单 | Android SAF/iOS UIDocumentPicker 独立保存及分享已接；限定 ready 目录普通文件；设备待验 |
| F06 | 源码/Markdown/行引用 | workspace/source-view.js; preview | 类型/行号/完整文本 | 文件预览 | 初始行定位与引用已接，源码行回归通过；实际大文件待验 |
| F07 | 图片/PDF/全屏 | workspace/pdf-preview.js; 授权内容 | 预览边界 | 文件预览 | 已接；两平台待验 |
| F08 | HTML 隔离 | workspace/html-preview.js; srcdoc | 禁脚本/导航/外网/设备权限 | 隔离 WebView | CSP、sandbox、恶意字符串/权限边界测试通过；系统 WebView 动态攻击样本待验 |
| F09 | 路径复制/根引用 | workspace/file-actions.js; info | 授权路径 | 文件菜单 | 路径复制和引用到草稿已接；设备交互待验 |
| G01 | Git 状态/两区差异 | workspace/git-panel.js; git-status/git-diff | 仓库和版本 | 工作台→Git | 真实临时 Git 仓库 HTTP＋FFI 状态与两区差异通过 |
| G02 | 暂存/取消暂存/提交 | workspace/git-panel.js; git-action | version 和确认 | Git 面板 | 真实 Git 暂存/取消/提交、旧版本拒绝通过；设备确认待验 |
| G03 | 历史/历史差异 | workspace/git-panel.js; git-history/git-commit | revision/path | Git→历史 | 真实 Git 历史与历史差异 HTTP＋FFI 通过 |
| G04 | 建分支/切换/合并/中止 | workspace/git-panel.js; git-action | 冲突、版本与确认 | Git→分支 | 真实 Git 建分支/切换/冲突/中止 HTTP＋FFI 通过；网络未知结果待验 |
| T01 | 一次性命令 | workspace/command-terminal-panel.js; terminal | 在电脑执行、明确确认 | 终端面板 | 已接；真实命令待验 |
| T02 | PTY/中文/Ctrl+C | workspace/terminal-panel.js; terminal?mode=pty | 回执/id/inputId | 原生 xterm | HTTP＋FFI 负载通过；实际 PTY/IME 待验 |
| T03 | 补全/尺寸 | workspace/terminal-panel.js; complete/resize | 替换范围和 cols/rows | 终端面板 | HTTP＋FFI 负载通过；实际 shell 待验 |
| T04 | 停止/关闭/重进 | workspace/terminal-panel.js; stop/close | 句柄持久化、不重放 | 终端面板 | 已接；断线/前后台待验 |
| T05 | 侧边聊天/控制 | workspace/side-chat.js; side-chat?view=native | Codex 与网关能力 | 派生任务 | HTTP＋FFI list/create 通过；控制待验 |
| T06 | 子智能体记录 | workspace/agents-panel.js; subagents | 保存记录和完整性标记 | 派生任务→记录 | turns.messages 与树结构已接；真实多层子任务待验 |
| T07 | 后台任务/停止 | clients/desktop-sessions.js; tasks/stop-task | cancellable | 派生任务 | 已接；真实任务待验 |
| T08 | 宽屏并排/标签保持 | workspace/floating-panel.js; 本地 UI | 屏幕宽度/完整身份 | 聊天/工作台 | ≥1000px 并排、账号会话作用域页签保持已接；实际平板待验 |
| P01 | 云登录/登录态 | 云账号 API | App 无注册/兑换 | 电脑/设置 | 保留既有功能；全量回归待验 |
| P02 | 已保存账号/额度/模型 | accounts/accounts.js; accounts/details | canReadQuota/section/readOnly | 设置→电脑功能→客户端→账号 | 桌面更新后 Lenovo 账号页读取成功，实际返回 0 个 Codex 已保存账号；额度与切换尚无真实证据 |
| P03 | 切换账号/CLI 同步 | accounts/client-accounts.js; accounts/switch | 任务确认/requestId/canSyncLocalCli | 账号卡片 | 字段已补；实际切换待验 |
| P04 | WSL 账号 | accounts/wsl-accounts.js; wsl-accounts | 原环境管理及返回能力 | 账号管理→WSL | 原生 WSL 账号/模型/允许的 API 编辑已接；HTTP＋FFI 模型/账号契约通过 |
| P05 | 提醒/重置动态/桌面更新 | accounts/accounts.js; reminders/reset-dynamic/desktop-update | canManageDesktop/更新能力 | 账号设置 | 提醒、重置动态与桌面更新入口已接；实际客户端待验 |
| P06 | 全局/单会话通知 | shell/app.js; notifications/defaults | 布尔默认与 inherit/on/off | 设置/任务设置 | 已接；继承行为待验 |
| P07 | Bark/ntfy/PushPlus | shell/app.js; notifications/channels/* | 服务端字段与测试确认 | 通知设置 | 已接；逐字段/实际发送待验 |
| P08 | Webhook | shell/app.js; webhook/endpoints | 端点 ID/方法/模板 | 通知设置 | Web 相同 provider、网关模板、显式 URL 显隐、空密钥保留；HTTP＋FFI upsert 通过，未实际发送 |
| P09 | 显示/字体/传输偏好 | settings/presentation.js; file-transfer | 网关和本地范围 | 设置 | 字体/字号/密度/强调色及内容/入口显隐已接；中英 320px/2x 字体回归通过 |
| P10 | 网络恢复/SSH 诊断 | shell/app.js; network-adaptation/ssh-retry | 指定 host/能力 | 电脑设置 | SSH host 已修；恢复待验 |
| P11 | 通知跳转/前后台 | 通知桥/inbox | 实例/环境/账号 | 系统通知 | 既有单测通过；新实例跳转待验 |
| V01 | Android 普通/cloud 构建 | toolchains.json/交付笔记 | 同签名 Lenovo L71091、不卸载 | APK/设备 | ARM64 debug 构建及覆盖安装成功；普通/可选云推送 Kotlin/Manifest 编译、Android 单测通过；最终错误页修订再次交付见记录 |
| V02 | iOS 普通/cloud/签名 | toolchains.json/iOS 工程 | macOS/Xcode/签名/设备 | iOS App | Windows 本机；无构建和真机证据 |
| V03 | 中英/浅深/大字体/键盘/返回 | Flutter 页面 | 窄屏/平板/系统行为 | 全部新页面 | 全面 UI 回归待验 |
| V04 | 直连/P2P/Noise 中转 | transport/relay | 三传输一致的业务与取消语义 | 所有功能 | 完整矩阵端到端待验 |
| V05 | App Store 准备 | Apple 4.2/4.2.7/付费服务规则 | 最终形态、测试环境、远程执行说明 | [审核准备](app-store-readiness.md) | 演示流程与说明草稿已准备；可访问审核环境、签名构建和最终规则适用性仍待落实 |

## 运行证据

- Rust：`cargo test --manifest-path rust/Cargo.toml --locked`，81 通过、1 跳过；包括通用方法/正文的直连 HTTP 与真实 Noise/WebSocket、v3→v5 升级及跨实例/环境/账号隔离。跳过的是需要专用夹具的真实 P2P 测试。`cargo fmt`、`cargo clippy --locked --all-targets -- -D warnings` 通过。
- 真实 FFI：`scripts/test_native.py` 的既有原生测试 8 项通过，扩展的 `test/native_web_parity_test.dart` 1 项通过。桌面源码从干净 `6057778a` 导出，使用实际 HTTP Handler 和 Rust DLL；编码客户端为合成夹具，不操作安装中的编码工具。覆盖真实临时 Git 仓库、长消息分页、WSL 模型/账号、Webhook upsert、Range/ETag 变化拒绝、目录 ZIP、终端负载/回执、侧边聊天、项目登记、过期写入和迟到读取。
- 本轮通道移除后再次构建实际 Rust DLL，既有 FFI 8 项与桌面 HTTP 契约 1 项全部通过；本次 HTTP 来源为配套桌面工作树，已包含接口清单移除及未读正文错误连接关闭的修复，与前一轮干净基线验证分别计证。
- Flutter：`flutter analyze` 无问题；全量测试 402 通过、4 跳过（原生入口在专用运行中另验）。26 项视觉测试通过，16 张有改动的截图已逐张检查；新增内容/身份/布局/审批专项 12 项通过。
- Python 构建与验收脚本：`python -B -m unittest discover -s scripts/tests -v`，94 项运行、2 项 macOS 专用跳过，其余通过。
- 桌面：全量 `python -B scripts/test-backend.py --source-only` 运行 3531 项，237 项跳过；初跑有 3 个用例的 4 条错误（HTTP 超时和 Windows 子进程编码）。使用 `PYTHONUTF8=1` 定向复跑失败用例及账号/新策略共 49 项，1 项 POSIX 专用跳过，其余通过；另新增现有账号 source 版本变化/不可读回归 1 项通过。没有将初次全量失败表述为全量一次通过。
- 删除接口清单后：桌面通用转发、Noise/P2P 公用处理、云网页、旧共享中继及相关会话测试 147 项通过；HTTP/认证/Harness 补充回归 45 项通过。服务端隔离 PostgreSQL 的 `internal/api`、`internal/webproxy` 测试与 `go vet` 通过。用户授权后远端已部署 `http-forwarding-20261110-d35a7a5`；运行二进制与构建哈希一致，公网 TLS、健康、认证和跨 Origin 拒绝通过，10 张持久表摘要一致。
- Android 构建和设备证据见下方交付记录。iOS 构建、签名真机与三种传输全面回归尚未完成。

## 验证入口与边界

Rust 身份/存储/协议实现位于 `rust/src/engine.rs`、`rust/src/engine/workbench.rs`、`rust/src/adapters/desktop.rs`、`rust/src/persistence.rs` 与 `rust/src/relay.rs`。原生业务页位于 `lib/ui/business/`；平台保存分别在 Android `WorkspaceFileExport.kt` 和 iOS `AppDelegate.swift`。`test/business_content_test.dart` 覆盖结构化内容与布局，`test/native_web_parity_test.dart` 必须配合 `scripts/web_parity_fixture.py` 和真实 DLL 运行。

普通 Flutter 测试的模拟 Repository 只能证明交互和参数，不能作为 HTTP/FFI 或真实客户端通过证据。CI 从 `toolchains.json.gateway_commit` 固定检出桌面源码，缺少夹具直接失败。终端夹具证明协议与回执，不证明真实 PTY、系统键盘或 Ctrl+C 的终端语义；预览字符串测试不证明 Android/iOS WebView 运行时隔离。

## Android 交付记录（2026-11-10）

- 设备重新核对为 Lenovo L71091 / Android 13 / ARM64；通过用户提供的无线 ADB 地址连接，包名 `dev.waken.bridge_mobile`。
- 首轮包 SHA-256：`b4ace98d3af3074f4ff479ffa6f2b45dd91378f47b7d41ddd61ead67dc800779`；签名 SHA-256 与现有包相同：`79cc12dccddc4606767c48dca5668b9a26cfc7b334275ef555a0ab606ac55797`。
- 覆盖安装后、首次启动前比较数据库/WAL/偏好共 28 个文件，全部逐字节相同。首次安装时间仍为 `2026-10-28 10:11:30`，首轮更新时间为 `2026-11-10 16:23:43`。
- 冷启动 `Status: ok`；数据库从 v3 升至 v5，原 1 台电脑、6 条草稿、1 条操作保留。6 条草稿和 1 条操作的旧字段与升级前逐项一致。安全存储键集合、密钥配置和通知同意保留；联网后有 1 项加密偏好值更新，因此不宣称联网后的全部私有文件仍字节相同。
- 原电脑连接可用；实测读取 Codex 真实会话列表、详情、原生菜单和工作台目录。Claude 返回未配置提示；当前网关未提供可用 ZCode 实例。未切换真实编码账号、停止既有任务或发送通知。
- 账号页首次遇到旧网关接口清单的 `access_denied`，由此修复业务错误页的堆栈展示和重试按钮不可见；桌面授权覆盖更新后，已能读取账号页及管理版本，实际返回 0 个 Codex 已保存账号。用户随后要求取消各通道接口清单，配套源码已移除该策略；额度、实际切换和完整传输组合仍待验。
- 错误页修订包 `b9b9c098c5e7d97c5fcb65e7510e6301734a41294a6dccdd0cf8a595bb3fd483` 已同签名覆盖安装；安装包与设备包哈希一致，首次启动前 36 个私有文件逐字节保留，冷启动正常。
- 删除接口/方法清单后的包位于忽略的 `.local/deliveries/http-forwarding-2026-11-10/app-debug-ff14e3212eed.apk`，SHA-256 为 `ff14e3212eed27be0f10f9c757567997aab91f825cdf7234806c8f59dbe22a1d`。12 个 ARM64 ELF 库的打包检查通过；重新核对 Lenovo L71091 和签名后覆盖安装成功。设备 APK 哈希一致，首次启动前 38 个数据库/WAL/偏好文件逐字节保留，首次安装时间未变，冷启动 `Status: ok`。该包是同签名 debug 测试包，不是商店发布产物。
- 配套远端部署后，手机保留既有云登录；刷新找回在线电脑，重新读取真实 Codex 列表、电脑功能页和已保存账号页成功，未再出现接口策略拒绝。该检查没有切换编码账号、改动通知开关或启动/停止任务；各条传输及全部业务组合继续分别待验。
- 原始截图、包、数据库备份和日志保留在忽略的 `.tmp/web-parity-device/` 与 `.local/deliveries/`；凭据和用户数据不得提交仓库。

每个适用项均通过后才可收口。网关不支持的项须记录返回能力与 App 限制表现，不能仅标记不适用。
