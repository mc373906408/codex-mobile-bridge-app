import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/strings.dart';
import 'design/bridge_theme.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key, required this.strings});

  final Strings strings;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: BridgeNavigationBar(title: Text(widget.strings.t('Scan QR'))),
    body: MobileScanner(
      onDetect: (capture) {
        final value = capture.barcodes
            .where((barcode) => barcode.rawValue != null)
            .firstOrNull
            ?.rawValue;
        if (_handled || value == null) return;
        _handled = true;
        Navigator.pop(context, value);
      },
      errorBuilder: (context, error) =>
          Center(child: Text(widget.strings.t('Camera unavailable'))),
    ),
  );
}
