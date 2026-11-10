import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    final notice = await rootBundle.loadString('NOTICE');
    final license = await rootBundle.loadString('LICENSE');
    yield LicenseEntryWithLineBreaks(['Bridge Mobile'], '$notice\n\n$license');
    for (final name in ['ibmplexsans', 'ibmplexmono']) {
      yield LicenseEntryWithLineBreaks([
        'IBM Plex',
      ], await rootBundle.loadString('assets/fonts/$name-OFL.txt'));
    }
    final lgpl = await rootBundle.loadString(
      'third_party/bridge-p2p/licenses/EasyTier-LGPL-3.0.txt',
    );
    final gpl = await rootBundle.loadString(
      'third_party/bridge-p2p/licenses/GPL-3.0.txt',
    );
    yield LicenseEntryWithLineBreaks(['EasyTier 2.6.4'], '$lgpl\n\n$gpl');
  });
}
