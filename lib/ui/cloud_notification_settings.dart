import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../notifications/cloud_push_controller.dart';

class CloudNotificationSettings extends StatelessWidget {
  const CloudNotificationSettings({
    super.key,
    required this.controller,
    required this.strings,
  });
  final CloudPushController controller;
  final Strings strings;

  Future<void> _enable(BuildContext context) async {
    final version = controller.state.noticeVersion;
    final vendor = version == 'cloud-umeng-push-v1';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.t('Private cloud notifications')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                strings.t(
                  'Your approved desktop encrypts previews with separate notification keys. The cloud can see account, device, timing and traffic metadata, but not preview text.',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                strings.t(
                  vendor
                      ? 'This build uses Umeng U-Push. After consent, Umeng receives a device token, delivery metadata and ciphertext. Analytics and advertising collection are disabled. Previous Lenovo test consent does not apply.'
                      : 'Remote delivery, when configured, uses the platform push service. SDK-free builds receive only authenticated direct cloud updates while the app can run.',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                strings.t(
                  'Missing keys, a locked device or extension timeout may show only a generic alert. Delivery is not guaranteed. Turning this off stops local previews and requests endpoint removal when the server is reachable; it does not stop desktop tasks or direct connections.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.t('Not now')),
          ),
          FilledButton(
            key: const Key('accept-cloud-notifications'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.t('Allow encrypted notifications')),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.setConsent(true, version);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.bridge.supported) return const SizedBox.shrink();
      final s = strings;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.t('Cloud task notifications'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          SwitchListTile.adaptive(
            key: const Key('cloud-notification-consent'),
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('Private cloud notifications')),
            subtitle: Text(s.t(controller.statusText)),
            value: controller.state.consent,
            onChanged: controller.busy || !controller.state.interactive
                ? null
                : (enabled) {
                    if (enabled) {
                      _enable(context);
                    } else {
                      controller.setConsent(
                        false,
                        controller.state.noticeVersion,
                      );
                    }
                  },
          ),
          if (controller.state.consent && !controller.state.allowed)
            OutlinedButton(
              key: const Key('cloud-notification-permission'),
              onPressed: controller.busy ? null : controller.requestPermission,
              child: Text(s.t('Notification permissions')),
            ),
          if (controller.message case final message?)
            Text(s.t(message), style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    },
  );
}
