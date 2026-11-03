import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/ui/cloud_status_widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    final strings = Strings(Locale(locale));

    test('official server uses its localized name in $locale', () {
      expect(
        cloudServerLabel(officialCloudOrigin, strings),
        strings.t('Official cloud'),
      );
    });

    test('self-hosted addresses remain exact in $locale', () {
      const origin = 'https://private.example:8787';
      expect(cloudServerLabel(origin, strings), origin);
    });

    test('another endpoint never receives the official label in $locale', () {
      final origin = officialCloudOrigin.replaceFirst(':8787', ':8788');
      expect(cloudServerLabel(origin, strings), origin);
    });
  }
}
