import 'dart:async';

import 'package:flutter/material.dart';

import '../data/cloud_server.dart';
import '../l10n/strings.dart';
import '../viewmodels/cloud_view_model.dart';
import 'cloud_status_widgets.dart';

class CloudServicePage extends StatefulWidget {
  const CloudServicePage({
    super.key,
    required this.cloud,
    required this.strings,
    this.requestedOrigin,
  });
  final CloudViewModel cloud;
  final Strings strings;
  final String? requestedOrigin;
  @override
  State<CloudServicePage> createState() => _CloudServicePageState();
}

class _CloudServicePageState extends State<CloudServicePage> {
  final _form = GlobalKey<FormState>();
  final _login = TextEditingController(), _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    _login.text = widget.cloud.savedLogin;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.cloud.refresh());
    });
  }

  @override
  void dispose() {
    _password.clear();
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_form.currentState?.validate() != true) return;
    final password = _password.text;
    _password.clear();
    await widget.cloud.signIn(_login.text, password);
  }

  Future<void> _switch(String origin) async {
    final cloud = widget.cloud;
    if (!cloud.canManage || origin == cloud.origin) return;
    if (cloud.signedIn) {
      final s = widget.strings;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(s.t('Sign out and switch server?')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.t(
                  'The current cloud account will be signed out. Saved computers and local connections are kept. The new server requires its own login.',
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(cloudServerLabel(origin, s)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.t('Cancel')),
            ),
            FilledButton(
              key: const Key('confirm-cloud-server-switch'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.t('Sign out and switch')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !await cloud.signOut()) return;
    }
    if (!mounted) return;
    if (await cloud.switchServer(origin)) {
      _password.clear();
      _login.clear();
    }
  }

  Future<void> _selfHost() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) =>
          _ServerDialog(cloud: widget.cloud, strings: widget.strings),
    );
    if (value != null && mounted) await _switch(value);
  }

  InputDecoration _credentialDecoration(
    BuildContext context, {
    required String label,
    required String hint,
    required IconData icon,
  }) {
    final colors = Theme.of(context).colorScheme;
    OutlineInputBorder outline(Color color, {double width = 1.2}) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      prefixIcon: Icon(icon),
      counterText: '',
      filled: true,
      fillColor: colors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: outline(colors.outline),
      enabledBorder: outline(colors.outline),
      focusedBorder: outline(colors.primary, width: 2),
      disabledBorder: outline(colors.outlineVariant),
      errorBorder: outline(colors.error),
      focusedErrorBorder: outline(colors.error, width: 2),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.cloud, widget.cloud.bridge]),
    builder: (context, _) {
      final cloud = widget.cloud;
      final s = widget.strings;
      final theme = Theme.of(context);
      final serverPanel = _Panel(
        title: s.t('Cloud server'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  key: const Key('official-cloud-option'),
                  label: Text(s.t('Official cloud')),
                  selected: cloud.official,
                  onSelected: cloud.canManage
                      ? (_) => _switch(officialCloudOrigin)
                      : null,
                ),
                ChoiceChip(
                  key: const Key('selfhost-cloud-option'),
                  label: Text(s.t('Self-hosted server')),
                  selected: !cloud.official,
                  onSelected: cloud.canManage ? (_) => _selfHost() : null,
                ),
              ],
            ),
            if (!cloud.official) ...[
              const SizedBox(height: 12),
              SelectableText(
                cloud.origin,
                key: const Key('current-cloud-origin'),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              s.t(
                'Server changes require an explicit sign-out. Device discovery never selects another server or account.',
              ),
              style: theme.textTheme.bodySmall,
            ),
            if (cloud.capabilities case final capabilities?) ...[
              const SizedBox(height: 8),
              Text(
                s.t(
                  capabilities.mode == 'selfhost'
                      ? 'Self-hosted service'
                      : 'Hosted service',
                ),
                style: theme.textTheme.labelMedium,
              ),
            ],
          ],
        ),
      );
      return PopScope(
        canPop: !cloud.busy,
        child: Scaffold(
          appBar: AppBar(
            title: Text(s.t('Cloud service')),
            actions: [
              IconButton(
                key: const Key('refresh-cloud-service'),
                tooltip: s.t('Refresh'),
                onPressed:
                    cloud.loading || cloud.busy || !cloud.bridge.foreground
                    ? null
                    : cloud.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: RefreshIndicator(
              onRefresh: cloud.refresh,
              child: SingleChildScrollView(
                key: const Key('cloud-service-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (widget.requestedOrigin case final requested?) ...[
                            _Panel(
                              title: s.t('Saved connection server'),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(
                                    cloudServerLabel(requested, s),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    s.t(
                                      'Sign in with the account used to pair this computer. No other server credentials will be used.',
                                    ),
                                  ),
                                  if (requested != cloud.origin) ...[
                                    const SizedBox(height: 12),
                                    OutlinedButton(
                                      key: const Key(
                                        'use-saved-connection-server',
                                      ),
                                      onPressed: cloud.canManage
                                          ? () => _switch(requested)
                                          : null,
                                      child: Text(s.t('Use this server')),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          if (cloud.busy || cloud.loading)
                            const LinearProgressIndicator(minHeight: 2),
                          if (cloud.error case final error?)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: 16,
                                top: 12,
                              ),
                              child: Text(
                                s.error(error),
                                key: const Key('cloud-operation-error'),
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                          if (!cloud.signedIn) ...[
                            serverPanel,
                            const SizedBox(height: 16),
                          ],
                          _Panel(
                            title: s.t('Cloud account'),
                            child: cloud.signedIn
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SelectableText(
                                        cloud.account!.login,
                                        key: const Key(
                                          'signed-in-cloud-account',
                                        ),
                                        style: theme.textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        s.t(
                                          'Signed in. Same-account devices appear automatically. Enable Allow Connection on each desktop.',
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 12,
                                        runSpacing: 12,
                                        children: [
                                          OutlinedButton.icon(
                                            key: const Key('cloud-sign-out'),
                                            onPressed: cloud.canManage
                                                ? cloud.signOut
                                                : null,
                                            icon: const Icon(Icons.logout),
                                            label: Text(s.t('Log out')),
                                          ),
                                        ],
                                      ),
                                    ],
                                  )
                                : Form(
                                    key: _form,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        TextFormField(
                                          key: const Key('cloud-login'),
                                          controller: _login,
                                          enabled: cloud.canManage,
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          keyboardType: TextInputType.text,
                                          textInputAction: TextInputAction.next,
                                          maxLength: 320,
                                          decoration: _credentialDecoration(
                                            context,
                                            label: s.t('Email / Account'),
                                            hint: s.t(
                                              'Enter your email or account',
                                            ),
                                            icon: Icons.person_outline_rounded,
                                          ),
                                          validator: (value) =>
                                              value?.trim().isNotEmpty == true
                                              ? null
                                              : s.t('Enter your cloud account'),
                                        ),
                                        const SizedBox(height: 12),
                                        TextFormField(
                                          key: const Key('cloud-password'),
                                          controller: _password,
                                          enabled: cloud.canManage,
                                          obscureText: true,
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          textInputAction: TextInputAction.done,
                                          maxLength: 1024,
                                          decoration: _credentialDecoration(
                                            context,
                                            label: s.t('Password'),
                                            hint: s.t('Enter your password'),
                                            icon: Icons.lock_outline_rounded,
                                          ),
                                          validator: (value) =>
                                              value?.isNotEmpty == true
                                              ? null
                                              : s.t('Enter your password'),
                                          onFieldSubmitted: (_) {
                                            if (cloud.canSignIn) _signIn();
                                          },
                                        ),
                                        const SizedBox(height: 12),
                                        FilledButton(
                                          key: const Key('cloud-sign-in'),
                                          onPressed: cloud.canSignIn
                                              ? _signIn
                                              : null,
                                          child: Text(s.t('Sign in')),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          s.t(
                                            cloud.capabilities?.mode ==
                                                    'selfhost'
                                                ? 'Ask your server administrator to create an account. This app does not register accounts.'
                                                : 'New here? Complete registration in the desktop app first, then sign in here.',
                                          ),
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                          if (cloud.signedIn) ...[
                            const SizedBox(height: 16),
                            serverPanel,
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

class _ServerDialog extends StatefulWidget {
  const _ServerDialog({required this.cloud, required this.strings});
  final CloudViewModel cloud;
  final Strings strings;
  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final _origin = TextEditingController(
    text: widget.cloud.official ? '' : widget.cloud.origin,
  );
  Object? _error;
  @override
  void dispose() {
    _origin.dispose();
    super.dispose();
  }

  void _save() {
    try {
      Navigator.pop(context, widget.cloud.canonicalInput(_origin.text));
    } catch (error) {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.strings.t('Self-hosted server')),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('cloud-server-input'),
            controller: _origin,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: widget.strings.t('Cloud server origin'),
              hintText: 'https://relay.example:8787',
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Text(
            widget.strings.t(
              'Use an exact HTTP or HTTPS origin, including its port. HTTP does not protect account credentials. Paths, redirects and QR-selected servers are not accepted.',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              widget.strings.error(_error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.strings.t('Cancel')),
      ),
      FilledButton(
        key: const Key('save-cloud-server'),
        onPressed: _save,
        child: Text(widget.strings.t('Use server')),
      ),
    ],
  );
}
