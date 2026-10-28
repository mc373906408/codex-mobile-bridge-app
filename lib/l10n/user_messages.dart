import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

const _unknownError =
    'The operation result could not be confirmed. Check the connection and verify any submission on the computer.';
const _unknownNotice =
    'The gateway has a notice. Check the details on the computer.';
const _timeout = 'The connection timed out. Check the network and gateway.';
const _network =
    'The gateway could not be reached or its certificate was not trusted';
const _storage = 'Secure credential storage is unavailable';

String localizedError(Object error, {required bool chinese}) =>
    _localize(_messageKey(error) ?? _unknownError, chinese);

String localizedNotice(String message, {required bool chinese}) =>
    _localize(_messageKey(message) ?? _unknownNotice, chinese);

String _localize(String key, bool chinese) => chinese ? _messages[key]! : key;

String? _messageKey(Object error) {
  final raw = switch (error) {
    AnyhowException(:final message) => message,
    StateError(:final message) => message,
    FormatException(:final message) => message,
    TimeoutException() => _timeout,
    SocketException() => _network,
    TlsException() => 'The gateway certificate could not be verified.',
    FileSystemException() =>
      'Local files could not be accessed. Check storage space and permissions.',
    PlatformException(:final code)
        when const {
          'read',
          'readAll',
          'write',
          'delete',
          'deleteAll',
          'containsKey',
          'storage_unavailable',
        }.contains(code) =>
      _storage,
    PlatformException() || MissingPluginException() => 'A device feature is unavailable. Check app permissions or update the app.',
    _ => error.toString(),
  };
  final message = _unwrap(raw);
  if (_messages.containsKey(message)) return message;
  if (message.startsWith('Invalid gateway address:')) {
    return 'Invalid gateway address. Use HTTPS or a local network address.';
  }
  if (message.startsWith('Incompatible gateway response:')) {
    return 'The gateway response is incompatible. Check the app and gateway versions.';
  }
  final http = RegExp(r'^Gateway error \((\d{3})\):').firstMatch(message);
  if (http != null) {
    // Gateway bodies may contain diagnostics or secrets, not localized UI copy.
    return switch (int.parse(http.group(1)!)) {
      400 || 422 => 'The gateway rejected the request. Check your input.',
      401 => 'Please sign in again',
      403 =>
        'Access was denied. Check your account permissions on the computer.',
      404 => 'The gateway endpoint was not found. Check the address and gateway version.',
      408 || 504 => _timeout,
      409 ||
      412 => 'Session state or account changed. Refresh before trying again',
      413 => 'Gateway response exceeded the safe size limit',
      429 => 'Too many requests. Wait before performing another operation.',
      >= 500 => 'The gateway encountered an error. Check it on the computer.',
      _ => _unknownError,
    };
  }
  return null;
}

String _unwrap(String value) {
  var message = value.trim();
  // Also accept messages already stringified by older native/event boundaries.
  for (var depth = 0; depth < 4; depth++) {
    final wrapper = RegExp(r'^(?:AnyhowException|Exception|StateError)\(')
        .firstMatch(message);
    if (wrapper != null) {
      message = message.substring(wrapper.end);
      if (message.endsWith(')')) {
        message = message.substring(0, message.length - 1);
      }
      continue;
    }
    final prefix = RegExp(
      r'^(?:Bad state|Exception|FormatException|Invalid argument\(s\)): ',
    ).firstMatch(message);
    if (prefix == null) break;
    message = message.substring(prefix.end);
  }
  return message.split(RegExp(r'[\r\n]')).first.trim();
}

