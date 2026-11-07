import '../data/bridge_types.dart';

String environmentIssueReason(EnvironmentIssue issue, {required bool chinese}) {
  if (issue.loading) {
    return chinese
        ? '电脑正在后台读取此 SSH 主机的聊天，请稍后刷新列表。'
        : 'The computer is reading chats from this SSH host. Refresh the list shortly.';
  }
  final translations = <String, String>{
    'SSH 主机暂不可用，请检查电脑上的连接': 'The SSH host could not be reached. Check its connection on the computer.',
    'SSH 读取失败，请检查电脑上该主机的 SSH 连接': 'Reading the SSH host failed. Check its SSH connection on the computer.',
    'SSH 别名无效': 'The SSH host alias is invalid.',
    '暂时找不到 Codex 会话数据库，请打开电脑 Codex 后重试。': 'The Codex chat database was not found. Open Codex on the computer and retry.',
    'Codex 会话数据库正在更新，请稍后重试。':
        'The Codex chat database is being updated. Retry shortly.',
    '暂时无法读取 Codex 会话数据库，请稍后重试或重新打开电脑 Codex。': 'The Codex chat database could not be read. Retry or reopen Codex on the computer.',
  };
  return diagnosticText(
    chinese ? issue.reason : translations[issue.reason] ?? issue.reason,
  );
}

String diagnosticText(String text) {
  final withoutTrace = text
      .split(RegExp(r'\n(?:Stack backtrace:|Traceback \()'))
      .first;
  return withoutTrace
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
      .replaceAll(RegExp(r'(?<=://)[^/\s@]+@'), '[redacted]@')
      .replaceAllMapped(
        RegExp(
          r'\b(authorization|cookie|password|token|secret|api[_-]?key)\s*[:=]\s*[^\r\n,;]+',
          caseSensitive: false,
        ),
        (match) => '${match[1]}=[redacted]',
      );
}
