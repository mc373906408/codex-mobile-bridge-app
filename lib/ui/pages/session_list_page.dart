import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../l10n/strings.dart';
import '../dialogs.dart';
import 'session_environment_notice.dart';
import 'session_list_header.dart';
import 'session_list_tile.dart';
import '../business/session_actions.dart';
import '../business/common.dart';

class SessionListPage extends StatelessWidget {
  const SessionListPage({
    super.key,
    required this.model,
    required this.strings,
    required this.onInbox,
    required this.onCancelConnection,
  });

  final BridgeViewModel model;
  final Strings strings;
  final VoidCallback onInbox;
  final VoidCallback onCancelConnection;

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
          _rows(),
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

  Widget _rows() {
    final rows = [...model.sessions]
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return model.groupByProject ? a.cwd.compareTo(b.cwd) : 0;
      });
    return SliverList.builder(
      itemCount: model.sessions.length + (model.nextOffset != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == model.sessions.length) {
          return TextButton(
            onPressed: model.loading || !model.authenticated
                ? null
                : () => model.refreshSessions(more: true),
            child: Text(strings.t('Load more')),
          );
        }
        final row = rows[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (model.groupByProject &&
                (index == 0 || rows[index - 1].cwd != row.cwd))
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  row.cwd.isEmpty
                      ? words(context, '其他聊天', 'Other chats')
                      : row.cwd,
                ),
              ),
            SessionListTile(
              row: row,
              computerName: _computerName,
              selected: row.session == model.selected,
              read: model.isSessionRead(row.session),
              onTap: _canInteract
                  ? () async {
                      await model.openSession(row.session);
                      if (model.selected == row.session && model.fresh) {
                        model.markSessionRead(row.session, true);
                      }
                    }
                  : null,
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
