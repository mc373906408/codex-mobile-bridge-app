import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';
import '../viewmodels/cloud_view_model.dart';
import 'dialogs.dart';
import 'rename_computer_dialog.dart';

class CloudHome extends StatelessWidget {
  const CloudHome({
    super.key,
    required this.model,
    required this.cloud,
    required this.strings,
    required this.onCloud,
    required this.onComputer,
  });
  final BridgeViewModel model;
  final CloudViewModel? cloud;
  final Strings strings;
  final VoidCallback onCloud;
  final ValueChanged<Computer> onComputer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled =
        model.initialized &&
        !model.busy &&
        model.foreground &&
        cloud?.busy != true;
    final computersById = {
      for (final computer in model.computers)
        if (computer.connectionType != ConnectionType.relay)
          computer.id: computer,
    };
    final currentCloud = cloud;
    // Keep offline identities stored; only current online cloud entries belong here.
    if (currentCloud != null && currentCloud.signedIn) {
      for (final state in currentCloud.devices) {
        if (((currentCloud.discoveryError == null &&
                    state.device.gateway.online) ||
                currentCloud.p2pConnected(state.computer)) &&
            currentCloud.matches(state.computer)) {
          computersById[state.computer.id] = state.computer;
        }
      }
    }
    final computers = computersById.values.toList();
    return DecoratedBox(
      decoration: BoxDecoration(color: theme.scaffoldBackgroundColor),
      child: RefreshIndicator(
        onRefresh: () => cloud?.refresh() ?? Future<void>.value(),
        child: SingleChildScrollView(
          key: const Key('cloud-home-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            strings.t('Computers'),
                            style: theme.textTheme.headlineLarge,
                          ),
                        ),
                        if (model.computers.isNotEmpty)
                          PopupMenuButton<String>(
                            key: const Key('saved-computers-menu'),
                            tooltip: strings.t('Saved computers'),
                            enabled: enabled,
                            icon: Icon(
                              CupertinoIcons.ellipsis_circle,
                              color: colors.primary,
                            ),
                            onSelected: (id) => onComputer(
                              model.computers.firstWhere(
                                (computer) => computer.id == id,
                              ),
                            ),
                            itemBuilder: (_) => [
                              for (final computer in model.computers)
                                PopupMenuItem(
                                  value: computer.id,
                                  child: Text(model.computerName(computer)),
                                ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      strings.t('Connect your computer'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _ConnectionChoices(
                      strings: strings,
                      cloudEnabled: cloud?.canManage == true,
                      directEnabled: enabled,
                      signedIn: cloud?.signedIn == true,
                      onCloud: onCloud,
                      onDirect: () => addComputerDialog(
                        context,
                        model,
                        strings,
                        cloud: cloud,
                        onCloud: onCloud,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _SectionTitle(
                      key: const Key('saved-computers-section'),
                      title: strings.t('Saved computers'),
                      count: computers.length,
                    ),
                    const SizedBox(height: 8),
                    if (computers.isEmpty)
                      _EmptyConnections(
                        icon: Icons.computer_rounded,
                        title: strings.t(
                          cloud?.signedIn == true
                              ? 'No online cloud computers'
                              : 'No computers yet',
                        ),
                        description: strings.t(
                          cloud?.signedIn == true
                              ? 'Offline cloud computers stay saved and reappear automatically when they reconnect.'
                              : 'Sign in to discover your cloud computers, or add a direct connection.',
                        ),
                      ),
                    if (cloud?.discoveryError case final error?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          strings.error(error),
                          key: const Key('cloud-discovery-error'),
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    for (final computer in computers)
                      _computerCard(context, computer, enabled),
                    if (computers.any(
                      (computer) =>
                          computer.connectionType == ConnectionType.direct,
                    )) ...[
                      const SizedBox(height: 12),
                      Text(
                        strings.t('Swipe left to remove a direct connection'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _computerCard(BuildContext context, Computer computer, bool enabled) {
    final colors = Theme.of(context).colorScheme;
    final isRelay = computer.connectionType == ConnectionType.relay;
    final state = cloud?.deviceState(computer);
    final card = Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(CupertinoIcons.desktopcomputer, color: colors.primary),
        title: Text(
          model.computerName(computer),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(
          strings.t(
            isRelay
                ? state?.device.gateway.online == true ||
                          cloud?.p2pConnected(computer) == true
                      ? 'Online'
                      : 'Offline'
                : model.computer?.id == computer.id && model.authenticated
                ? 'Connected'
                : 'Not connected',
          ),
          key: ValueKey('computer-status-${computer.id}'),
        ),
        trailing: PopupMenuButton<String>(
          key: ValueKey('computer-options-${computer.id}'),
          tooltip: strings.t('Computer options'),
          enabled: enabled && !model.renamingComputer,
          icon: const Icon(CupertinoIcons.ellipsis_circle),
          onSelected: (_) =>
              renameComputerDialog(context, model, computer, strings),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'rename',
              child: Text(strings.t('Rename computer')),
            ),
          ],
        ),
        onLongPress: enabled && !model.renamingComputer
            ? () => renameComputerDialog(context, model, computer, strings)
            : null,
        onTap: enabled ? () => onComputer(computer) : null,
      ),
    );
    if (isRelay) {
      return Semantics(
        key: ValueKey('computer-card-${computer.id}'),
        child: card,
      );
    }
    return Semantics(
      key: ValueKey('computer-card-${computer.id}'),
      onDismiss: enabled
          ? () => removeComputerDialog(context, model, computer, strings)
          : null,
      child: Dismissible(
        key: ValueKey('remove-computer-${computer.id}'),
        direction: enabled
            ? DismissDirection.endToStart
            : DismissDirection.none,
        confirmDismiss: (_) async {
          await removeComputerDialog(context, model, computer, strings);
          return false;
        },
        background: Container(
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: colors.errorContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline, color: colors.onErrorContainer),
              const SizedBox(width: 8),
              Text(
                strings.t('Remove'),
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ],
          ),
        ),
        child: card,
      ),
    );
  }
}

class _ConnectionChoices extends StatelessWidget {
  const _ConnectionChoices({
    required this.strings,
    required this.cloudEnabled,
    required this.directEnabled,
    required this.signedIn,
    required this.onCloud,
    required this.onDirect,
  });
  final Strings strings;
  final bool cloudEnabled, directEnabled, signedIn;
  final VoidCallback onCloud, onDirect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final cloud = _ConnectionOption(
        key: const Key('cloud-connection-option'),
        primary: true,
        icon: CupertinoIcons.cloud,
        title: strings.t('Cloud'),
        description: strings.t('Encrypted relay across networks.'),
        actionKey: const Key('cloud-primary-action'),
        actionLabel: strings.t(signedIn ? 'Open cloud' : 'Sign in'),
        onAction: cloudEnabled ? onCloud : null,
      );
      final direct = _ConnectionOption(
        key: const Key('direct-connection-option'),
        icon: CupertinoIcons.link,
        title: strings.t('Direct'),
        description: strings.t('LAN, VPN or HTTPS. No cloud account.'),
        actionKey: const Key('add-local-computer'),
        actionLabel: strings.t('Add direct'),
        onAction: directEnabled ? onDirect : null,
      );
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (constraints.maxWidth < 280 * textScale) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [cloud, const SizedBox(height: 12), direct],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: cloud),
            const SizedBox(width: 12),
            Expanded(child: direct),
          ],
        ),
      );
    },
  );
}

class _ConnectionOption extends StatelessWidget {
  const _ConnectionOption({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.actionKey,
    required this.actionLabel,
    required this.onAction,
    this.primary = false,
  });
  final IconData icon;
  final String title, description, actionLabel;
  final Key actionKey;
  final VoidCallback? onAction;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final buttonStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: colors.primary, size: 24),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: primary
                  ? FilledButton(
                      key: actionKey,
                      style: buttonStyle,
                      onPressed: onAction,
                      child: Text(actionLabel),
                    )
                  : OutlinedButton(
                      key: actionKey,
                      style: buttonStyle,
                      onPressed: onAction,
                      child: Text(actionLabel),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({super.key, required this.title, required this.count});
  final String title;
  final int count;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      const SizedBox(width: 8),
      Text(
        '$count',
        style: TextStyle(
          fontFamily: 'PlexMono',
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class _EmptyConnections extends StatelessWidget {
  const _EmptyConnections({
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title, description;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary, size: 22),
        const SizedBox(height: 10),
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(description, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
