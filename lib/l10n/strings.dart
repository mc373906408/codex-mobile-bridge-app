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
    'Connect': '连接',
    'Your work. Within reach.': '工作在电脑，进度在手边。',
    'A private connection to the coding tools on your own computers.':
        '通过你自己的网关，连接电脑上的编程助手。',
    'Direct to your gateway': '直连你的网关',
    'No cloud relay': '不经过云端中继',
    'No push SDKs': '不接入推送 SDK',
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
