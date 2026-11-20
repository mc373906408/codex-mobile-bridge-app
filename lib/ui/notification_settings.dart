import 'package:flutter/material.dart';

import '../data/bridge_types.dart';
import '../l10n/strings.dart';
import '../notifications/cloud_push_controller.dart';
import '../notifications/notification_controller.dart';
import '../viewmodels/bridge_view_model.dart';
import '../viewmodels/cloud_view_model.dart';
import 'cloud_status_widgets.dart';

class NotificationSettings extends StatelessWidget {
  const NotificationSettings({
    super.key,
    required this.controller,
    required this.model,
    required this.computers,
    required this.strings,
    this.cloudPush,
    this.cloud,
  });
  final NotificationController controller;
  final BridgeViewModel model;
  final List<Computer> computers;
  final Strings strings;
  final CloudPushController? cloudPush;
  final CloudViewModel? cloud;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, model, ?cloudPush]),
    builder: (context, _) {
      final s = strings;
      final style = Theme.of(context).textTheme;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const Key('notifications-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('All computer notifications')),
            subtitle: Text(
              s.t(
                'Receive notifications from saved computers and the active cloud account.',
              ),
            ),
            value: model.notificationsEnabled,
            onChanged: controller.busy ? null : model.setNotificationsEnabled,
          ),
          for (final computer in computers)
            SwitchListTile(
              key: ValueKey('computer-notification-${computer.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(model.computerName(computer)),
              subtitle: Text(
                s.t(
                  computer.connectionType == ConnectionType.relay
                      ? 'Cloud computer'
                      : 'Direct gateway',
                ),
              ),
              value: model.computerNotificationsEnabled(computer),
              onChanged: controller.busy
                  ? null
                  : (enabled) => model.setComputerNotificationsEnabled(
                      computer,
                      enabled,
                    ),
            ),
          const SizedBox(height: 8),
          Text(
            s.t(
              controller.state.supported &&
                      controller.bridge.backgroundListening
                  ? 'Allow system notifications for alerts while Bridge is in the background.'
                  : 'The inbox checks online computers while Bridge is open. Background alerts depend on the cloud push service.',
            ),
            style: style.bodyMedium,
          ),
          const SizedBox(height: 8),
          if (controller.state.supported) ...[
            Text(
              s.t(
                controller.state.allowed
                    ? 'System notifications allowed'
                    : 'System notification permission is required',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${s.t(controller.statusText)}${controller.checked ? ' (${controller.online}/${controller.total})' : ''}',
              key: const Key('notification-status'),
              style: style.bodyMedium,
            ),
            const SizedBox(height: 8),
            if (controller.bridge.backgroundListening)
              Text(
                s.t(
                  'Direct gateway listening uses an ongoing notification and additional battery. No Google services required. Force-stop, lost connectivity or battery restrictions can interrupt delivery.',
                ),
                style: style.bodySmall,
              ),
            if (controller.bridge.backgroundListening &&
                controller.state.batteryOptimized) ...[
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
                  icon: const Icon(
                    Icons.notifications_active_outlined,
                    size: 18,
                  ),
                  label: Text(s.t('Send test notification')),
                ),
                TextButton(
                  onPressed: () => controller.openSettings(),
                  child: Text(s.t('Notification permissions')),
                ),
                if (controller.bridge.backgroundListening)
                  TextButton(
                    onPressed: () => controller.openSettings(battery: true),
                    child: Text(s.t('Battery settings')),
                  ),
              ],
            ),
          ],
          if (cloudPush case final push?) ...[
            const SizedBox(height: 8),
            CloudNotificationSummary(cloud: cloud, push: push, strings: s),
          ],
          if (cloudPush?.message case final feedback?) Text(s.t(feedback)),
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
