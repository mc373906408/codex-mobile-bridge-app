import 'package:flutter/material.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';
import '../viewmodels/cloud_view_model.dart';
import 'cloud_status_widgets.dart';
import 'dialogs.dart';

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
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primaryContainer.withValues(alpha: .24),
            Theme.of(context).scaffoldBackgroundColor,
            colors.secondaryContainer.withValues(alpha: .18),
          ],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: () => cloud?.refresh() ?? Future<void>.value(),
        child: SingleChildScrollView(
          key: const Key('cloud-home-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      strings.t('Connect your computer'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      strings.t('Cloud or direct. Your choice.'),
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
                    const SizedBox(height: 20),
                    Text(
                      strings.t(
                        'Cloud relay or local direct. Your desktop remains in control.',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
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
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(
          isRelay ? Icons.cloud_outlined : Icons.computer_rounded,
          color: colors.primary,
        ),
        title: Text(computer.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.t(isRelay ? 'Cloud relay' : 'Local direct'),
              style: TextStyle(color: colors.primary),
            ),
            Text(
              cloudServerLabel(
                computer.relay?.origin ?? computer.baseUrl,
                strings,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (isRelay && cloud?.matches(computer) != true)
              Text(
                strings.t('Explicit server login required'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (isRelay && cloud?.matches(computer) == true) ...[
              Text(
                strings.t(
                  state?.device.status == CloudDeviceStatus.disabled
                      ? 'Connection disabled on this desktop'
                      : state?.device.status == CloudDeviceStatus.revoked
                      ? 'Device permanently revoked'
                      : state?.allowed == true
                      ? 'Connection allowed on desktop'
                      : 'Waiting for desktop permission',
                ),
                key: ValueKey('cloud-permission-${computer.id}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                strings.t(
                  state?.device.gateway.online == true ||
                          cloud?.p2pConnected(computer) == true
                      ? 'Online'
                      : 'Offline',
                ),
                key: ValueKey('cloud-online-${computer.id}'),
              ),
              if (cloud?.transports[computer.id]?.connected == true)
                Text(
                  strings.t(
                    cloud?.p2pConnected(computer) == true
                        ? 'P2P direct'
                        : 'Cloud relay',
                  ),
                ),
            ],
          ],
        ),
        trailing: Icon(
          isRelay && cloud?.canConnect(computer) != true
              ? Icons.info_outline
              : Icons.arrow_forward_rounded,
        ),
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
        icon: Icons.cloud_outlined,
        title: strings.t('Cloud'),
        description: strings.t('Encrypted relay across networks.'),
        actionKey: const Key('cloud-primary-action'),
        actionLabel: strings.t(signedIn ? 'Open cloud' : 'Sign in'),
        onAction: cloudEnabled ? onCloud : null,
      );
      final direct = _ConnectionOption(
        key: const Key('direct-connection-option'),
        icon: Icons.computer_rounded,
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
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(44)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: primary
          ? colors.primaryContainer.withValues(alpha: .65)
          : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: primary
              ? colors.primary.withValues(alpha: .3)
              : colors.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: colors.primary, size: 24),
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
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(16),
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
