import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../data/cloud_accounts.dart';
import '../../l10n/strings.dart';
import '../../viewmodels/bridge_view_model.dart';
import '../../viewmodels/cloud_view_model.dart';
import '../cloud_status_widgets.dart';

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
    required this.model,
    required this.cloud,
    required this.strings,
    required this.onCloud,
    required this.onComputer,
  });
  final BridgeViewModel model;
  final Strings strings;
  final CloudViewModel? cloud;
  final VoidCallback onCloud;
  final ValueChanged<Computer> onComputer;
  @override
  State<ConnectionPage> createState() => ConnectionPageState();
}

class ConnectionPageState extends State<ConnectionPage> {
  final _username = TextEditingController(),
      _password = TextEditingController();
  @override
  void dispose() {
    _username.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final password = _password.text;
    _password.clear();
    await widget.model.login(_username.text, password);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    final computer = widget.model.computer;
    if (computer?.connectionType == ConnectionType.relay) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(28),
            children: [
              const Icon(Icons.cloud_outlined, size: 42),
              const SizedBox(height: 20),
              Text(
                computer!.name,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(cloudServerLabel(computer.relay!.origin, s)),
              const SizedBox(height: 20),
              Text(
                s.t(
                  'Cloud connections use the account saved for this exact server and the locally approved desktop keys.',
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed:
                    widget.model.busy ||
                        widget.model.loading ||
                        widget.model.repository is! CloudRepository
                    ? null
                    : widget.onCloud,
                child: Text(s.t('Manage cloud service')),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed:
                    !widget.model.busy &&
                        !widget.model.loading &&
                        widget.model.foreground &&
                        widget.cloud?.canConnect(computer) == true
                    ? () => widget.onComputer(computer)
                    : null,
                child: Text(s.t('Reconnect')),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 450),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(28),
          children: [
            const Icon(Icons.lock_outline_rounded, size: 42),
            const SizedBox(height: 20),
            Text(
              widget.model.computer?.name ?? s.t('Sign in'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(
              widget.model.computer?.baseUrl ?? '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _username,
              autofillHints: const [AutofillHints.username],
              decoration: InputDecoration(labelText: s.t('Username')),
              enabled: !widget.model.busy,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(labelText: s.t('Password')),
              enabled: !widget.model.busy,
              onSubmitted: (_) {
                if (!widget.model.busy) _login();
              },
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: widget.model.busy || widget.model.loading
                  ? null
                  : _login,
              child: Text(s.t('Sign in')),
            ),
            const SizedBox(height: 16),
            Text(
              s.t('Credentials stay in your device secure storage.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: widget.model.loading
                  ? null
                  : () => widget.model.selectComputer(widget.model.computer!),
              icon: const Icon(Icons.refresh),
              label: Text(s.t('Retry')),
            ),
          ],
        ),
      ),
    );
  }
}
