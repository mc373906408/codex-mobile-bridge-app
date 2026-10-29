import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../privacy/umeng_test_consent.dart';

Future<void> showUmengTestConsentDialog({
  required BuildContext context,
  required UmengTestConsentController controller,
  required Strings strings,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) =>
      _ConsentDialog(controller: controller, strings: strings),
);

class _ConsentDialog extends StatelessWidget {
  const _ConsentDialog({required this.controller, required this.strings});
  final UmengTestConsentController controller;
  final Strings strings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final s = strings;
      final theme = Theme.of(context);
      final media = MediaQuery.of(context);
      final disabled = controller.busy || !controller.state.interactive;
      Future<void> choose(bool accept) async {
        if (await controller.decide(accept: accept) && context.mounted) {
          Navigator.of(context).pop();
        }
      }

      final actions = [
        OutlinedButton(
          key: const Key('umeng-consent-decline'),
          onPressed: disabled ? null : () => choose(false),
          child: Text(s.t('Not now; keep direct notifications')),
        ),
        FilledButton(
          key: const Key('umeng-consent-accept'),
          onPressed: disabled ? null : () => choose(true),
          child: Text(s.t('Agree to this device test only')),
        ),
      ];
      // AlertDialog only scrolls its title/content, not its separate action bar.
      final scrollActions =
          media.textScaler.scale(14) > 21 ||
          media.size.height - media.viewInsets.vertical < 480;

      return PopScope(
        canPop: !controller.busy,
        child: AlertDialog(
          key: const Key('umeng-test-consent-dialog'),
          scrollable: true,
          icon: Icon(
            Icons.privacy_tip_outlined,
            color: theme.colorScheme.primary,
          ),
          title: Text(s.t('Lenovo test: U-Push consent')),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  s.t(
                    'Lenovo debug builds only. Not a production privacy policy.',
                  ),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(s.t('Why this test'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                s.t(
                  'This test enables U-Push registration and manual console notifications on your Lenovo device. Gateway-triggered fallback delivery is not connected yet.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.t('What the push service may process'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                s.t(
                  'Umeng and its Alibaba transport may process device identifiers (such as Android ID or OAID), device and app information, network information, and notification delivery records.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.t('What stays with your gateway'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                s.t(
                  'This integration does not upload chat text, attachments, gateway addresses, or login credentials. Test notifications show generic text and only open Bridge.',
                ),
              ),
              const SizedBox(height: 16),
              Text(s.t('Your choice'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                s.t(
                  'Declining keeps direct notifications and all chat features available. Your choice is stored on this phone. Withdrawal blocks test notifications and requests push disabling; it does not erase uploaded metadata or guarantee all vendor background work stops before an app restart. A changed disclosure needs fresh consent.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.t(
                  'Agreeing now initializes and registers U-Push. Shared analytics and crash collection are disabled. Real notification delivery is not yet verified.',
                ),
                style: theme.textTheme.bodySmall,
              ),
              TextButton.icon(
                key: const Key('umeng-privacy-details'),
                onPressed: disabled ? null : controller.openPrivacyDetails,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(s.t('Official Umeng privacy guidance')),
              ),
              if (controller.message case final message?)
                Text(
                  s.t(message),
                  key: const Key('umeng-consent-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              if (scrollActions) ...[
                const SizedBox(height: 16),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  overflowSpacing: 8,
                  children: actions,
                ),
              ],
            ],
          ),
          actions: scrollActions ? null : actions,
        ),
      );
    },
  );
}

class UmengTestConsentSettings extends StatelessWidget {
  const UmengTestConsentSettings({
    super.key,
    required this.controller,
    required this.strings,
    required this.onReview,
  });

  final UmengTestConsentController controller;
  final Strings strings;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.state.eligible) return const SizedBox.shrink();
      final s = strings;
      final disabled = controller.busy || !controller.state.interactive;
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.t('U-Push test privacy'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              s.t(controller.state.statusMessage),
              key: const Key('umeng-push-status'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  key: const Key('umeng-consent-review'),
                  onPressed: disabled ? null : onReview,
                  child: Text(s.t('Review test disclosure')),
                ),
                if (controller.state.accepted &&
                    controller.state.hasDeviceToken)
                  OutlinedButton.icon(
                    key: const Key('umeng-copy-token'),
                    onPressed: disabled || !controller.state.canCopyToken
                        ? null
                        : controller.copyPushToken,
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(s.t('Copy test device token')),
                  ),
                if (controller.state.accepted)
                  TextButton(
                    key: const Key('umeng-consent-withdraw'),
                    onPressed: disabled
                        ? null
                        : () => controller.decide(accept: false),
                    child: Text(s.t('Withdraw test consent')),
                  ),
              ],
            ),
            if (controller.message case final message?) Text(s.t(message)),
          ],
        ),
      );
    },
  );
}
