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
    'Cloud relay': '云端中继',
    'Cloud task notifications': '云端任务通知',
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
    'Public addresses require HTTPS. HTTP is allowed only for local networks.':
        '公网必须使用 HTTPS；HTTP 仅限局域网地址。',
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
