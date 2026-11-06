import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../l10n/strings.dart';
import '../../viewmodels/bridge_view_model.dart';
import '../dialogs.dart';
import '../provider_name.dart';

class SessionListPage extends StatelessWidget {
  const SessionListPage({
    super.key,
    required this.model,
    required this.strings,
  });
  final BridgeViewModel model;
  final Strings strings;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme, s = strings;
    final canInteract = model.authenticated && !model.busy;
    return RefreshIndicator(
      onRefresh: model.refreshSessions,
      notificationPredicate: (notification) =>
          model.authenticated &&
          defaultScrollNotificationPredicate(notification),
      child: CustomScrollView(
        key: PageStorageKey((
          'session-list',
          model.computer?.id,
          model.provider,
        )),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).top),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 22, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.t('Chats'),
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                      ),
                      IconButton(
                        onPressed: canInteract
                            ? () => newChatDialog(context, model, s)
                            : null,
                        tooltip: s.t('New chat'),
                        icon: const Icon(CupertinoIcons.square_pencil),
                      ),
                      IconButton(
                        onPressed: model.loading || !model.authenticated
                            ? null
                            : model.refreshSessions,
                        tooltip: s.t('Refresh'),
                        icon: const Icon(CupertinoIcons.arrow_clockwise),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: CupertinoSlidingSegmentedControl<Provider>(
                    groupValue: model.provider,
                    children: {
                      for (final provider in Provider.values)
                        provider: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 4,
                          ),
                          child: Text(
                            providerName(provider),
                            style: TextStyle(
                              fontSize: 13,
                              color: canInteract
                                  ? colors.onSurface
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    },
                    onValueChanged: (value) {
                      if (canInteract && value != null) {
                        model.selectProvider(value);
                      }
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    key: ValueKey(model.provider),
                    enabled: model.authenticated,
                    onChanged: model.search,
                    decoration: InputDecoration(
                      hintText: s.t('Search conversations'),
                      prefixIcon: const Icon(CupertinoIcons.search, size: 20),
                      isDense: true,
                    ),
                  ),
                ),
                if (model.notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      s.notice(model.notice!),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (model.pendingCreations.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: OutlinedButton.icon(
                      onPressed: canInteract
                          ? () => pendingCreationsDialog(context, model, s)
                          : null,
                      icon: const Icon(Icons.help_outline),
                      label: Text(
                        '${s.t('Pending verification')} (${model.pendingCreations.length})',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (model.sessions.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: model.loading
                    ? const SizedBox(height: 80)
                    : Column(
                        children: [
                          Icon(
                            CupertinoIcons.chat_bubble_2,
                            size: 36,
                            color: colors.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            s.t('No conversations yet'),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            s.t(
                              'Enable and configure this client on the computer first.',
                            ),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
              ),
            )
          else
            SliverList.builder(
              itemCount:
                  model.sessions.length + (model.nextOffset != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == model.sessions.length) {
                  return TextButton(
                    onPressed: model.loading || !model.authenticated
                        ? null
                        : () => model.refreshSessions(more: true),
                    child: Text(s.t('Load more')),
                  );
                }
                final row = model.sessions[index],
                    active = row.session == model.selected;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  child: ListTile(
                    selected: active,
                    tileColor: colors.surface,
                    selectedTileColor: colors.primaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    title: Text(
                      row.title.isEmpty ? row.session.id : row.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(
                        '${row.session.environment}  /  ${row.cwd.split(RegExp(r'[/\\]')).last}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: active ? colors.primary : colors.outline,
                      size: 18,
                    ),
                    onTap: canInteract
                        ? () => model.openSession(row.session)
                        : null,
                  ),
                );
              },
            ),
          if (model.computer?.connectionType == ConnectionType.direct)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextButton.icon(
                  onPressed: model.busy
                      ? null
                      : () => removeComputerDialog(
                          context,
                          model,
                          model.computer!,
                          s,
                        ),
                  icon: const Icon(Icons.link_off, size: 16),
                  label: Text(
                    s.t('Remove connection'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }
}
