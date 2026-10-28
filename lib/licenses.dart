import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final name in ['ibmplexsans', 'ibmplexmono']) {
      yield LicenseEntryWithLineBreaks([
        'IBM Plex',
      ], await rootBundle.loadString('assets/fonts/$name-OFL.txt'));
    }
  });
}
