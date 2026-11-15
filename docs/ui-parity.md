# 原生布局与客户端网页对照

本轮以用户提供的聊天与模型设置截图为布局参考，保留原生玻璃材质。相邻桌面仓库 `web/` 是布局与交互位置的来源；本机浏览器地址栏、手机状态栏属于宿主，不绘制进 App。本文记录检查范围与证据边界，不将 Flutter 合成夹具称为真实客户端业务验收。

| 页面族 | 网页来源 | 原生入口与处理 | 验证 |
| --- | --- | --- | --- |
| 聊天标题与工作台页签 | `web/shared/presentation.css`、`web/features/workspace/workbench.css` | `chat_page.dart` 使用客户端图标、单行标题、状态与菜单；下方聊天／工作台标签和添加入口；固定区域保留 regular 玻璃 | 浅深色截图、窄屏大字号、导航与草稿回归 |
| 正文与过程记录 | `web/features/chat/timeline.js`、`web/shell/content.css` | `message_card.dart` 使用 CODEX／客户端模型标签、灰色消息操作与时间；思考、命令及文件变更使用轻量折叠，用户消息为浅灰底 | 长聊天滚动截图、消息内容回归；没有时间字段时不伪造时间 |
| 聊天输入 | `web/index.html` 的 `.composer`、`presentation-controls.css` | 模型＋强度、Skill、权限、上下文、收起；输入框默认单行、随内容增高；附件、发送方式、工作模式、停止、发送。极窄屏／大字号将操作分行 | 中英文键盘、大字号、附件预览／删除、发送规则与草稿回归 |
| 模型设置 | `web/shared/presentation-controls.css`、`web/shell/app.js` | regular 玻璃面板跟随 App 主题，弹窗遮罩透明，避免背景变暗透进玻璃；顶部刷新／关闭、更新日期、有界列表、选中勾、强度网格、Fast 与整行应用；目录在打开聊天后预取、五分钟复用并合并在途请求 | 浅深色面板及透明背景截图、横竖屏／键盘／大字号、身份／连接／刷新／失败测试 |
| 会话列表与客户端切换 | `web/shell/chat-list.css`、`web/features/clients/client-navigation.css` | 列表紧凑排版、网页主题、活动点与筛选；保留原生客户端选择及三标签导航，工具组使用 regular 玻璃 | 列表与菜单截图、中英文320／390宽度、大字号与筛选回归 |
| 新建会话 | `web/shared/creation-model-picker.js`、`web/shared/project-picker.js` | 项目／环境表单保留原生适配；模型列表与强度网格共用模型设置组件，增加字段间距 | 中英文窄屏大字号、创建入口与操作回归 |
| 任务设置／权限／队列／Skill | `web/features/chat/permissions.js`、`modes.js`、`composer-commands.js` | 同一玻璃导航与表单主题；输入区直接到达 Skill 和权限；权限确认和未知操作规则不变 | 中英文业务页布局、业务与审批回归 |
| 文件／预览 | `web/features/workspace/workbench.css`、`source-view.js` | 工作台标签、路径／文件搜索、源码／Markdown／图片／PDF预览与下载继续使用原生入口；导航使用玻璃 | 业务页布局、附件、下载、只读预览隔离及已有FFI测试 |
| Git／终端／派生任务 | `web/features/workspace/{git-panel,terminal-panel,agents-panel}.js` | 同一工作台结构与主题；终端工具横向滚动，派生任务使用可换行选项组，避免英文大字号溢出 | 实际点击工作台标签后检查窄屏大字号；测试不启动真实终端、不提交Git或停止任务 |
| 账号／WSL／客户端管理／网关表单 | `web/features/accounts/`、`web/features/clients/` | 共用玻璃导航、主题、表单边框；WSL API编辑字段增加间距。账号作用域、配对与即时写前核验保留 | 中英文列表／账号／WSL／网络／通知表单布局与既有业务测试 |
| 外观／通知／通用弹窗 | `web/features/settings/presentation.js`、`web/features/chat/session-menu.css` | 网页字号、强调色、边框与按钮层级；原生无障碍、选择、确认和系统保存流程保留 | 根设置截图、外观控件、错误页面／确认与通知回归 |
| 电脑／云服务／登录／配对／隐私 | 网页登录及客户端管理的公共视觉 | 手机独有流程沿用电脑和云账号结构；复用主题、字段间距、卡片和玻璃导航；不添加网页中没有的假在线／假权限 | 电脑／直连登录截图，云登录／授权／错误与隐私同意回归 |

桌面模型目录本身已经有缓存。App 先前每次弹窗都经 `SessionBusiness.read` 读取前、后两次完整快照；本轮使用已显示的认证快照并保留读取后的远端身份核对，预取与打开共享读取。在当前连接和同一会话作用域内，缓存有效的重复打开不请求目录或正文；冷启动、显式刷新和上游目录缓存失效仍可能等待电脑或模型服务。

本轮验证不等于所有网页业务都已逐像素复刻：玻璃是用户指定的原生材质，浏览器原生下拉与字体也不等同 Flutter。工作台、账号和审批的真实数据、所有 provider、SSH／WSL 及 iPhone 真机仍需要对应环境验收。手机独有的云登录、配对和通知授权继续保留原生步骤。实现决定和实际构建／设备结果见[布局与玻璃记录](../.agents/notes/implemented/architecture/2026-11-15-web-client-ui.md)。
