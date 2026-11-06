import 'package:flutter/widgets.dart';

import 'user_messages.dart';

class Strings {
  const Strings(this.locale);
  final Locale locale;
  bool get zh => locale.languageCode == 'zh';
  String t(String key) => zh ? (_zh[key] ?? key) : key;
  String error(Object value) => localizedError(value, chinese: zh);
  String notice(String value) => localizedNotice(value, chinese: zh);

  static const _zh = <String, String>{
    'Back to home': '返回首页',
    'Computers': '我的电脑',
    'Add computer': '添加电脑',
    'Connect your computer': '连接你的电脑',
    'Cloud or direct. Your choice.': '云端或直连，按需选择。',
    'Cloud': '云端',
    'Direct': '直连',
    'Encrypted relay across networks.': '跨网络访问\n端到端加密',
    'LAN, VPN or HTTPS. No cloud account.': '局域网 / VPN / HTTPS\n无需云账号',
    'Add direct': '添加直连',
    'Cloud device': '云设备',
    'Sign in to discover your cloud computers, or add a direct connection.':
        '登录后自动发现云端电脑，也可添加直连。',
    'Swipe left to remove a direct connection': '左滑卡片移除直连',
    'Waiting for desktop permission': '等待桌面允许连接',
    'Connection allowed on desktop': '桌面已允许连接',
    'Connection disabled on this desktop': '此桌面的连接权限已关闭',
    'Device permanently revoked': '设备已永久撤销',
    'Phones and computers on the same account are discovered automatically. Enable Allow Connection on the desktop; signing in never grants access.':
        '同账号手机与电脑会自动发现彼此。请在桌面开启“允许连接”；登录不会自动授予访问权限。',
    'Safety code': '安全码',
    'Compare this safety code with the desktop before allowing the first connection.':
        '首次允许连接前，请核对手机与桌面的安全码一致。',
    'Keep both devices online for the first encrypted identity check.':
        '首次加密身份验证需要手机与桌面同时在线。',
    'Desktop identity': '桌面身份公钥',
    'Server changes require an explicit sign-out. Device discovery never selects another server or account.':
        '更换服务器需要先明确退出登录，设备发现不会切换到其他服务器或账号。',
    'Signed in. Same-account devices appear automatically. Enable Allow Connection on each desktop.':
        '已登录，同账号设备会自动出现。请在各桌面开启“允许连接”。',
    'Request pairing': '请求配对',
    'Phone name': '手机名称',
    'Select your computer, then allow this phone on the desktop. Pairing requests do not expire.':
        '选择电脑后，在电脑端允许这台手机配对。请求不会过期。',
    'No computers found. Sign in on your desktop first.': '未找到电脑，请先在电脑端登录云账号。',
    'Pairing approved on desktop': '电脑已允许配对',
    'Pairing rejected or withdrawn': '配对已被拒绝或撤回',
    'Waiting for desktop approval': '等待电脑允许配对',
    'Compare this safety code with the desktop before allowing pairing.':
        '允许配对前，请核对手机与电脑上的安全码一致。',
    'Closing this dialog keeps the request pending. Only an explicit approval, rejection or withdrawal changes it.':
        '关闭窗口会保留请求，只有明确允许、拒绝或撤回才会改变状态。',
    'Withdraw request': '撤回请求',
    'Remove request': '移除请求',
    'Server changes require an explicit sign-out. Pairing requests never select a server or account.':
        '更换服务器需要先明确退出登录，配对请求不会切换服务器或账号。',
    'Open cloud': '进入云端',
    'Log out': '退出登录',
    'Saved computers': '已保存的电脑',
    'No computers yet': '还没有添加电脑',
    'No online cloud computers': '暂无在线云设备',
    'Offline cloud computers stay saved and reappear automatically when they reconnect.':
        '离线云设备会保留，上线后自动显示。',
    'Sign in and pair a cloud computer, or add a direct connection.':
        '登录并配对云端电脑，或添加直连。',
    'Cloud relay': '云端中继',
    'P2P direct': 'P2P 直连',
    'Cloud access unavailable': '云服务访问资格不可用',
    'Cloud service': '云服务中心',
    'Manage cloud service': '管理云服务',
    'Account and server settings': '账号与服务器设置',
    'Official cloud': '官方云服务',
    'Self-hosted server': '自部署服务器',
    'Cloud server': '云端服务器',
    'Your cloud workspace': '电脑在远方，工作在手边。',
    'Not signed in': '尚未登录',
    'Sign in to official cloud': '登录官方云',
    'Sign in to cloud': '登录云服务',
    'Pair computer': '配对电脑',
    'Pair cloud computer': '配对云端电脑',
    'Cloud computer': '云端电脑',
    'Cloud computers': '云端电脑',
    'Local direct computers': '本地直连电脑',
    'Local direct': '本地直连',
    'Local connections work without a cloud account.': '本地直连始终可用，无需云账号。',
    'Cloud relay or local direct. Your desktop remains in control.':
        '云端中继或本地直连，控制权始终在你的电脑。',
    'Cloud services are unavailable in this build': '此构建暂不支持云服务',
    'End-to-end encrypted relay': '端到端加密中继',
    'Connect away from your local network. Pair by QR and approve the keys on your desktop.':
        '不在同一局域网，也能连接电脑。扫码配对，并在桌面端核对公钥与批准。',
    'Your desktop, beyond the local network': '让你的电脑不再受局域网限制',
    'Sign in, then scan the cloud pairing QR on your desktop. Login alone does not authorize a computer.':
        '登录后扫描桌面端的云配对二维码。登录账号不会自动授权电脑。',
    'Explicit server login required': '需明确登录对应服务器与账号',
    'Checking service status': '正在检查服务状态',
    'Sign in to check service status': '登录后查看服务状态',
    'Service status cannot be confirmed': '暂无法确认服务状态',
    'No hosted service-day checks': '自部署不检查托管服务天数',
    'Expiry not provided by the server': '服务器未提供到期时间',
    'Valid until': '服务到期时间：',
    'While the app can run': '应用可运行期间',
    'Background push': '后台推送',
    'Cloud notifications are unavailable on this device': '此设备暂不支持云端通知',
    'Not enabled; your consent is required': '尚未开启，需要你的明确同意',
    'Sign in and pair a computer to receive notifications': '登录并配对电脑后接收通知',
    'Pair a computer to receive notifications': '配对电脑后接收通知',
    'Available while the app can run': '可在应用可运行期间接收',
    'Background push cannot be confirmed': '暂无法确认后台推送能力',
    'Notification availability cannot be confirmed': '暂无法确认云端通知是否可用',
    'Background push is not configured on this server': '此服务器尚未配置后台推送',
    'Background push is not configured in this build': '此构建尚未配置后台推送',
    'Push app configuration does not match this server': '推送应用配置与此服务器不匹配',
    'Background push is enabled': '后台推送已启用',
    'Server changes require an explicit sign-out. QR codes never select a server or account.':
        '切换服务器前必须明确退出账号。二维码不会自动选择服务器或账号。',
    'Hosted service': '托管云服务',
    'Signed in. Computer authorization still requires desktop approval.':
        '账号已登录，电脑授权仍需在桌面端批准。',
    'Email': '邮箱',
    'Email / Account': '邮箱/账号',
    'Enter your email or account': '请输入邮箱或账号',
    'Enter your cloud account': '请填写云账号',
    'Enter your password': '请填写密码',
    'Ask your server administrator to create an account. This app does not register accounts.':
        '请联系自部署服务器管理员创建账号。此应用不提供注册。',
    'New here? Complete registration in the desktop app first, then sign in here.':
        '首次使用？请先在桌面端完成注册，再在此登录。',
    'A saved login is not proof that the service is currently available. Refresh to check with the server.':
        '已保存登录不代表服务当前可用，刷新后以服务器返回的状态为准。',
    'Delivery is not guaranteed. Viewing this page does not grant consent or request notification permissions.':
        '不保证通知送达。浏览此页面不会代你同意或申请通知权限。',
    'Use an exact HTTP or HTTPS origin, including its port. HTTP does not protect account credentials. Paths, redirects and QR-selected servers are not accepted.':
        '支持 HTTP 和 HTTPS，请填写完整服务器地址并保留端口。HTTP 不保护账号凭据。不接受路径、跳转或由二维码选择服务器。',
    'Use server': '使用此服务器',
    'Use this server': '切换到此服务器',
    'Cloud login required': '需要登录对应云账号',
    'This saved computer requires its original server and account. Switch explicitly and sign in before reconnecting.':
        '这台电脑需要原来的服务器与账号，请明确切换并登录后再连接。',
    'Open cloud service': '打开云服务中心',
    'Saved connection server': '此连接所属的服务器',
    'Sign in with the account used to pair this computer. No other server credentials will be used.':
        '请使用配对这台电脑时的账号登录，不会使用其他服务器的凭据。',
    'Check desktop approval': '检查桌面批准状态',
    'Reconnect': '重新连接',
    'Cloud task notifications': '云端任务通知',
    'Signing in enables encrypted cloud task notifications. Your system may ask for notification permission. Push services receive device tokens, delivery metadata and encrypted previews.':
        '登录后自动接收加密的云端任务通知，系统可能询问通知权限。推送服务会接收设备标识、投递信息和加密预览。',
    'Private cloud notifications': '私密云端通知',
    'Checking cloud notification settings': '正在检查云端通知设置',
    'Cloud notifications are off': '云端通知已关闭',
    'System notification permission is required': '需要系统通知权限',
    'Direct cloud updates only; remote push is not configured':
        '仅接收云端直达更新；未配置远程推送',
    'Encrypted cloud notifications are enabled': '加密云端通知已启用',
    'Waiting for private push registration': '正在等待私密推送注册',
    'Cloud notification settings could not be saved': '无法保存云端通知设置',
    'Allow encrypted notifications': '允许加密通知',
    'Your approved desktop encrypts previews with separate notification keys. The cloud can see account, device, timing and traffic metadata, but not preview text.':
        '已批准的桌面使用独立通知密钥加密预览。云端可以看到账号、设备、时序和流量元数据，但看不到预览文字。',
    'This build uses Umeng U-Push. After consent, Umeng receives a device token, delivery metadata and ciphertext. Analytics and advertising collection are disabled. Previous Lenovo test consent does not apply.':
        '此构建使用友盟 U-Push。取得同意后，友盟会接收设备令牌、投递元数据和密文。统计和广告采集已关闭，之前的联想测试同意不适用于此功能。',
    'Remote delivery, when configured, uses the platform push service. SDK-free builds receive only authenticated direct cloud updates while the app can run.':
        '配置远程投递后使用平台推送服务。不含推送 SDK 的构建仅在应用可运行时接收已认证的云端直达更新。',
    'Missing keys, a locked device or extension timeout may show only a generic alert. Delivery is not guaranteed. Turning this off stops local previews and requests endpoint removal when the server is reachable; it does not stop desktop tasks or direct connections.': '密钥不可用、设备锁定或扩展超时可能仅显示通用提示，不保证送达。关闭后停止本地预览，并在服务器可达时请求移除推送端点；不会停止桌面任务或直连。',
    'Choose the cloud server explicitly. A QR code never changes the selected account or server.':
        '请明确选择云端服务器。二维码不会改变所选账号或服务器。',
    'Cloud server origin': '云端服务器地址',
    'Check server capabilities': '检查服务器能力',
    'Saved cloud account': '已保存的云端账号',
    'Cloud account': '云端账号',
    'Service status': '服务状态',
    'Sign out': '退出账号',
    'Service active': '服务可用',
    'Service unavailable': '服务暂不可用',
    'Self-hosted service': '自建服务器服务',
    'Computer name': '电脑名称',
    'Five-minute desktop pairing QR': '桌面五分钟有效配对二维码',
    'Compare these keys with the desktop candidate. Approve only on the desktop.':
        '请与桌面候选设备的公钥核对，仅在桌面端批准配对。',
    'Desktop control key': '桌面控制公钥',
    'Phone control key': '手机控制公钥',
    'Phone preview key': '手机预览公钥',
    'Close': '关闭',
    'Prepare pairing': '准备配对',
    'Confirm keys and request approval': '确认公钥并请求批准',
    'Cloud connections use the account saved for this exact server and the locally approved desktop keys.':
        '云端连接使用此服务器专属的已保存账号，以及在桌面本机批准并固定的公钥。',
    'Cloud account and reconnect': '管理云端账号并重新连接',
    'Connect': '连接',
    'Your work. Within reach.': '工作在电脑，进度在手边。',
    'A private connection to the coding tools on your own computers.':
        '通过你自己的网关，连接电脑上的编程助手。',
    'Direct to your gateway': '直连你的网关',
    'No cloud relay': '不经过云端中继',
    'No push SDKs': '不接入推送 SDK',
    'Chat stays with your gateway': '聊天直连你的网关',
    'Lenovo test: U-Push consent': '联想测试：友盟推送知情同意',
    'Lenovo debug builds only. Not a production privacy policy.':
        '仅限联想调试版，不是正式隐私政策。',
    'Why this test': '为什么要做这个测试',
    'This test enables U-Push registration and manual console notifications on your Lenovo device. Gateway-triggered fallback delivery is not connected yet.':
        '本次在你的联想设备上启用友盟 U-Push 注册和后台手动发送通知的测试，网关触发的离线补发尚未接通。',
    'What the push service may process': '推送服务可能处理的信息',
    'Umeng and its Alibaba transport may process device identifiers (such as Android ID or OAID), device and app information, network information, and notification delivery records.':
        '友盟及其阿里巴巴传输组件可能处理设备标识（如 Android ID 或 OAID）、设备与应用信息、网络信息以及通知送达记录。',
    'What stays with your gateway': '哪些信息不会放进友盟推送',
    'This integration does not upload chat text, attachments, gateway addresses, or login credentials. Test notifications show generic text and only open Bridge.':
        '本次接入不会上传聊天正文、附件、网关地址或登录凭据。测试通知只显示通用文案，点击只打开 Bridge。',
    'Your choice': '你可以自行决定',
    'Declining keeps direct notifications and all chat features available. Your choice is stored on this phone. Withdrawal blocks test notifications and requests push disabling; it does not erase uploaded metadata or guarantee all vendor background work stops before an app restart. A changed disclosure needs fresh consent.': '不同意也能继续使用直连通知和全部聊天功能，选择保存在本机。撤回会屏蔽测试通知并请求停用推送，但不会删除已上传的元数据，也不能保证重启应用前所有厂商后台任务都已停止；说明变更后需重新同意。',
    'Agreeing now initializes and registers U-Push. Shared analytics and crash collection are disabled. Real notification delivery is not yet verified.':
        '现在同意会初始化并注册友盟 U-Push；共用组件中的统计和崩溃采集已禁用。真实通知送达仍需验证。',
    'Official Umeng privacy guidance': '查看友盟官方隐私配置说明',
    'Not now; keep direct notifications': '暂不同意，保留直连通知',
    'Agree to this device test only': '同意仅在本机测试',
    'U-Push test privacy': '友盟推送测试隐私',
    'Test consent saved. U-Push is waiting to start.': '已保存测试同意，友盟推送正在等待启动。',
    'Registering this device with U-Push...': '正在向友盟注册本机推送…',
    'U-Push registered. Real notification delivery still needs a device test.':
        '友盟推送已注册，真实通知送达仍需真机测试。',
    'U-Push registration failed. Review test consent to retry.':
        '友盟推送注册失败，可查看测试说明并再次同意以重试。',
    'Consent withdrawn. Waiting for U-Push to confirm push disabling.':
        '已撤回同意，正在等待友盟确认停用推送。',
    'U-Push disabling was not confirmed. Restart the app before another test.':
        '未能确认友盟推送已停用，请重启应用后再测试。',
    'Copy test device token': '复制测试设备 Token',
    'Test device token copied. Paste it only into your Umeng test console.':
        '已复制测试设备 Token，请仅粘贴到自己的友盟测试后台。',
    'Could not copy the test device token. Please try again.':
        '无法复制测试设备 Token，请重试。',
    'U-Push test notifications are off. Direct notifications are unchanged.':
        '友盟测试通知已关闭，原有直连通知不受影响。',
    'Review test disclosure': '查看测试说明',
    'Withdraw test consent': '撤回测试同意',
    'Could not read the test consent. Push status is unavailable.':
        '无法读取测试同意状态，推送状态暂不可用。',
    'Could not save your choice. Review the test status and try again.':
        '无法保存你的选择，请查看测试状态后重试。',
    'Could not open the official privacy details. Please try again.':
        '无法打开友盟官方隐私说明，请重试。',
    'Name': '电脑名称',
    'Gateway address': '网关地址',
    'Paste the address or pairing link shown on your computer.':
        '粘贴电脑网关显示的地址或配对链接。',
    'HTTP and HTTPS addresses are supported. HTTP does not encrypt credentials or gateway traffic.':
        '支持 HTTP 和 HTTPS 地址。HTTP 不加密账号凭据或网关流量。',
    'Scan QR': '扫描二维码',
    'Scan on your phone': '请在手机上扫码',
    'Cancel': '取消',
    'Save and connect': '保存并连接',
    'Sign in': '登录',
    'Username': '用户名',
    'Password': '密码',
    'Credentials stay in your device secure storage.': '登录凭据仅保存在设备的系统安全存储中。',
    'Choose a conversation': '选择一条聊天',
    'Continue without changing its original execution environment.':
        '在原来的执行环境中查看进度、继续对话。',
    'Search conversations': '搜索聊天或项目',
    'New chat': '新建聊天',
    'Refresh': '刷新',
    'Load more': '加载更多',
    'No conversations yet': '暂时没有聊天',
    'Enable and configure this client on the computer first.':
        '请先在电脑网关启用并配置这个客户端。',
    'History only': '仅查看历史',
    'Live': '已连接',
    'Running': '运行中',
    'Online': '在线',
    'Offline': '离线',
    'Waiting for approval': '等待审批',
    'Continue session': '继续会话',
    'Stop task': '停止任务',
    'Older messages': '更早的消息',
    'Reading history…': '正在读取历史…',
    'History is not live control state. Refresh before taking action.':
        '历史记录不代表当前执行状态；刷新后才能操作。',
    'Write a message…': '继续这条聊天…',
    'Send': '发送',
    'Add attachment': '添加附件',
    'Photos': '相册图片',
    'Choose a photo or screenshot': '选择照片或截图',
    'Files': '文件',
    'Browse other files': '浏览其他文件',
    'Preview image': '预览图片',
    'Remove attachment': '移除附件',
    'Adding attachment...': '正在添加附件…',
    'Add to current task': '补充当前任务',
    'Model': '模型',
    'Reasoning effort': '推理强度',
    'Apply': '应用',
    'Copy': '复制',
    'Copy code': '复制代码',
    'Copied': '已复制',
    'Tool activity': '工具活动',
    'You': '你',
    'Assistant': '助手',
    'Approval': '审批请求',
    'Accept once': '仅本次允许',
    'Decline': '拒绝',
    'Answer': '回答',
    'Submit answers': '提交回答',
    'Handle this request on the computer.': '请在电脑端处理此类型请求。',
    'Pending verification': '结果待核对',
    'Check on the computer': '在电脑上核对',
    'This operation may already have been submitted. It will never be replayed automatically.':
        '这次操作可能已经提交，不会自动重发。',
    'I checked on the computer': '我已在电脑上核对',
    'Only confirm after checking the original conversation. This does not resend anything or claim that the operation succeeded.':
        '请先查看电脑上的原会话。确认只解除本机的拦截，不会重新发送，也不代表操作成功。',
    'Inbox': '未读动态',
    'No new activity': '暂无新动态',
    'Task notifications are automatic. Allow Android notifications to receive alerts.':
        '后台任务通知自动开启；允许安卓通知权限后即可接收提醒。',
    'Android notifications': '安卓通知',
    'Allow notifications in Android settings': '请在安卓设置中允许通知，并启用两个通知类别',
    'Open the app to restart background listening': '请重新打开应用以恢复后台监听',
    'Add a gateway to receive notifications': '添加网关后即可接收通知',
    'Connecting to gateways...': '正在连接网关…',
    'Cloud notification storage is unavailable; chat remains available':
        '云通知存储暂不可用，聊天连接仍可使用',
    'Server notification settings could not be confirmed': '暂时无法确认服务器上的通知设置',
    'No gateway is reachable or notifications are disabled':
        '网关暂不可达、需要登录，或网关未启用通知',
    'Listening to saved gateways': '正在监听已保存的网关',
    'Direct gateway listening uses an ongoing notification and additional battery. No Google services required. Force-stop, lost connectivity or battery restrictions can interrupt delivery.':
        '直连网关监听需要常驻通知，并会增加耗电，不依赖 Google 服务。强制停止应用、断网或省电限制都可能中断提醒。',
    'For more reliable alerts, allow Bridge to run in the background in Android battery settings.':
        '为提高提醒可靠性，请在安卓电池设置中允许 Bridge 后台运行。',
    'Send test notification': '发送测试通知',
    'Notification permissions': '通知权限',
    'Battery settings': '电池设置',
    'Notification setup failed. Reopen the app and try again.':
        '通知初始化失败，请重新打开应用后重试。',
    'Could not start notifications. Check Android permissions and try again.':
        '无法开启通知，请检查安卓权限后重试。',
    'Notification state could not be saved. Check device storage.':
        '通知状态保存失败，请检查手机存储空间。',
    'Test notification sent. Check the notification shade.':
        '测试通知已发送，请查看手机通知栏。此测试不代表网关事件已送达。',
    'Open Bridge permissions from Android app settings.':
        '请在安卓应用设置中打开 Bridge 的权限页面。',
    'Appearance': '外观',
    'Open source licenses': '开源许可',
    'System theme': '跟随系统',
    'Light': '浅色',
    'Dark': '深色',
    'Language': '语言',
    'Remove connection': '移除连接',
    'Swipe left to remove a connection': '左滑卡片移除连接',
    'Remove the saved connection, credentials, drafts and pending records from this phone?':
        '从本机移除这台电脑的连接、凭据、草稿及待核对记录？',
    'The gateway and conversations on your computer are not deleted.':
        '不会删除电脑上的网关或聊天。',
    'Remove': '移除',
    'Project': '项目',
    'Title': '聊天名称',
    'Opening message': '首条消息',
    'Execution environment': '执行环境',
    'Create': '创建',
    'No registered projects': '没有已登记的项目',
    'Register a project in the gateway first.': '请先在电脑网关登记项目。',
    'Camera unavailable. Paste a pairing link instead.': '相机不可用；也可以粘贴配对链接。',
    'Point at the pairing QR code in your gateway.': '对准电脑网关中的配对二维码。',
    'External image blocked': '已阻止外部图片',
    'Image unavailable': '图片暂不可用',
    'Long content was truncated. Read the full output on the computer.':
        '长内容已截断，请在电脑查看完整输出。',
    'Unknown result. Check the computer before submitting again.':
        '结果不明，请在电脑核对后再提交。',
    'No supported clients': '暂无可用客户端',
    'Settings': '设置',
    'Retry': '重试',
    'Connection failed': '连接失败',
    'Starting native core…': '正在启动原生核心…',
    'Native core could not start': '原生核心启动失败',
    'Restart the app. If it still cannot start, update it or contact support.':
        '请重启应用；如果仍无法启动，请更新应用或联系维护者。',
  };
}
