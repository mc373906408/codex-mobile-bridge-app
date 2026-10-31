import 'dart:io';

import 'package:flutter/material.dart';

import '../data/bridge_repository.dart';
import '../data/cloud_accounts.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';

class CloudConnectionDialog extends StatefulWidget {
  const CloudConnectionDialog({
    super.key,
    required this.model,
    required this.strings,
    required this.scan,
    this.reconnect,
    this.invitation,
  });
  final BridgeViewModel model;
  final Strings strings;
  final Future<String?> Function(BuildContext) scan;
  final Computer? reconnect;
  final String? invitation;
  @override
  State<CloudConnectionDialog> createState() => _CloudConnectionDialogState();
}

class _CloudConnectionDialogState extends State<CloudConnectionDialog> {
  final _origin = TextEditingController(), _login = TextEditingController();
  final _password = TextEditingController(), _name = TextEditingController();
  final _invitation = TextEditingController();
  List<CloudAccountRef> _accounts = [];
  CloudAccountRef? _account;
  CloudCapabilities? _capabilities;
  CloudEntitlement? _entitlement;
  PreparedRelay? _prepared;
  bool _busy = false;
  Object? _error;
  CloudRepository get _repository => widget.model.repository as CloudRepository;

  @override
  void initState() {
    super.initState();
    _origin.text = widget.reconnect?.relay?.origin ?? '';
    _invitation.text = widget.invitation ?? '';
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await _repository.cloudAccounts.accounts();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        final relay = widget.reconnect?.relay;
        _account = accounts
            .where(
              (value) =>
                  value.origin == relay?.origin &&
                  value.accountId == relay?.accountId &&
                  value.enabled,
            )
            .firstOrNull;
        if (_account case final account?) _login.text = account.login;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _password.clear();
    _invitation.clear();
    for (final controller in [_origin, _login, _password, _name, _invitation]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _work(Future<void> Function() work) async {
    if (_busy || widget.model.busy || !widget.model.foreground) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() => _work(() async {
    final origin = _repository.cloudAccounts.canonicalOrigin(_origin.text);
    final capabilities = await _repository.cloudAccounts.capabilities(origin);
    if (mounted) setState(() => _capabilities = capabilities);
  });

  Future<void> _signIn() => _work(() async {
    try {
      final origin = _repository.cloudAccounts.canonicalOrigin(_origin.text);
      final account = await _repository.cloudAccounts.signIn(
        origin,
        _login.text,
        _password.text,
      );
      final entitlement = await _repository.cloudAccounts.entitlement(account);
      if (mounted) {
        setState(() {
          _account = account;
          _entitlement = entitlement;
        });
      }
      await _loadAccounts();
      // _loadAccounts selects only a reconnect identity; retain the explicit login otherwise.
      if (mounted) setState(() => _account = account);
    } finally {
      _password.clear();
    }
  });

  Future<void> _checkEntitlement() => _work(() async {
    final account = _account;
    if (account == null || account.origin != _origin.text) {
      throw StateError('Select a cloud account first');
    }
    final entitlement = await _repository.cloudAccounts.entitlement(account);
    if (mounted) setState(() => _entitlement = entitlement);
  });

  Future<void> _signOut() => _work(() async {
    final account = _account;
    if (account == null) return;
    // The local account/preview is disabled before the best-effort server logout.
    try {
      await _repository.cloudAccounts.signOut(account);
    } finally {
      if (mounted) {
        setState(() {
          _account = null;
          _entitlement = null;
        });
      }
      await _loadAccounts();
    }
  });

  Future<void> _prepare() => _work(() async {
    final account = _account;
    if (account == null || account.origin != _origin.text) {
      throw StateError('Select a cloud account first');
    }
    final prepared = await _repository.prepareRelay(
      account,
      _invitation.text,
      _name.text.trim().isEmpty ? 'Cloud computer' : _name.text.trim(),
    );
    if (mounted) setState(() => _prepared = prepared);
  });

  Future<void> _confirm() => _work(() async {
    final prepared = _prepared!;
    final status = await _repository.confirmRelay(
      prepared.computer,
      _invitation.text,
    );
    if (!status.authenticated) throw StateError('Desktop approval is required');
    await widget.model.selectPreparedRelay(prepared.computer);
    if (mounted) Navigator.pop(context, true);
  });

  Future<void> _reconnect() => _work(() async {
    await widget.model.selectPreparedRelay(widget.reconnect!);
    if (mounted && widget.model.authenticated) Navigator.pop(context, true);
  });

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    final fieldsEnabled = !_busy && _prepared == null;
    final matching = _accounts
        .where((value) => value.origin == _origin.text && value.enabled)
        .toList();
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(s.t('Cloud relay')),
        scrollable: true,
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.t(
                  'Choose the cloud server explicitly. A QR code never changes the selected account or server.',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _origin,
                readOnly: widget.reconnect != null,
                enabled: fieldsEnabled,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: s.t('Cloud server origin'),
                  hintText: 'https://relay.example',
                ),
                onChanged: (_) => setState(() {
                  _account = null;
                  _capabilities = null;
                  _entitlement = null;
                }),
              ),
              TextButton(
                onPressed: fieldsEnabled ? _check : null,
                child: Text(s.t('Check server capabilities')),
              ),
              if (_capabilities case final capabilities?)
                Text('${capabilities.mode} / ${capabilities.login}'),
              if (matching.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'cloud-accounts-${_origin.text}-${_account?.scope}',
                  ),
                  initialValue:
                      matching.any((value) => value.scope == _account?.scope)
                      ? _account?.scope
                      : null,
                  decoration: InputDecoration(
                    labelText: s.t('Saved cloud account'),
                  ),
                  items: matching
                      .map(
                        (value) => DropdownMenuItem(
                          value: value.scope,
                          child: Text(value.login),
                        ),
                      )
                      .toList(),
                  onChanged: fieldsEnabled
                      ? (scope) => setState(() {
                          _account = matching.firstWhere(
                            (value) => value.scope == scope,
                          );
                          _entitlement = null;
                        })
                      : null,
                ),
              TextField(
                controller: _login,
                enabled: fieldsEnabled,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 320,
                decoration: InputDecoration(labelText: s.t('Cloud account')),
              ),
              TextField(
                controller: _password,
                enabled: fieldsEnabled,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 1024,
                decoration: InputDecoration(labelText: s.t('Password')),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: fieldsEnabled ? _signIn : null,
                    child: Text(s.t('Sign in')),
                  ),
                  TextButton(
                    onPressed: fieldsEnabled && _account != null
                        ? _checkEntitlement
                        : null,
                    child: Text(s.t('Service status')),
                  ),
                  TextButton(
                    onPressed: fieldsEnabled && _account != null
                        ? _signOut
                        : null,
                    child: Text(s.t('Sign out')),
                  ),
                ],
              ),
              if (_entitlement case final entitlement?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    entitlement.required_
                        ? '${s.t(entitlement.active ? 'Service active' : 'Service unavailable')}${entitlement.expiresAt == null ? '' : ' / ${entitlement.expiresAt}'}'
                        : s.t('Self-hosted service'),
                  ),
                ),
              if (widget.reconnect == null) ...[
                const Divider(height: 28),
                TextField(
                  controller: _name,
                  enabled: fieldsEnabled,
                  maxLength: 80,
                  decoration: InputDecoration(labelText: s.t('Computer name')),
                ),
                TextField(
                  controller: _invitation,
                  enabled: fieldsEnabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 4096,
                  decoration: InputDecoration(
                    labelText: s.t('Five-minute desktop pairing QR'),
                  ),
                ),
                TextButton.icon(
                  onPressed:
                      fieldsEnabled && (Platform.isAndroid || Platform.isIOS)
                      ? () async {
                          final value = await widget.scan(context);
                          if (mounted && value != null) {
                            _invitation.text = value;
                          }
                        }
                      : null,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(s.t('Scan QR')),
                ),
              ],
              if (_prepared case final prepared?) ...[
                const Divider(height: 28),
                Text(
                  s.t(
                    'Compare these keys with the desktop candidate. Approve only on the desktop.',
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '${s.t('Desktop control key')}:\n${prepared.computer.relay!.desktopPublicKey}',
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '${s.t('Phone control key')}:\n${prepared.mobileControlPublicKey}',
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '${s.t('Phone preview key')}:\n${prepared.mobilePreviewPublicKey}',
                ),
              ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    s.error(_error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(s.t('Close')),
          ),
          if (widget.reconnect != null)
            FilledButton(
              onPressed: !_busy && _account != null ? _reconnect : null,
              child: Text(s.t('Reconnect')),
            )
          else
            FilledButton(
              onPressed: _busy || _account == null
                  ? null
                  : (_prepared == null ? _prepare : _confirm),
              child: Text(
                s.t(
                  _prepared == null
                      ? 'Prepare pairing'
                      : 'Confirm keys and request approval',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
