import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app.dart';
import 'data/bridge_repository.dart';
import 'l10n/strings.dart';
import 'licenses.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  try {
    await RustLib.init();
    runApp(BridgeApp(repository: NativeBridgeRepository()));
  } catch (_) {
    runApp(const NativeStartupFailureApp());
  }
}

class NativeStartupFailureApp extends StatelessWidget {
  const NativeStartupFailureApp({super.key, this.locale = const Locale('zh')});
  final Locale locale;

  @override
  Widget build(BuildContext context) {
    final s = Strings(locale);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              '${s.t('Native core could not start')}\n'
              '${s.t('Restart the app. If it still cannot start, update it or contact support.')}',
            ),
          ),
        ),
      ),
    );
  }
}
