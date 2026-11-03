import 'package:flutter/material.dart';

import '../data/cloud_server.dart';
import '../l10n/strings.dart';
import '../notifications/cloud_notification_status.dart';
import '../notifications/cloud_push_bridge.dart';
import '../notifications/cloud_push_controller.dart';
import '../viewmodels/cloud_view_model.dart';

String cloudServerLabel(String origin, Strings strings) =>
    origin == officialCloudOrigin ? strings.t('Official cloud') : origin;

CloudNotificationStatus cloudNotificationStatus(
  CloudViewModel? cloud,
  CloudPushController? push,
) => CloudNotificationStatus(
  capabilities: cloud?.capabilities,
  state: push?.bridge.supported == true
      ? push!.state
      : const CloudPushState(supported: false),
  checked: push == null || !push.bridge.supported || push.checked,
  signedIn: cloud?.signedIn == true,
  hasComputer: cloud != null && cloud.bridge.computers.any(cloud.matches),
  serviceActive: switch (cloud?.serviceStatus) {
    CloudServiceStatus.active || CloudServiceStatus.selfHosted => true,
    CloudServiceStatus.unavailable => false,
    _ => null,
  },
  registered:
      cloud != null &&
      push != null &&
      cloud.bridge.computers.any(
        (computer) => cloud.matches(computer) && push.registeredFor(computer),
      ),
);

String cloudExpiry(BuildContext context, CloudViewModel cloud, Strings s) {
  final date = cloud.expiresAt?.toLocal();
  if (date == null) return s.t('Expiry not provided by the server');
  final localizations = MaterialLocalizations.of(context);
  return '${s.t('Valid until')} ${localizations.formatCompactDate(date)} '
      '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date), alwaysUse24HourFormat: true)}';
}

class CloudServiceStatusLabel extends StatelessWidget {
  const CloudServiceStatusLabel({
    super.key,
    required this.cloud,
    required this.strings,
    this.onDark = false,
  });
  final CloudViewModel cloud;
  final Strings strings;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final good =
        cloud.serviceStatus == CloudServiceStatus.active ||
        cloud.serviceStatus == CloudServiceStatus.selfHosted;
    final color = onDark
        ? (good ? const Color(0xFFABDFC5) : const Color(0xFFF1D9AA))
        : (good ? colors.primary : colors.onSurfaceVariant);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Icon(
            good ? Icons.verified_outlined : Icons.info_outline,
            size: 16,
            color: color,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            strings.t(cloud.serviceStatusText),
            key: const Key('cloud-service-status'),
            style: TextStyle(color: color),
          ),
        ),
      ],
    );
  }
}

class CloudNotificationSummary extends StatelessWidget {
  const CloudNotificationSummary({
    super.key,
    required this.cloud,
    required this.push,
    required this.strings,
  });
  final CloudViewModel? cloud;
  final CloudPushController? push;
  final Strings strings;

  @override
  Widget build(BuildContext context) {
    final status = cloudNotificationStatus(cloud, push);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.t('While the app can run'),
          style: theme.textTheme.labelMedium,
        ),
        const SizedBox(height: 4),
        Text(
          strings.t(status.directText),
          key: const Key('cloud-direct-notification-status'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Text(strings.t('Background push'), style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(
          strings.t(status.backgroundText),
          key: const Key('cloud-background-push-status'),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
