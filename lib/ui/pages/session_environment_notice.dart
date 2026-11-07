import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../l10n/environment_messages.dart';
import '../../l10n/strings.dart';
import '../session_environment.dart';

class SessionEnvironmentNotice extends StatelessWidget {
  const SessionEnvironmentNotice({
    super.key,
    required this.issues,
    required this.computerName,
    required this.strings,
    required this.onRefresh,
  });

  final List<EnvironmentIssue> issues;
  final String computerName;
  final Strings strings;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              strings.zh ? '部分聊天尚未加载' : 'Some chats have not loaded',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final issue in issues) _issue(context, issue),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onRefresh,
                icon: const Icon(CupertinoIcons.arrow_clockwise, size: 16),
                label: Text(strings.zh ? '重新加载列表' : 'Reload chats'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _issue(BuildContext context, EnvironmentIssue issue) {
    final name = sessionEnvironmentName(
      issue.environment,
      computerName: computerName,
      label: issue.label,
    );
    final status = issue.loading
        ? (strings.zh ? '读取中' : 'Loading')
        : (strings.zh ? '读取失败' : 'Could not load');
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$name · $status',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            environmentIssueReason(issue, chinese: strings.zh),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
