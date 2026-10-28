import 'dart:async';
import 'dart:io';

import 'package:bridge_mobile/l10n/strings.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const _network =
    'The gateway could not be reached or its certificate was not trusted';
const _networkZh = '无法连接网关，或安全证书不受信任。请检查网关地址、网络连接和证书配置。';
const _trace =
    '\n\nStack backtrace:\n   0: private/path.rs:42\n   1: secret-token';
const _zh = Strings(Locale('zh'));
const _en = Strings(Locale('en'));

void main() {
  test(
    'native network failures are localized without exception or backtrace',
    () {
      for (final error in <Object>[
        AnyhowException('$_network$_trace'),
        AnyhowException(_network),
        'AnyhowException($_network$_trace)',
        'AnyhowException($_network)',
        'Exception: AnyhowException($_network$_trace)',
        '$_network\r\nStack backtrace:\r\nsecret-token',
        const SocketException('private-host'),
      ]) {
        expect(_zh.error(error), _networkZh);
        expect(_en.error(error), _network);
      }
    },
  );

  final cases = <Object, String>{
    AnyhowException('Invalid gateway address: use an HTTPS origin$_trace'):
        '网关地址无效，请填写完整的安全连接地址，或局域网地址和端口。',
    AnyhowException('Please sign in again$_trace'): '登录未通过或已失效，请检查用户名和密码后重新登录。',
    'Invalid or expired pairing code': '配对码无效或已过期，请从电脑端获取新的配对码。',
    'Incompatible gateway response: missing CSRF token':
        '网关返回的数据不兼容，请检查应用和网关版本是否匹配。',
    'The gateway redirected the request. Credentials were not forwarded':
        '网关要求跳转到其他地址。为保护登录凭据，已停止请求，请检查网关地址。',
    StateError('Attachment exceeds 20 MiB'): '附件超过 20 兆字节，请选择更小的文件。',
    'Bad state: Connection is closed': '连接已关闭，请重新选择电脑并连接。',
    TimeoutException('secret-token'): '连接超时，请检查网络连接和电脑上的网关服务。',
    const HandshakeException('secret-token'): '网关安全证书验证失败，请检查电脑端的证书配置。',
    const FileSystemException('secret-token', 'private/path'):
        '无法读写本机文件，请检查存储空间和应用权限。',
    PlatformException(code: 'write', message: 'secret-token'):
        '无法访问系统安全存储，请检查设备状态和应用权限。',
    PlatformException(code: 'picker_failed', message: 'secret-token'):
        '设备功能暂不可用，请检查应用权限或更新应用。',
    MissingPluginException('secret-token'): '设备功能暂不可用，请检查应用权限或更新应用。',
    'Local state could not be saved. Check the computer before retrying':
        '本机状态保存失败，请先在电脑端核对操作结果，不要重复提交。',
    'Previous submission is unresolved; it was not replayed':
        '上一次提交的结果尚未确认，应用没有自动重发，请在电脑端核对。',
  };
  for (final entry in cases.entries) {
    test('localized error: ${entry.key.runtimeType} ${entry.value}', () {
      expect(_zh.error(entry.key), entry.value);
      expect(_zh.error(entry.key), isNot(contains(RegExp('[A-Za-z]'))));
    });
  }

  final httpCases = <int, String>{
    400: '网关拒绝了请求，请检查填写的内容。',
    401: '登录未通过或已失效，请检查用户名和密码后重新登录。',
    403: '访问被拒绝，请在电脑端检查账号权限。',
    404: '未找到网关接口，请检查网关地址和版本。',
    408: '连接超时，请检查网络连接和电脑上的网关服务。',
    409: '会话状态或账号已变化，请刷新后再操作。',
    412: '会话状态或账号已变化，请刷新后再操作。',
    413: '请求或响应数据超过安全大小限制，请减少内容或附件。',
    422: '网关拒绝了请求，请检查填写的内容。',
    429: '请求过于频繁，请稍后操作；已提交的任务请先在电脑端核对。',
    500: '网关服务发生错误，请在电脑端检查服务状态；已提交的操作请先核对结果。',
    502: '网关服务发生错误，请在电脑端检查服务状态；已提交的操作请先核对结果。',
    503: '网关服务发生错误，请在电脑端检查服务状态；已提交的操作请先核对结果。',
    504: '连接超时，请检查网络连接和电脑上的网关服务。',
  };
  for (final entry in httpCases.entries) {
    test('gateway status ${entry.key} never exposes the response body', () {
      final error = AnyhowException(
        'Gateway error (${entry.key}): English diagnostic secret-token$_trace',
      );
      expect(_zh.error(error), entry.value);
      expect(_en.error(error), isNot(contains('secret-token')));
      expect(_en.error(error), isNot(contains('Stack backtrace')));
    });
  }

  test('unknown errors never leak diagnostics in either language', () {
    for (final error in <Object>[
      AnyhowException('Unknown native failure secret-token$_trace'),
      PanicException('private/path secret-token'),
      StateError('private/path secret-token'),
      'Unknown failure\n$_network',
      '',
    ]) {
      expect(_zh.error(error), '暂时无法确认操作结果。请检查连接；如已提交请求，请先在电脑上核对。');
      expect(_en.error(error), isNot(contains('secret-token')));
      expect(_en.error(error), isNot(contains('Exception')));
    }
  });

  test('notices use translations and a safe localized fallback', () {
    expect(
      _zh.notice('Some execution environments are unavailable'),
      '部分执行环境暂不可用，请在电脑端检查连接。',
    );
    expect(
      _zh.notice('History changed; refresh the latest view'),
      '历史记录已变化，请刷新查看最新内容。',
    );
    expect(_zh.notice(_network), _networkZh);
    expect(_zh.notice('Unknown warning secret-token'), '网关返回了提示，请在电脑端查看详情。');
    expect(
      _en.notice('Unknown warning secret-token'),
      'The gateway has a notice. Check the details on the computer.',
    );
  });
}
