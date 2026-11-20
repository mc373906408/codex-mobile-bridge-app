import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/bridge_types.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';
import '../viewmodels/cloud_view_model.dart';
import 'pairing_scan_page.dart';

class CloudConnectionDialog extends StatefulWidget {
  const CloudConnectionDialog({
    super.key,
    required this.model,
    required this.cloud,
    required this.strings,
    required this.computer,
  });

  final BridgeViewModel model;
  final CloudViewModel cloud;
  final Strings strings;
  final Computer computer;

  @override
  State<CloudConnectionDialog> createState() => _CloudConnectionDialogState();
}

class _CloudConnectionDialogState extends State<CloudConnectionDialog> {
  bool _working = false;
  bool _failed = false;
  String? _scannedBinding;
  bool _connectQueued = false;

  @override
  void initState() {
    super.initState();
    final computer = widget.computer;
    if (widget.cloud.deviceState(computer)?.device.status ==
        CloudDeviceStatus.unpaired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _request(computer);
      });
    }
  }

  Future<void> _run(Future<bool> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _failed = false;
    });
    final success = await action();
    if (!mounted) return;
    setState(() {
      _working = false;
      _failed = !success;
    });
  }

  Future<void> _request(Computer computer) => _run(() async {
    _scannedBinding = null;
    return widget.cloud.requestPairing(computer);
  });

  Future<void> _submitScan(Computer computer, String? payload) async {
    if (!mounted || payload == null) return;
    await _run(() async {
      final verified = await widget.cloud.scanPairing(computer, payload);
      if (verified) _scannedBinding = computer.id;
      return verified;
    });
  }

  Future<void> _scan(Computer computer) async {
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ScanPage(strings: widget.strings)),
    );
    await _submitScan(computer, payload);
  }

  Future<void> _connect(Computer computer) async {
    if (!mounted || _working || !widget.cloud.canConnect(computer)) return;
    setState(() => _working = true);
    await widget.model.selectPreparedRelay(computer);
    if (!mounted) return;
    if (widget.model.authenticated &&
        widget.model.computer?.id == computer.id) {
      Navigator.pop(context, true);
    } else {
      setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.cloud, widget.model]),
    builder: (context, _) {
      final cloud = widget.cloud;
      final s = widget.strings;
      final original = widget.computer;
      final state = !cloud.matches(original)
          ? null
          : cloud.devices.where((candidate) {
              final source = original.relay;
              final gateway = candidate.device.gateway;
              return gateway.id == source?.gatewayId &&
                  gateway.controlPublicKey == source?.desktopPublicKey;
            }).firstOrNull;
      final target = state?.computer;
      final pending = state?.device.status == CloudDeviceStatus.pending;
      final scanned = target != null && _scannedBinding == target.id;
      final canScan =
          pending &&
          state?.verified == true &&
          state?.device.gateway.online == true;
      final canRequest =
          state?.device.gateway.online == true &&
          (state?.device.status == CloudDeviceStatus.unpaired ||
              state?.needsRepair == true);
      final ready = target != null && cloud.canConnect(target);
      final enabled = !_working && cloud.canManage;
      if (ready && scanned && !_working && !_connectQueued) {
        _connectQueued = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _connect(target));
      }
      final status = switch (state?.device.status) {
        _ when _working => 'Preparing cloud connection…',
        CloudDeviceStatus.unpaired => 'Not paired',
        CloudDeviceStatus.pending when scanned =>
          'Waiting for desktop approval',
        CloudDeviceStatus.pending when canScan => 'Desktop pairing QR ready',
        CloudDeviceStatus.pending => 'Preparing encrypted pairing…',
        CloudDeviceStatus.active when state?.needsRepair == true =>
          'This connection needs to be paired again',
        CloudDeviceStatus.active when state?.device.accessAllowed != true =>
          'Desktop permission is enabled, but cloud access is unavailable',
        CloudDeviceStatus.active when state?.error != null =>
          'Desktop approval confirmed; encrypted identity verification failed',
        CloudDeviceStatus.active when state?.allowed != true =>
          'Desktop approval confirmed; verifying encrypted identity',
        CloudDeviceStatus.active => 'Connection allowed on desktop',
        CloudDeviceStatus.disabled => 'Connection disabled on this desktop',
        CloudDeviceStatus.revoked => 'Device permanently revoked',
        null => 'Cloud device status unavailable',
      };
      final computer = target ?? original;
      final error =
          (_failed ? cloud.operationError : null) ??
          state?.error ??
          cloud.discoveryError;
      return AlertDialog(
        key: const Key('cloud-device-info'),
        scrollable: true,
        title: Text(widget.model.computerName(computer)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t(status), key: const Key('cloud-device-permission')),
            if (state != null) ...[
              const SizedBox(height: 8),
              Text(s.t(state.device.gateway.online ? 'Online' : 'Offline')),
            ],
            if (error != null && (state?.needsRepair != true || _failed)) ...[
              const SizedBox(height: 12),
              Text(
                s.cloudError(error),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (canScan && !scanned && target != null)
              TextButton(
                key: const Key('paste-cloud-pairing-qr'),
                onPressed: !enabled
                    ? null
                    : () async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        await _submitScan(target, data?.text);
                      },
                child: Text(s.t('Paste pairing code')),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _working ? null : () => Navigator.pop(context, false),
            child: Text(s.t('Close')),
          ),
          if (canRequest && target != null)
            FilledButton(
              key: const Key('start-cloud-pairing'),
              onPressed: enabled ? () => _request(target) : null,
              child: Text(s.t(state!.needsRepair ? 'Pair again' : 'Connect')),
            ),
          if (canScan &&
              !scanned &&
              target != null &&
              (Platform.isAndroid || Platform.isIOS))
            FilledButton.icon(
              key: const Key('scan-cloud-pairing-qr'),
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: enabled ? () => _scan(target) : null,
              label: Text(s.t('Scan QR')),
            ),
          if (ready)
            FilledButton(
              key: const Key('connect-cloud-device'),
              onPressed: enabled ? () => _connect(target) : null,
              child: Text(s.t('Connect')),
            ),
        ],
      );
    },
  );
}