// Only known application messages are displayed; unknown diagnostics stay out
// of the UI in both languages. Conversation content is not passed through here.
const _messages = <String, String>{
  _unknownError: '暂时无法确认操作结果。请检查连接；如已提交请求，请先在电脑上核对。',
  _unknownNotice: '网关返回了提示，请在电脑端查看详情。',
  _network: '无法连接网关，或安全证书不受信任。请检查网关地址、网络连接和证书配置。',
  _timeout: '连接超时，请检查网络连接和电脑上的网关服务。',
  _storage: '无法访问系统安全存储，请检查设备状态和应用权限。',
  'The gateway certificate could not be verified.': '网关安全证书验证失败，请检查电脑端的证书配置。',
  'Invalid gateway address. Use HTTPS or a local network address.':
      '网关地址无效，请填写完整的安全连接地址，或局域网地址和端口。',
  'The gateway response is incompatible. Check the app and gateway versions.':
      '网关返回的数据不兼容，请检查应用和网关版本是否匹配。',
  'Please sign in again': '登录未通过或已失效，请检查用户名和密码后重新登录。',
  'The gateway redirected the request. Credentials were not forwarded':
      '网关要求跳转到其他地址。为保护登录凭据，已停止请求，请检查网关地址。',
  'Gateway response exceeded the safe size limit': '请求或响应数据超过安全大小限制，请减少内容或附件。',
  'The gateway rejected the request. Check your input.': '网关拒绝了请求，请检查填写的内容。',
  'Access was denied. Check your account permissions on the computer.':
      '访问被拒绝，请在电脑端检查账号权限。',
  'The gateway endpoint was not found. Check the address and gateway version.':
      '未找到网关接口，请检查网关地址和版本。',
  'Too many requests. Wait before performing another operation.':
      '请求过于频繁，请稍后操作；已提交的任务请先在电脑端核对。',
  'The gateway encountered an error. Check it on the computer.':
      '网关服务发生错误，请在电脑端检查服务状态；已提交的操作请先核对结果。',
  'Local files could not be accessed. Check storage space and permissions.':
      '无法读写本机文件，请检查存储空间和应用权限。',
  'A device feature is unavailable. Check app permissions or update the app.':
      '设备功能暂不可用，请检查应用权限或更新应用。',
  'Local state could not be saved. Check the computer before retrying':
      '本机状态保存失败，请先在电脑端核对操作结果，不要重复提交。',
  'Operation cancelled': '操作已取消。',
  'Connection is closed': '连接已关闭，请重新选择电脑并连接。',
  'Select and authenticate a computer first': '请先选择电脑并登录。',
  'Secure credential storage is unavailable; sign in again after restarting':
      '登录凭据未能安全保存，重启应用后需要重新登录。',
  'Credentials belong to a different gateway address': '登录凭据与网关地址不匹配，请重新登录。',
  'Invalid login input': '登录信息不符合要求，请检查用户名和密码的长度。',
  'Invalid or expired pairing code': '配对码无效或已过期，请从电脑端获取新的配对码。',
  'Session state or account changed. Refresh before trying again':
      '会话状态或账号已变化，请刷新后再操作。',
  'This session cannot use the selected send mode': '当前会话不支持所选的发送方式，请刷新会话状态。',
  'Message is empty or too large': '消息为空或内容过长，请检查消息长度和附件数量。',
  'Attachments are not supported': '当前客户端不支持附件。',
  'Invalid attachment ID': '附件信息无效，请重新选择附件。',
  'Attachment exceeds 20 MiB': '附件超过 20 兆字节，请选择更小的文件。',
  'Attachment is unsupported or exceeds 20 MiB': '附件类型不受支持或超过 20 兆字节，请重新选择文件。',
  'This client accepts image attachments only': '当前客户端仅支持图片附件。',
  'Invalid upload ID': '上传记录无效，请刷新后重新选择附件。',
  'Unsupported image reference': '不支持此图片来源，请在电脑端查看。',
  'Image is unavailable': '图片暂不可用，请在电脑端查看。',
  'Only raster images are rendered': '仅支持普通图片格式，请在电脑端查看此内容。',
  'There is no confirmed running task to stop': '没有可确认正在运行的任务，请刷新后再查看。',
  'Resume is not available': '当前会话暂不支持继续执行。',
  'This approval has expired or was already handled': '此审批已过期或已处理，请刷新查看最新请求。',
  'Handle this request on the computer': '请在电脑端处理此请求。',
  'Handle this request on the computer.': '请在电脑端处理此请求。',
  'Answer every question': '请回答所有问题。',
  'Missing answer': '还有问题未回答，请补充完整。',
  'Invalid answer': '回答内容不符合要求，请检查后再提交。',
  'Model settings are not available': '当前会话不支持调整模型设置。',
  'Select an advertised model': '请选择网关提供的可用模型。',
  'Select an advertised reasoning effort': '请选择当前模型支持的推理强度。',
  'Invalid new-chat title or message': '聊天名称或首条消息不符合要求，请检查内容和长度。',
  'The project is no longer available': '该项目已不可用，请在电脑端检查项目配置。',
  'This client requires an opening message': '此客户端需要填写首条消息才能创建聊天。',
  'Connection changed; reopen the new chat dialog': '连接已变化，请重新打开新建聊天窗口。',
  'Session changed; reopen model settings': '会话已变化，请重新打开模型设置。',
  'The task changed; refresh before stopping': '任务状态已变化，请刷新后再停止任务。',
  'This approval changed or expired. Read the current request first':
      '审批请求已变化或过期，请先查看最新请求。',
  'Conversation unavailable; find it on the original computer':
      '聊天暂不可用，请在原来的电脑上查看。',
  'Local database needs a newer application': '本机数据需要更新版本的应用，请先更新应用。',
  'Invalid display preferences': '外观或语言设置无效，请重新选择。',
  'Invalid computer configuration': '电脑连接配置无效，请检查名称和网关地址。',
  'A different address requires a separate connection and login':
      '新的网关地址需要单独添加连接并登录。',
  'Account identity has not been verified': '账号身份尚未验证，请重新连接并登录。',
  'Draft exceeds the gateway limit': '草稿超过网关限制，请减少内容或附件。',
  'Invalid operation ID': '操作记录无效，请先在电脑端核对结果。',
  'Operation ID was already used for different content':
      '操作记录与提交内容不一致，请先在电脑端核对。',
  'Check the previous unresolved operation on the computer before submitting again':
      '上一次操作结果尚未确认，请先在电脑端核对，不要重复提交。',
  'Explicit confirmation of a desktop check is required': '请先在电脑端核对，再确认已检查结果。',
  'Check the new chat on the computer first': '请先在电脑端核对新建聊天的结果。',
  'Previous submission is unresolved; it was not replayed':
      '上一次提交的结果尚未确认，应用没有自动重发，请在电脑端核对。',
  'Submission may have reached the computer': '请求可能已到达电脑，请先核对结果，不要重复提交。',
  'Check the result on the computer; this operation will not be replayed':
      '请在电脑端核对结果，此操作不会自动重发。',
  'Upload was not acknowledged; check it on the computer':
      '尚未收到上传确认，请在电脑端核对，不要重复上传。',
  'Unknown result. Check the computer before submitting again.':
      '结果不明，请在电脑端核对后再提交。',
  'History changed; refresh the latest view': '历史记录已变化，请刷新查看最新内容。',
  'Memory window reached. Refresh to return to the latest messages':
      '已达到本机消息显示上限，请刷新回到最新消息。',
  'Account identity is unavailable. Refresh or continue on the computer':
      '暂时无法验证账号身份，请刷新，或在电脑端继续操作。',
  'Client unavailable; configure it on the computer': '客户端暂不可用，请先在电脑端完成配置。',
  'Some execution environments are unavailable': '部分执行环境暂不可用，请在电脑端检查连接。',
  'History cursor is too large': '历史记录定位信息过长，请刷新查看最新内容。',
  'Invalid session identity': '会话信息无效，请重新选择聊天。',
  'Invalid Codex session ID': '会话编号无效，请重新选择聊天。',
  'Codex session ID must be canonical': '会话编号格式不正确，请重新选择聊天。',
  'Invalid API path': '网关接口地址无效，请检查应用和网关版本。',
  'Unsupported mobile platform': '此设备平台暂不受支持。',
};
