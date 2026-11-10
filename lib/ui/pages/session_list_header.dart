import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../l10n/strings.dart';
import '../design/bridge_theme.dart';
import '../dialogs.dart';
import '../provider_name.dart';
import '../business/common.dart';

class SessionListHeader extends StatelessWidget {
  const SessionListHeader({
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
  static const _referenceTextSize = 16.0;
  static const _inlineTextLimit = 20.0;

  bool get _canInteract =>
      model.authenticated && !model.busy && model.foreground;

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('session-list-header'),
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _topBar(context),
        const SizedBox(height: 12),
        _search(context),
      ],
    ),
  );

  Widget _topBar(BuildContext context) {
    final picker = _providerPicker(context, _canInteract);
    final actions = _actions(context);
    final largeText =
        MediaQuery.textScalerOf(context).scale(_referenceTextSize) >
        _inlineTextLimit;
    if (largeText) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: Alignment.centerLeft, child: picker),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: actions),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [picker, const SizedBox(width: 12), actions],
    );
  }

  Widget _actions(BuildContext context) {
    final s = strings;
    return BridgeGlass(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (model.authenticated)
            IconButton(
              tooltip: s.t('Inbox'),
              onPressed: onInbox,
              icon: Badge(
                isLabelVisible: model.unreadCount > 0,
                label: Text('${model.unreadCount}'),
                child: const Icon(CupertinoIcons.tray),
              ),
            ),
          IconButton(
            onPressed: _canInteract
                ? () => newChatDialog(context, model, s)
                : null,
            tooltip: s.t('New chat'),
            icon: const Icon(CupertinoIcons.square_pencil),
          ),
          IconButton(
            onPressed: model.loading || !_canInteract
                ? null
                : model.refreshSessions,
            tooltip: s.t('Refresh'),
            icon: const Icon(CupertinoIcons.arrow_clockwise),
          ),
          if (model.loading && !model.authenticated)
            IconButton(
              key: const Key('cancel-connection'),
              tooltip: s.t('Cancel connection'),
              onPressed: model.busy ? null : onCancelConnection,
              icon: const Icon(CupertinoIcons.xmark, size: 18),
            ),
        ],
      ),
    );
  }

  Widget _search(BuildContext context) => TextFormField(
    key: ValueKey((
      'session-search',
      model.computer?.id,
      model.provider,
      model.entry,
    )),
    initialValue: model.query,
    enabled: model.authenticated,
    onChanged: model.search,
    style: Theme.of(context).textTheme.bodyMedium,
    decoration: InputDecoration(
      hintText: strings.t('Search chats'),
      prefixIcon: const Icon(CupertinoIcons.search, size: 18),
      prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 48),
      suffixIcon: PopupMenuButton<String>(
        key: const Key('session-filters'),
        enabled: _canInteract,
        tooltip: words(context, '筛选与分组', 'Filter & group'),
        icon: Badge(
          isLabelVisible:
              model.archived || model.source != 'all' || model.groupByProject,
          child: const Icon(Icons.filter_list),
        ),
        onSelected: (value) {
          if (!_canInteract) return;
          if (value == 'archived') {
            model.filterSessions(archived: !model.archived);
          } else if (value == 'group') {
            model.setPresentation('groupByProject', !model.groupByProject);
          } else {
            model.filterSessions(source: value.substring(7));
          }
        },
        itemBuilder: (_) => [
          CheckedPopupMenuItem(
            value: 'archived',
            checked: model.archived,
            child: Text(words(context, '已归档', 'Archived')),
          ),
          CheckedPopupMenuItem(
            value: 'group',
            checked: model.groupByProject,
            child: Text(words(context, '按项目分组', 'Group by project')),
          ),
          const PopupMenuDivider(),
          for (final source in {'all', ...model.availableSources})
            CheckedPopupMenuItem(
              value: 'source:$source',
              checked: model.source == source,
              child: Text(
                source == 'all'
                    ? words(context, '全部来源', 'All sources')
                    : source,
              ),
            ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      isDense: true,
    ),
  );

  Widget _providerPicker(BuildContext context, bool enabled) {
    final theme = Theme.of(context);
    final clients = model.clients.isNotEmpty
        ? model.clients
        : Provider.values
              .map(
                (p) => ClientInfo(
                  provider: p,
                  enabled: true,
                  connected: false,
                  readable: true,
                  reason: '',
                ),
              )
              .toList();
    return PopupMenuButton<ClientInfo>(
      key: const Key('provider-picker'),
      tooltip: strings.t('Switch agent'),
      enabled: enabled,
      useRootNavigator: true,
      requestFocus: true,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 8),
      color: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: .12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outlineVariant, width: .5),
      ),
      popUpAnimationStyle: AnimationStyle(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        reverseDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 120),
      ),
      itemBuilder: (context) => [
        for (final client in clients)
          CheckedPopupMenuItem<ClientInfo>(
            key: ValueKey(
              'provider-option-${client.provider.name}${client.entry.isEmpty ? '' : '-${client.entry}'}',
            ),
            value: client,
            checked:
                model.provider == client.provider &&
                model.entry == client.entry,
            height: 52,
            child: Text(
              client.name.isEmpty ? providerName(client.provider) : client.name,
            ),
          ),
      ],
      onSelected: (client) {
        if (model.authenticated && !model.busy && model.foreground) {
          model.selectClient(client);
        }
      },
      child: _providerLabel(context, enabled),
    );
  }

  Widget _providerLabel(BuildContext context, bool enabled) {
    final theme = Theme.of(context);
    return BridgeGlass(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              model.clients
                          .where(
                            (c) =>
                                c.provider == model.provider &&
                                c.entry == model.entry,
                          )
                          .firstOrNull
                          ?.name
                          .isNotEmpty ==
                      true
                  ? model.clients
                        .firstWhere(
                          (c) =>
                              c.provider == model.provider &&
                              c.entry == model.entry,
                        )
                        .name
                  : providerName(model.provider),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: enabled
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              CupertinoIcons.chevron_down,
              size: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
