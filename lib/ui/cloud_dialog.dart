import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../data/bridge_types.dart';
import '../viewmodels/bridge_view_model.dart';
import '../viewmodels/cloud_view_model.dart';
import 'cloud_status_widgets.dart';

class CloudConnectionDialog extends StatelessWidget {
  const CloudConnectionDialog({
    super.key,
    required this.model,
    required this.cloud,
    required this.strings,
    this.computer,
  });
  final BridgeViewModel model;
  final CloudViewModel cloud;
  final Strings strings;
  final Computer? computer;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([cloud, model]),
    builder: (context, _) {
      final target = computer ?? cloud.devices.firstOrNull?.computer;
      final state = target == null ? null : cloud.deviceState(target);
      final s = strings;
      final code = state?.pairing?.safetyCode ?? '';
      return AlertDialog(
        key: const Key('cloud-device-info'),
        scrollable: true,
        title: Text(
          target == null ? s.t('Cloud device') : model.computerName(target),
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(cloud.account?.login ?? s.t('Not signed in')),
              const SizedBox(height: 4),
              SelectableText(cloudServerLabel(cloud.origin, s)),
              const SizedBox(height: 16),
              Text(
                s.t(
                  state?.device.status == CloudDeviceStatus.disabled
                      ? 'Connection disabled on this desktop'
                      : state?.device.status == CloudDeviceStatus.revoked
                      ? 'Device permanently revoked'
                      : state?.allowed == true
                      ? 'Connection allowed on desktop'
                      : 'Waiting for desktop permission',
                ),
                key: const Key('cloud-device-permission'),
              ),
              const SizedBox(height: 8),
              Text(
                s.t(
                  state?.device.gateway.online == true ? 'Online' : 'Offline',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.t(
                  'Phones and computers on the same account are discovered automatically. Enable Allow Connection on the desktop; signing in never grants access.',
                ),
              ),
              if (code.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(s.t('Safety code')),
                SelectableText(
                  code,
                  key: const Key('cloud-pairing-safety-code'),
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontFamily: 'PlexMono'),
                ),
                const SizedBox(height: 8),
                Text(
                  s.t(
                    'Compare this safety code with the desktop before allowing the first connection.',
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Text(
                  s.t(
                    'Keep both devices online for the first encrypted identity check.',
                  ),
                ),
              ],
              if (target?.relay case final relay?) ...[
                const SizedBox(height: 16),
                Text(s.t('Desktop identity')),
                SelectableText(
                  relay.desktopPublicKey,
                  key: const Key('cloud-desktop-public-key'),
                ),
              ],
              if (state?.error ?? cloud.discoveryError case final error?) ...[
                const SizedBox(height: 12),
                Text(
                  s.error(error),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.t('Close')),
          ),
          if (target != null && cloud.canConnect(target))
            FilledButton(
              key: const Key('connect-cloud-device'),
              onPressed: model.busy || model.loading
                  ? null
                  : () async {
                      await model.selectPreparedRelay(target);
                      if (context.mounted && model.authenticated) {
                        Navigator.pop(context, true);
                      }
                    },
              child: Text(s.t('Connect')),
            ),
        ],
      );
    },
  );
}
