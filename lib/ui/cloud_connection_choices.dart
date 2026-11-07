import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../l10n/strings.dart';

class CloudConnectionChoices extends StatelessWidget {
  const CloudConnectionChoices({
    super.key,
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
  static const _referenceTextSize = 14.0;
  static const _minimumRowWidth = 280.0;

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
      final textScale =
          MediaQuery.textScalerOf(context).scale(_referenceTextSize) /
          _referenceTextSize;
      if (constraints.maxWidth < _minimumRowWidth * textScale) {
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
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _description(context),
            Padding(padding: const EdgeInsets.only(top: 18), child: _action()),
          ],
        ),
      ),
    );
  }

  Widget _description(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
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
    );
  }

  Widget _action() {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    );
    return primary
        ? FilledButton(
            key: actionKey,
            style: style,
            onPressed: onAction,
            child: Text(actionLabel),
          )
        : OutlinedButton(
            key: actionKey,
            style: style,
            onPressed: onAction,
            child: Text(actionLabel),
          );
  }
}
