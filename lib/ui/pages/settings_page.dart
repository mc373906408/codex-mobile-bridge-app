import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../notifications/notification_controller.dart';
import '../../privacy/umeng_test_consent.dart';
import '../../viewmodels/bridge_view_model.dart';
import '../design/bridge_theme.dart';
import '../notification_settings.dart';
import '../umeng_test_consent.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.model,
    required this.strings,
    this.notifications,
    this.consent,
    required this.cloudAvailable,
    required this.onCloud,
    required this.onReviewConsent,
  });
  final BridgeViewModel model;
  final Strings strings;
  final NotificationController? notifications;
  final UmengTestConsentController? consent;
  final bool cloudAvailable;
  final VoidCallback onCloud, onReviewConsent;

  @override
  Widget build(BuildContext context) {
    final s = strings;
    return ListView(
      key: const PageStorageKey('settings-scroll'),
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        BridgePageTitle(
          s.t('Settings'),
          subtitle: s.t('Make yourself at home.'),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label(context, s.t('Appearance')),
                  BridgeSection(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              CupertinoIcons.paintbrush,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                s.t('Appearance'),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        CupertinoSlidingSegmentedControl<String>(
                          groupValue: model.theme,
                          padding: const EdgeInsets.all(4),
                          children: {
                            for (final mode in ['system', 'light', 'dark'])
                              mode: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                  horizontal: 4,
                                ),
                                child: Text(
                                  s.t(switch (mode) {
                                    'light' => 'Light',
                                    'dark' => 'Dark',
                                    _ => 'System theme',
                                  }),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                          },
                          onValueChanged: (value) {
                            if (value != null) {
                              model.setAppearance(theme: value);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  BridgeSection(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final code in ['zh', 'en'])
                          ListTile(
                            title: Text(code == 'zh' ? '简体中文' : 'English'),
                            leading: const Icon(CupertinoIcons.globe),
                            trailing: model.locale == code
                                ? const Icon(
                                    CupertinoIcons.check_mark,
                                    size: 20,
                                  )
                                : null,
                            onTap: () => model.setAppearance(locale: code),
                          ),
                      ],
                    ),
                  ),
                  if (cloudAvailable) ...[
                    _label(context, s.t('Account')),
                    BridgeSection(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        key: const Key('settings-cloud-service'),
                        leading: const Icon(CupertinoIcons.cloud),
                        title: Text(s.t('Cloud service')),
                        subtitle: Text(s.t('Account and server settings')),
                        trailing: const Icon(
                          CupertinoIcons.chevron_forward,
                          size: 16,
                        ),
                        onTap: onCloud,
                      ),
                    ),
                  ],
                  if (notifications != null) ...[
                    _label(context, s.t('Notifications')),
                    BridgeSection(
                      child: NotificationSettings(
                        controller: notifications!,
                        strings: s,
                      ),
                    ),
                  ],
                  if (consent != null) ...[
                    _label(context, s.t('Privacy')),
                    BridgeSection(
                      child: UmengTestConsentSettings(
                        controller: consent!,
                        strings: s,
                        onReview: onReviewConsent,
                      ),
                    ),
                  ],
                  _label(context, s.t('About')),
                  BridgeSection(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: const Icon(CupertinoIcons.doc_text),
                      title: Text(s.t('Open source licenses')),
                      trailing: const Icon(
                        CupertinoIcons.chevron_forward,
                        size: 16,
                      ),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: 'Bridge Mobile',
                        applicationVersion: const String.fromEnvironment(
                          'FLUTTER_BUILD_NAME',
                          defaultValue: '0.2.0',
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 20, 8, 12),
                    child: Text(
                      s.t(
                        'Cloud relay or local direct. Your desktop remains in control.',
                      ),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 24, 12, 10),
    child: Text(
      label,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}
