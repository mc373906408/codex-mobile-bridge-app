import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../notifications/notification_controller.dart';

class NotificationSettings extends StatelessWidget {
  const NotificationSettings({
    super.key,
    required this.controller,
    required this.strings,
  });
  final NotificationController controller;
  final Strings strings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.state.supported) return const SizedBox.shrink();
      final s = strings;
      final style = Theme.of(context).textTheme;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.t('Android notifications'), style: style.titleLarge),
          const SizedBox(height: 8),
          Text(
            s.t(
              'Task notifications are automatic. Allow Android notifications to receive alerts.',
            ),
            style: style.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '${s.t(controller.statusText)}${controller.checked && controller.state.allowed && controller.state.running ? ' (${controller.online}/${controller.total})' : ''}',
            key: const Key('notification-status'),
            style: style.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            s.t(
              'Direct gateway listening uses an ongoing notification and additional battery. No Google services required. Force-stop, lost connectivity or battery restrictions can interrupt delivery.',
            ),
            style: style.bodySmall,
          ),
          if (controller.state.batteryOptimized) ...[
            const SizedBox(height: 8),
            Text(
              s.t(
                'For more reliable alerts, allow Bridge to run in the background in Android battery settings.',
              ),
              style: style.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('test-notification'),
                onPressed: controller.busy ? null : controller.sendTest,
                icon: const Icon(Icons.notifications_active_outlined, size: 18),
                label: Text(s.t('Send test notification')),
              ),
              TextButton(
                onPressed: () => controller.openSettings(),
                child: Text(s.t('Notification permissions')),
              ),
              TextButton(
                onPressed: () => controller.openSettings(battery: true),
                child: Text(s.t('Battery settings')),
              ),
            ],
          ),
          if (controller.message case final message?)
            Text(
              s.t(message),
              key: const Key('notification-feedback'),
              style: style.bodySmall,
            ),
        ],
      );
    },
  );
}
