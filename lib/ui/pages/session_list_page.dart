import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../data/session_time.dart';
import '../../l10n/strings.dart';
import '../dialogs.dart';
import 'session_environment_notice.dart';
import 'session_list_header.dart';
import 'session_list_tile.dart';
import '../business/session_actions.dart';
import '../business/common.dart';

const _otherChatsGroup = '__other_chats__';
const _pinnedChatsSection = '__pinned_chats__';
const _recentChatsSection = '__recent_chats__';

class SessionListPage extends StatelessWidget {
  const SessionListPage({
    super.key,
    required this.model,
    required this.strings,
    required this.onInbox,
    required this.onCancelConnection,
    this.inboxUnreadCount,
  });

  final BridgeViewModel model;
  final Strings strings;
  final VoidCallback onInbox;
  final VoidCallback onCancelConnection;
  final int? inboxUnreadCount;

  bool get _canInteract => model.authenticated && !model.busy;
  String get _computerName => model.computerName(model.computer!);

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: model.refreshSessions,
    notificationPredicate: (notification) =>
        model.authenticated && defaultScrollNotificationPredicate(notification),
    child: CustomScrollView(
      key: PageStorageKey(('session-list', model.computer?.id, model.provider)),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).top),
        ),
        SliverToBoxAdapter(child: _heading(context)),
        if (model.sessions.isEmpty)
          SliverToBoxAdapter(child: _empty(context))
        else
          _rows(context),
        if (model.computer?.connectionType == ConnectionType.direct)
          SliverToBoxAdapter(child: _disconnect(context)),
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    ),
  );

  Widget _heading(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SessionListHeader(
        model: model,
        strings: strings,
        onInbox: onInbox,
        onCancelConnection: onCancelConnection,
        inboxUnreadCount: inboxUnreadCount,
      ),
      if (model.environmentIssues.isNotEmpty)
        SessionEnvironmentNotice(
          key: const Key('session-environment-notice'),
          issues: model.environmentIssues,
          computerName: _computerName,
          strings: strings,
          onRefresh: model.loading || !_canInteract
              ? null
              : model.refreshSessions,
        ),
      if (model.notice != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            strings.notice(model.notice!),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (model.pendingCreations.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: _canInteract
                ? () => pendingCreationsDialog(context, model, strings)
                : null,
            icon: const Icon(Icons.help_outline),
            label: Text(
              '${strings.t('Pending verification')} (${model.pendingCreations.length})',
            ),
          ),
        ),
    ],
  );

  Widget _empty(BuildContext context) {
    if (model.loading || model.environmentIssues.isNotEmpty) {
      return const SizedBox(height: 80);
    }
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(
            CupertinoIcons.chat_bubble_2,
            size: 36,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(strings.t('No conversations yet'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            strings.t(
              'Enable and configure this client on the computer first.',
            ),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _rows(BuildContext context) {
    final rows = [...model.sessions];
    final metadata = {
      for (final row in rows) row.session: decodeSessionMetadata(row.metadata),
    };
    String projectKey(SessionSummary row) =>
        metadata[row.session]?['projectKey']?.toString() ??
        '${row.session.environment}|${row.cwd.isEmpty ? 'unassigned' : row.cwd}';
    bool unassigned(SessionSummary row) {
      return projectKey(row) == '${row.session.environment}|unassigned';
    }

    double recency(SessionSummary row) =>
        double.tryParse(metadata[row.session]?['recency']?.toString() ?? '') ??
        double.tryParse(row.updatedAt) ??
        DateTime.tryParse(row.updatedAt)?.millisecondsSinceEpoch.toDouble() ??
        0;

    int compareRecent(SessionSummary left, SessionSummary right) {
      final time = recency(right).compareTo(recency(left));
      if (time != 0) return time;
      final identifier = right.session.id.compareTo(left.session.id);
      return identifier != 0
          ? identifier
          : right.session.environment.compareTo(left.session.environment);
    }

    rows.sort((left, right) {
      if (model.groupByProject) {
        final unassignedOrder = (unassigned(left) ? 1 : 0).compareTo(
          unassigned(right) ? 1 : 0,
        );
        if (unassignedOrder != 0) return unassignedOrder;
        return compareRecent(left, right);
      }
      if (left.pinned != right.pinned) return left.pinned ? -1 : 1;
      return compareRecent(left, right);
    });
    String groupName(SessionSummary row) =>
        metadata[row.session]?['projectName']?.toString() ?? row.cwd;

    final items =
        <
          ({String? project, String title, SessionSummary? session, bool group})
        >[];
    if (model.groupByProject) {
      final projects = <String, List<SessionSummary>>{};
      for (final row in rows) {
        projects.putIfAbsent(projectKey(row), () => []).add(row);
      }
      final collapsed =
          model.presentation['collapsedProjects'] as Map? ?? const {};
      for (final project in projects.entries) {
        items.add((
          project: project.key,
          title: groupName(project.value.first).isEmpty
              ? _otherChatsGroup
              : groupName(project.value.first),
          session: null,
          group: true,
        ));
        if (collapsed[project.key] != true) {
          for (final row in project.value) {
            items.add((project: null, title: '', session: row, group: false));
          }
        }
      }
    } else {
      final pinned = rows.where((row) => row.pinned).toList();
      final recent = rows.where((row) => !row.pinned).toList();
      if (pinned.isNotEmpty) {
        items.add((
          project: null,
          title: _pinnedChatsSection,
          session: null,
          group: false,
        ));
      }
      for (final row in pinned) {
        items.add((project: null, title: '', session: row, group: false));
      }
      if (pinned.isNotEmpty && recent.isNotEmpty) {
        items.add((
          project: null,
          title: _recentChatsSection,
          session: null,
          group: false,
        ));
      }
      for (final row in recent) {
        items.add((project: null, title: '', session: row, group: false));
      }
    }
    if (_canInteract &&
        model.selected == null &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false) {
      final candidates = items.map((item) => item.session).nonNulls.toList();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted &&
            TickerMode.valuesOf(context).enabled &&
            ModalRoute.isCurrentOf(context) != false) {
          model.prefetchListedSessions(candidates);
        }
      });
    }
    return SliverList.builder(
      itemCount: items.length + (model.nextOffset != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == items.length) {
          return TextButton(
            onPressed: model.loading || !model.authenticated
                ? null
                : () => model.refreshSessions(more: true),
            child: Text(strings.t('Load more')),
          );
        }
        final item = items[index];
        if (item.session == null) {
          final label = switch (item.title) {
            _otherChatsGroup => words(context, '其他聊天', 'Other chats'),
            _pinnedChatsSection => words(context, '置顶聊天', 'Pinned chats'),
            _recentChatsSection => words(context, '最近聊天', 'Recent chats'),
            _ => item.title,
          };
          if (!item.group) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            );
          }
          final collapsed =
              (model.presentation['collapsedProjects'] as Map? ??
                  {})[item.project] ==
              true;
          return ListTile(
            key: ValueKey('project-group-${item.project}'),
            dense: true,
            leading: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
            title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () {
              final states = Map<String, dynamic>.from(
                model.presentation['collapsedProjects'] as Map? ?? {},
              );
              states[item.project!] = !collapsed;
              model.setPresentation('collapsedProjects', states);
            },
          );
        }
        final row = item.session!;
        return Column(
          children: [
            SessionListTile(
              row: row,
              computerName: _computerName,
              selected: row.session == model.selected,
              read: model.isSessionRead(row.session),
              activity: model.sessionActivity(row.session),
              messageTime: model.lastMessageTime(row),
              updateTime: sessionUpdateTime(row, metadata[row.session]!),
              onTap: _canInteract ? () => model.openListedSession(row) : null,
              onMenu: _canInteract
                  ? () => sessionActions(context, model, row.session, row: row)
                  : null,
            ),
          ],
        );
      },
    );
  }

  Widget _disconnect(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: TextButton.icon(
      onPressed: model.busy
          ? null
          : () =>
                removeComputerDialog(context, model, model.computer!, strings),
      icon: const Icon(Icons.link_off, size: 16),
      label: Text(
        strings.t('Remove connection'),
        style: const TextStyle(fontSize: 11),
      ),
    ),
  );
}
