import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/bridge_repository.dart';
import 'l10n/strings.dart';
import 'notifications/notification_controller.dart';
import 'ui/attachment_preview.dart';
import 'ui/dialogs.dart';
import 'ui/message_card.dart';
import 'ui/notification_settings.dart';
import 'viewmodels/bridge_view_model.dart';

class BridgeApp extends StatefulWidget {
  const BridgeApp({
    super.key,
    required this.repository,
    this.viewModel,
    this.notifications,
  });
  final BridgeRepository repository;
  final BridgeViewModel? viewModel;
  final NotificationController? notifications;
  @override
  State<BridgeApp> createState() => _BridgeAppState();
}

class _BridgeAppState extends State<BridgeApp> with WidgetsBindingObserver {
  late final BridgeViewModel _model;
  final _navigator = GlobalKey<NavigatorState>();
  bool _openingNotification = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _model = widget.viewModel ?? BridgeViewModel(widget.repository);
    _model.addListener(_modelChanged);
    widget.notifications?.addListener(_openPendingNotification);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (!_model.initialized) await _model.initialize();
    if (!mounted || !_model.initialized) return;
    _modelChanged();
    await widget.notifications?.initialize();
  }

  void _modelChanged() {
    widget.notifications?.updateConfiguration(_model.computers, _model.locale);
    _openPendingNotification();
  }

  void _openPendingNotification() {
    final notifications = widget.notifications;
    if (!mounted ||
        notifications == null ||
        _openingNotification ||
        !_model.initialized ||
        !_model.foreground ||
        _model.busy) {
      return;
    }
    final tap = notifications.consumeTap();
    if (tap == null) return;
    _openingNotification = true;
    _navigator.currentState?.popUntil((route) => route.isFirst);
    unawaited(
      _model
          .openNotification(
            computerId: tap.computerId,
            scope: tap.scope,
            eventId: tap.eventId,
          )
          .catchError((Object value) => _model.reportError(value))
          .whenComplete(() => _openingNotification = false),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_model.setForeground(true));
      unawaited(widget.notifications?.resume());
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_model.setForeground(false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _model.removeListener(_modelChanged);
    widget.notifications?.removeListener(_openPendingNotification);
    widget.notifications?.dispose();
    if (widget.viewModel == null) _model.dispose();
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF176C60),
          brightness: brightness,
        ).copyWith(
          surface: dark ? const Color(0xFF182523) : const Color(0xFFFBF9F2),
          primary: dark ? const Color(0xFF8BD9BE) : const Color(0xFF176C60),
          secondary: dark ? const Color(0xFFF2B289) : const Color(0xFFAC5732),
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: 'PlexSans',
    );
    return base.copyWith(
      scaffoldBackgroundColor: dark
          ? const Color(0xFF101C1A)
          : const Color(0xFFF3F0E7),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontSize: 38,
          fontWeight: FontWeight.w600,
          letterSpacing: -1.5,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -.7,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .6),
        thickness: 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _model,
    builder: (context, _) => MaterialApp(
      navigatorKey: _navigator,
      title: 'Bridge',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: switch (_model.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      locale: Locale(_model.locale),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) {
          final s = Strings(Locale(_model.locale));
          return _Home(
            model: _model,
            strings: s,
            onSettings: () => _settings(context, s),
          );
        },
      ),
    ),
  );

  void _settings(BuildContext context, Strings s) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.t('Appearance'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final mode in ThemeMode.values)
                    ChoiceChip(
                      label: Text(
                        s.t(switch (mode) {
                          ThemeMode.system => 'System theme',
                          ThemeMode.light => 'Light',
                          ThemeMode.dark => 'Dark',
                        }),
                      ),
                      selected: mode.name == _model.theme,
                      onSelected: (_) {
                        _model.setAppearance(theme: mode.name);
                        Navigator.pop(context);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                s.t('Language'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final code in ['zh', 'en'])
                    ChoiceChip(
                      label: Text(code == 'zh' ? '简体中文' : 'English'),
                      selected: _model.locale == code,
                      onSelected: (_) {
                        _model.setAppearance(locale: code);
                        Navigator.pop(context);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 24),
              if (widget.notifications case final notifications?) ...[
                NotificationSettings(controller: notifications, strings: s),
                const SizedBox(height: 24),
              ],
              Text(
                '${s.t('Direct to your gateway')} · ${s.t('No push SDKs')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Bridge Mobile',
                  applicationVersion: const String.fromEnvironment(
                    'FLUTTER_BUILD_NAME',
                    defaultValue: '0.1.0',
                  ),
                ),
                child: Text(s.t('Open source licenses')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({
    required this.model,
    required this.strings,
    required this.onSettings,
  });
  final BridgeViewModel model;
  final Strings strings;
  final VoidCallback onSettings;
  @override
  Widget build(BuildContext context) {
    final s = strings;
    return PopScope<Object?>(
      canPop: model.selected == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) model.backToSessions();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('home-button'),
            tooltip: s.t('Back to home'),
            padding: const EdgeInsets.all(12),
            onPressed: model.busy || !model.foreground
                ? null
                : () {
                    FocusScope.of(context).unfocus();
                    unawaited(model.backToComputers());
                  },
            icon: SizedBox.square(
              dimension: 32,
              child: _Mark(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          actions: [
            if (model.computers.isNotEmpty)
              PopupMenuButton<String>(
                enabled: !model.busy,
                tooltip: s.t('Computers'),
                onSelected: (id) {
                  if (id == 'add') {
                    addComputerDialog(context, model, s);
                  } else {
                    model.selectComputer(
                      model.computers.firstWhere((value) => value.id == id),
                    );
                  }
                },
                itemBuilder: (_) => [
                  for (final computer in model.computers)
                    PopupMenuItem(
                      value: computer.id,
                      child: Text(computer.name),
                    ),
                  PopupMenuItem(
                    value: 'add',
                    child: Text('+ ${s.t('Add computer')}'),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          model.computer?.name ?? s.t('Computers'),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
            if (model.authenticated)
              IconButton(
                onPressed: () => _inbox(context),
                tooltip: s.t('Inbox'),
                icon: Badge(
                  isLabelVisible: model.unreadCount > 0,
                  label: Text('${model.unreadCount}'),
                  child: const Icon(Icons.inbox_outlined),
                ),
              ),
            IconButton(
              onPressed: onSettings,
              tooltip: s.t('Settings'),
              icon: const Icon(Icons.tune_rounded),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (model.loading) const LinearProgressIndicator(minHeight: 2),
              if (model.error != null)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            s.error(model.error!),
                            style: const TextStyle(fontSize: 12),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          onPressed: model.dismissError,
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: model.computer == null
                    ? _Computers(model: model, strings: s)
                    : !model.authenticated
                    ? _Login(model: model, strings: s)
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth >= 850) {
                            return Row(
                              children: [
                                SizedBox(
                                  width: 320,
                                  child: _SessionList(model: model, strings: s),
                                ),
                                const VerticalDivider(width: 1),
                                Expanded(
                                  child: _Chat(
                                    model: model,
                                    strings: s,
                                    showBack: false,
                                  ),
                                ),
                              ],
                            );
                          }
                          return model.selected == null
                              ? _SessionList(model: model, strings: s)
                              : _Chat(model: model, strings: s, showBack: true);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _inbox(BuildContext context) {
    model.markInboxRead();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            children: [
              ListTile(
                title: Text(strings.t('Inbox')),
                subtitle: Text(
                  strings.t(
                    'Task notifications are automatic. Allow Android notifications to receive alerts.',
                  ),
                ),
              ),
              Expanded(
                child: model.inbox.isEmpty
                    ? Center(child: Text(strings.t('No new activity')))
                    : ListView.builder(
                        itemCount: model.inbox.length,
                        itemBuilder: (context, index) {
                          final entry = model.inbox[index];
                          return ListTile(
                            leading: const Icon(Icons.notifications_none),
                            title: Text(entry.title),
                            subtitle: Text(
                              entry.body,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: entry.session == null
                                ? null
                                : () {
                                    Navigator.pop(context);
                                    model.openInboxEntry(entry);
                                  },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _BridgePainter(color));
}

class _BridgePainter extends CustomPainter {
  _BridgePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width / 11
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(size.width * .12, size.height * .75)
      ..lineTo(size.width * .12, size.height * .4)
      ..quadraticBezierTo(
        size.width * .5,
        -size.height * .1,
        size.width * .88,
        size.height * .4,
      )
      ..lineTo(size.width * .88, size.height * .75);
    canvas.drawPath(path, paint);
    canvas.drawLine(
      Offset(size.width * .12, size.height * .55),
      Offset(size.width * .88, size.height * .55),
      paint,
    );
    paint.style = PaintingStyle.fill;
    for (final x in [.12, .88]) {
      canvas.drawCircle(
        Offset(size.width * x, size.height * .82),
        size.width * .09,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BridgePainter oldDelegate) => color != oldDelegate.color;
}

class _Computers extends StatelessWidget {
  const _Computers({required this.model, required this.strings});
  final BridgeViewModel model;
  final Strings strings;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primaryContainer.withValues(alpha: .2),
            Theme.of(context).scaffoldBackgroundColor,
            colors.secondaryContainer.withValues(alpha: .3),
          ],
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(28),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 86,
                  height: 86,
                  child: _Mark(color: colors.primary),
                ),
              ),
              const SizedBox(height: 26),
              Text(
                strings.t('YOUR DESK, UNTETHERED'),
                style: const TextStyle(
                  fontFamily: 'PlexMono',
                  fontSize: 11,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                strings.t('Your work. Within reach.'),
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 16),
              Text(
                strings.t(
                  'A private connection to the coding tools on your own computers.',
                ),
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(height: 1.6),
              ),
              const SizedBox(height: 28),
              if (model.computers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    strings.t('Swipe left to remove a connection'),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
              for (final computer in model.computers)
                Semantics(
                  key: ValueKey('computer-card-${computer.id}'),
                  onDismiss: model.busy || !model.foreground
                      ? null
                      : () => removeComputerDialog(
                          context,
                          model,
                          computer,
                          strings,
                        ),
                  child: Dismissible(
                    key: ValueKey('remove-computer-${computer.id}'),
                    direction: model.busy || !model.foreground
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    confirmDismiss: (_) async {
                      await removeComputerDialog(
                        context,
                        model,
                        computer,
                        strings,
                      );
                      // The model removes the card only after storage succeeds.
                      // Cancelling or failing leaves it available for another swipe.
                      return false;
                    },
                    background: Container(
                      margin: const EdgeInsets.all(4),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: colors.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.delete_outline,
                            color: colors.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            strings.t('Remove'),
                            style: TextStyle(color: colors.onErrorContainer),
                          ),
                        ],
                      ),
                    ),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        leading: Icon(
                          Icons.computer_rounded,
                          color: colors.primary,
                        ),
                        title: Text(computer.name),
                        subtitle: Text(
                          computer.baseUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.arrow_forward_rounded),
                        onTap: model.busy || !model.foreground
                            ? null
                            : () => model.selectComputer(computer),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed:
                      model.initialized && !model.busy && model.foreground
                      ? () => addComputerDialog(context, model, strings)
                      : null,
                  icon: const Icon(Icons.add),
                  label: Text(strings.t('Add computer')),
                ),
              ),
              const SizedBox(height: 36),
              const Divider(),
              const SizedBox(height: 12),
              Wrap(
                spacing: 20,
                runSpacing: 12,
                children: [
                  for (final text in [
                    'Direct to your gateway',
                    'No cloud relay',
                    'No push SDKs',
                  ])
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 15,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            strings.t(text),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Login extends StatefulWidget {
  const _Login({required this.model, required this.strings});
  final BridgeViewModel model;
  final Strings strings;
  @override
  State<_Login> createState() => _LoginState();
}

class _LoginState extends State<_Login> {
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

String providerName(Provider value) => switch (value) {
  Provider.codex => 'Codex',
  Provider.claude => 'Claude',
  Provider.deepseek => 'DeepSeek',
};

class _SessionList extends StatelessWidget {
  const _SessionList({required this.model, required this.strings});
  final BridgeViewModel model;
  final Strings strings;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme, s = strings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s.t('Choose a conversation'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                onPressed: model.busy
                    ? null
                    : () => newChatDialog(context, model, s),
                tooltip: s.t('New chat'),
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                onPressed: model.loading ? null : model.refreshSessions,
                tooltip: s.t('Refresh'),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<Provider>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            segments: [
              for (final provider in Provider.values)
                ButtonSegment(
                  value: provider,
                  label: Text(
                    providerName(provider),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selected: {model.provider},
            onSelectionChanged: model.busy
                ? null
                : (values) => model.selectProvider(values.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            key: ValueKey(model.provider),
            onChanged: model.search,
            decoration: InputDecoration(
              hintText: s.t('Search conversations'),
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
            ),
          ),
        ),
        if (model.notice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              s.notice(model.notice!),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (model.pendingCreations.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: model.busy
                  ? null
                  : () => pendingCreationsDialog(context, model, s),
              icon: const Icon(Icons.help_outline),
              label: Text(
                '${s.t('Pending verification')} (${model.pendingCreations.length})',
              ),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: model.refreshSessions,
            child: model.sessions.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 80),
                      Icon(
                        Icons.forum_outlined,
                        size: 36,
                        color: colors.outline,
                      ),
                      const SizedBox(height: 16),
                      Center(child: Text(s.t('No conversations yet'))),
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          s.t(
                            'Enable and configure this client on the computer first.',
                          ),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount:
                        model.sessions.length +
                        (model.nextOffset != null ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == model.sessions.length) {
                        return TextButton(
                          onPressed: model.loading
                              ? null
                              : () => model.refreshSessions(more: true),
                          child: Text(s.t('Load more')),
                        );
                      }
                      final row = model.sessions[index],
                          active = row.session == model.selected;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        child: ListTile(
                          selected: active,
                          selectedTileColor: colors.primaryContainer.withValues(
                            alpha: .7,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          title: Text(
                            row.title.isEmpty ? row.session.id : row.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: Text(
                              '${row.session.environment}  /  ${row.cwd.split(RegExp(r'[/\\]')).last}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'PlexMono',
                                fontSize: 10,
                              ),
                            ),
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: active ? colors.primary : colors.outline,
                            size: 18,
                          ),
                          onTap: model.busy
                              ? null
                              : () => model.openSession(row.session),
                        ),
                      );
                    },
                  ),
          ),
        ),
        if (model.computer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextButton.icon(
              onPressed: model.busy
                  ? null
                  : () => removeComputerDialog(
                      context,
                      model,
                      model.computer!,
                      s,
                    ),
              icon: const Icon(Icons.link_off, size: 16),
              label: Text(
                s.t('Remove connection'),
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
      ],
    );
  }
}

class _Chat extends StatefulWidget {
  const _Chat({
    required this.model,
    required this.strings,
    required this.showBack,
  });
  final BridgeViewModel model;
  final Strings strings;
  final bool showBack;
  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  SessionRef? _shownSession;
  String? _firstMessage;
  String? _lastMessage;
  int _lastLength = 0;
  int _messageCount = 0;
  bool _pickingAttachment = false;
  ({SessionSnapshot target, String name, Uint8List? bytes, bool image})?
  _pendingAttachment;
  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model,
        s = widget.strings,
        current = widget.model.snapshot;
    final colors = Theme.of(context).colorScheme;
    _scheduleScroll(model);
    if (_input.text != model.draftText) {
      _input.value = TextEditingValue(
        text: model.draftText,
        selection: TextSelection.collapsed(offset: model.draftText.length),
      );
    }
    if (model.selected == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: _Mark(color: colors.outlineVariant),
              ),
              const SizedBox(height: 24),
              Text(
                s.t('Choose a conversation'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                s.t(
                  'Continue without changing its original execution environment.',
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 12, 12, 12),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          child: Row(
            children: [
              if (widget.showBack)
                IconButton(
                  onPressed: model.busy ? null : model.backToSessions,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current?.title ?? s.t('Reading history…'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${providerName(model.selected!.provider)}  /  ${model.selected!.environment}',
                        style: TextStyle(
                          fontFamily: 'PlexMono',
                          fontSize: 10,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  s.t(
                    !model.fresh
                        ? 'Offline'
                        : current?.connected != true
                        ? 'History only'
                        : current!.running
                        ? 'Running'
                        : 'Live',
                  ),
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
              IconButton(
                onPressed: model.busy
                    ? null
                    : () => model.openSession(model.selected!),
                tooltip: s.t('Refresh'),
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
        ),
        if (!model.fresh && !model.loadingHistory)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              s.t(
                'History is not live control state. Refresh before taking action.',
              ),
              style: TextStyle(color: colors.secondary, fontSize: 12),
            ),
          ),
        if (model.notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              s.notice(model.notice!),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (current?.capabilities.resume == true)
          Padding(
            padding: const EdgeInsets.all(8),
            child: OutlinedButton.icon(
              onPressed: model.busy
                  ? null
                  : () => model.perform(
                      (value, id) => model.repository.resume(value, id),
                    ),
              icon: const Icon(Icons.play_arrow),
              label: Text(s.t('Continue session')),
            ),
          ),
        Expanded(
          child: SelectionArea(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              itemCount: model.messages.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Center(
                    child: model.loadingHistory
                        ? const Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : model.hasMoreHistory
                        ? TextButton(
                            onPressed: model.loadOlder,
                            child: Text(s.t('Older messages')),
                          )
                        : const SizedBox(height: 8),
                  );
                }
                return MessageCard(
                  key: ValueKey(model.messages[index - 1].id),
                  message: model.messages[index - 1],
                  session: model.selected!,
                  repository: model.repository,
                  strings: s,
                );
              },
            ),
          ),
        ),
        if (model.fresh && current != null && current.approvals.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 250),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final request in current.approvals)
                  _approval(context, current, request),
              ],
            ),
          ),
        if (model.pending.isNotEmpty)
          Container(
            color: colors.secondaryContainer,
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.help_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.t('Pending verification'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: () => _pending(context),
                  child: Text(s.t('Check on the computer')),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed:
                            !model.fresh ||
                                model.busy ||
                                current?.capabilities.models != true
                            ? null
                            : () => modelDialog(context, model, s),
                        icon: const Icon(Icons.tune, size: 15),
                        label: Text(
                          current?.model.isNotEmpty == true
                              ? current!.model
                              : s.t('Model'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                  if (current?.capabilities.steer == true)
                    FilterChip(
                      label: Text(
                        s.t('Add to current task'),
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: model.steer,
                      onSelected: model.setSteer,
                      visualDensity: VisualDensity.compact,
                    ),
                  if (current?.capabilities.stop == true)
                    IconButton(
                      onPressed: model.busy || !model.fresh
                          ? null
                          : () => model.perform((value, id) {
                              if (value.controlToken != current!.controlToken) {
                                throw StateError(
                                  'The task changed; refresh before stopping',
                                );
                              }
                              return model.repository.stop(current, id);
                            }),
                      tooltip: s.t('Stop task'),
                      color: colors.error,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                ],
              ),
              _attachmentStrip(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: model.canAttach && !_pickingAttachment
                        ? _pickFile
                        : null,
                    tooltip: s.t('Add attachment'),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('composer'),
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 100000,
                      enabled: model.draftEditable,
                      onChanged: model.editDraft,
                      decoration: InputDecoration(
                        hintText: s.t('Write a message…'),
                        counterText: '',
                        contentPadding: const EdgeInsets.all(14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: model.canSend && !_pickingAttachment
                        ? model.send
                        : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.all(14),
                      minimumSize: const Size(48, 48),
                    ),
                    child: model.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.arrow_upward, semanticLabel: s.t('Send')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _scheduleScroll(BridgeViewModel model) {
    final rows = model.messages;
    final first = rows.firstOrNull?.id, last = rows.lastOrNull?.id;
    final length =
        (rows.lastOrNull?.text.length ?? 0) +
        (rows.lastOrNull?.output.length ?? 0);
    final newSession = _shownSession != model.selected;
    final initial = _messageCount == 0 && rows.isNotEmpty;
    final prepend =
        !newSession &&
        first != _firstMessage &&
        last == _lastMessage &&
        rows.length > _messageCount;
    final oldMax = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    final oldOffset = _scroll.hasClients ? _scroll.offset : 0.0;
    final nearEnd = !_scroll.hasClients || _scroll.position.extentAfter < 140;
    final changed = last != _lastMessage || length != _lastLength;
    _shownSession = model.selected;
    _firstMessage = first;
    _lastMessage = last;
    _messageCount = rows.length;
    _lastLength = length;
    if (!prepend && !newSession && !initial && !(nearEnd && changed)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _shownSession != model.selected) {
        return;
      }
      final position = _scroll.position;
      final target = prepend
          ? oldOffset + position.maxScrollExtent - oldMax
          : position.maxScrollExtent;
      _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
    });
  }

  bool _matchesPickerTarget(SessionSnapshot target) =>
      mounted &&
      widget.model.selected == target.session &&
      (widget.model.snapshot == null ||
          widget.model.snapshot!.accountIdentity == target.accountIdentity);

  Widget _attachmentStrip() {
    final model = widget.model, s = widget.strings;
    final selection = _pendingAttachment;
    final pending = selection != null && _matchesPickerTarget(selection.target)
        ? selection
        : null;
    if (model.attachments.isEmpty && pending == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      key: ValueKey((model.selected, model.snapshot?.accountIdentity)),
      height: 108,
      child: ListView(
        key: const Key('attachment-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        children: [
          for (final file in model.attachments)
            ComposerAttachment(
              key: ValueKey('draft-attachment-${file.id}'),
              name: file.name,
              strings: s,
              preview: file.image
                  ? GatewayImage(
                      session: model.selected!,
                      attachment: file,
                      repository: model.repository,
                      strings: s,
                      width: 104,
                      height: 76,
                      decodeSize: 320,
                      compact: true,
                    )
                  : const Icon(Icons.insert_drive_file_outlined, size: 30),
              onRemove: model.busy || _pickingAttachment || !model.draftEditable
                  ? null
                  : () => model.removeAttachment(file),
            ),
          if (pending != null)
            ComposerAttachment(
              key: const Key('pending-attachment'),
              name: pending.name,
              strings: s,
              adding: true,
              preview: pending.image && pending.bytes != null
                  ? AttachmentImage(
                      bytes: pending.bytes!,
                      name: pending.name,
                      strings: s,
                      width: 104,
                      height: 76,
                      decodeSize: 320,
                      compact: true,
                    )
                  : Icon(
                      pending.image
                          ? Icons.photo_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 30,
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    final model = widget.model, s = widget.strings;
    final current = model.snapshot;
    if (current == null || _pickingAttachment || !model.canAttach) return;
    setState(() => _pickingAttachment = true);
    try {
      final type = await showModalBottomSheet<FileType>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const Key('pick-photo'),
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(s.t('Photos')),
                subtitle: Text(s.t('Choose a photo or screenshot')),
                onTap: () => Navigator.pop(context, FileType.image),
              ),
              if (current.capabilities.arbitraryFiles)
                ListTile(
                  key: const Key('pick-file'),
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(s.t('Files')),
                  subtitle: Text(s.t('Browse other files')),
                  onTap: () => Navigator.pop(context, FileType.any),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
      if (type == null || !_matchesPickerTarget(current)) return;
      final file = await FilePicker.pickFile(type: type);
      if (file == null || !_matchesPickerTarget(current)) return;
      const limit = 20 * 1024 * 1024;
      if ((file.lengthSync() ?? 0) > limit) {
        throw StateError('Attachment exceeds 20 MiB');
      }
      final image =
          type == FileType.image ||
          const {
            'png',
            'jpg',
            'jpeg',
            'gif',
            'webp',
          }.contains(file.extension?.toLowerCase());
      setState(() {
        _pendingAttachment = (
          target: current,
          name: file.name,
          bytes: null,
          image: image,
        );
      });
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (builder.length + chunk.length > limit) {
          throw StateError('Attachment exceeds 20 MiB');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (!_matchesPickerTarget(current)) return;
      setState(() {
        _pendingAttachment = (
          target: current,
          name: file.name,
          bytes: bytes,
          image: image,
        );
      });
      await model.attach(file.name, bytes, pickedFor: current);
    } catch (error) {
      if (_matchesPickerTarget(current)) model.reportError(error);
    } finally {
      if (mounted) {
        setState(() {
          _pickingAttachment = false;
          _pendingAttachment = null;
        });
      }
    }
  }

  Widget _approval(
    BuildContext context,
    SessionSnapshot authority,
    ApprovalRequest request,
  ) {
    final model = widget.model, s = widget.strings;
    Future<void> respond(bool accept) async {
      if (request.kind != ApprovalKind.questions) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s.t('Review request')),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: SelectableText(
                  request.detail,
                  style: const TextStyle(fontFamily: 'PlexMono', fontSize: 12),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.t('Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.t(accept ? 'Accept once' : 'Decline')),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      if (!context.mounted) return;
      final answers = request.kind == ApprovalKind.questions && accept
          ? await answerDialog(context, request, s)
          : <QuestionAnswer>[];
      if (answers == null) return;
      await model.perform((current, id) {
        if (current.controlToken != authority.controlToken ||
            !current.approvals.any(
              (value) =>
                  value.id == request.id &&
                  value.fingerprint == request.fingerprint,
            )) {
          throw StateError(
            'This approval changed or expired. Read the current request first',
          );
        }
        return model.repository.respond(
          authority,
          id,
          request,
          accept,
          answers,
        );
      });
    }

    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.t('Approval'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              request.detail.isEmpty ? request.title : request.detail,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'PlexMono', fontSize: 11),
            ),
            if (!request.supported)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(s.t('Handle this request on the computer.')),
              ),
            Wrap(
              spacing: 10,
              children: [
                if (request.canDecline)
                  TextButton(
                    onPressed: model.busy ? null : () => respond(false),
                    child: Text(s.t('Decline')),
                  ),
                if (request.canAccept)
                  FilledButton(
                    onPressed: model.busy ? null : () => respond(true),
                    child: Text(
                      s.t(
                        request.kind == ApprovalKind.questions
                            ? 'Answer'
                            : 'Accept once',
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pending(BuildContext context) async {
    final s = widget.strings, operations = [...widget.model.pending];
    final authority = widget.model.snapshot;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('Pending verification')),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.t(
                    'This operation may already have been submitted. It will never be replayed automatically.',
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  s.t(
                    'Only confirm after checking the original conversation. This does not resend anything or claim that the operation succeeded.',
                  ),
                ),
                for (final operation in operations)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(operation.action),
                    subtitle: Text(
                      operation.id,
                      style: const TextStyle(
                        fontFamily: 'PlexMono',
                        fontSize: 10,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: s.t('I checked on the computer'),
                      icon: const Icon(Icons.check_circle_outline),
                      onPressed: () async {
                        Navigator.pop(context);
                        try {
                          await widget.model.markReviewed(
                            operation,
                            authority: authority,
                          );
                        } catch (error) {
                          widget.model.reportError(error);
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.t('Cancel')),
          ),
        ],
      ),
    );
  }
}
