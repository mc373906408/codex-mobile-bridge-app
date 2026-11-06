import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/bridge_repository.dart';
import 'data/cloud_accounts.dart';
import 'l10n/strings.dart';
import 'notifications/notification_controller.dart';
import 'notifications/cloud_push_controller.dart';
import 'privacy/umeng_test_consent.dart';
import 'ui/dialogs.dart';
import 'ui/cloud_service_page.dart';
import 'ui/cloud_status_widgets.dart';
import 'ui/umeng_test_consent.dart';
import 'ui/design/accessibility_bridge.dart';
import 'ui/design/bridge_theme.dart';
import 'ui/navigation/app_navigation.dart';
import 'ui/navigation/bridge_shell.dart';
import 'ui/pages/settings_page.dart';
import 'viewmodels/bridge_view_model.dart';
import 'viewmodels/cloud_view_model.dart';

class BridgeApp extends StatefulWidget {
  const BridgeApp({
    super.key,
    required this.repository,
    this.viewModel,
    this.notifications,
    this.umengConsent,
    this.cloudPush,
  });
  final BridgeRepository repository;
  final BridgeViewModel? viewModel;
  final NotificationController? notifications;
  final UmengTestConsentController? umengConsent;
  final CloudPushController? cloudPush;
  @override
  State<BridgeApp> createState() => _BridgeAppState();
}

class _BridgeAppState extends State<BridgeApp> with WidgetsBindingObserver {
  late final BridgeViewModel _model;
  late final CloudViewModel? _cloud;
  late final Listenable _state;
  final _navigator = GlobalKey<NavigatorState>();
  late final AppNavigationController _navigation;
  final _accessibility = AccessibilityBridge();
  String? _observedComputer;
  bool _openingNotification = false;
  bool _openingConsent = false;
  bool _consentScheduled = false;
  bool _consentPrompted = false;
  bool _openingCloud = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _model = widget.viewModel ?? BridgeViewModel(widget.repository);
    _observedComputer = _model.computer?.id;
    _navigation = AppNavigationController(
      initial: _model.computer == null ? AppTab.computers : AppTab.chats,
    );
    unawaited(_accessibility.initialize());
    final repository = widget.repository;
    _cloud = repository is CloudRepository
        ? CloudViewModel(
            accounts: (repository as CloudRepository).cloudAccounts,
            bridge: _model,
          )
        : null;
    _state = Listenable.merge([
      _model,
      _navigation,
      _accessibility,
      ?_cloud,
      if (widget.cloudPush != null) widget.cloudPush!,
    ]);
    _model.addListener(_modelChanged);
    _cloud?.addListener(_modelChanged);
    _cloud?.setForeground(_model.foreground);
    widget.notifications?.addListener(_openPendingNotification);
    widget.cloudPush?.addListener(_openPendingNotification);
    widget.umengConsent?.addListener(_consentChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (!_model.initialized) await _model.initialize();
    if (!mounted || !_model.initialized) return;
    unawaited(_cloud?.initialize());
    _modelChanged();
    await widget.notifications?.initialize();
    await widget.cloudPush?.initialize();
    if (!mounted) return;
    await widget.umengConsent?.initialize();
  }

  void _modelChanged() {
    final computerId = _model.computer?.id;
    if (computerId != _observedComputer) {
      _observedComputer = computerId;
      if (computerId != null) _navigation.select(AppTab.chats);
    }
    _cloud?.setForeground(_model.foreground);
    widget.cloudPush?.configureAccount(
      _cloud?.account?.scope,
      foreground: _model.foreground,
    );
    widget.notifications?.updateConfiguration(
      _model.computers
          .where(
            (computer) =>
                computer.relay == null || _cloud?.authorized(computer) == true,
          )
          .toList(),
      _model.locale,
    );
    widget.cloudPush?.configure(
      _model.computers
          .where((computer) => _cloud?.matches(computer) == true)
          .toList(),
    );
    _openPendingNotification();
    _consentChanged();
  }

  void _consentChanged() {
    final consent = widget.umengConsent;
    if (!mounted ||
        consent == null ||
        !consent.state.needsDecision ||
        !consent.state.interactive ||
        _consentPrompted ||
        _consentScheduled ||
        _openingConsent) {
      return;
    }
    _consentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consentScheduled = false;
      if (mounted) unawaited(_showTestConsent());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showTestConsent({bool manual = false}) async {
    final consent = widget.umengConsent;
    final navigator = _navigator.currentState;
    if (!mounted ||
        consent == null ||
        navigator == null ||
        !consent.state.eligible ||
        !consent.state.interactive ||
        !_model.initialized ||
        !_model.foreground ||
        _model.busy ||
        _openingConsent ||
        _openingNotification ||
        (!manual &&
            (_consentPrompted ||
                !consent.state.needsDecision ||
                navigator.canPop()))) {
      return;
    }
    _openingConsent = true;
    _consentPrompted = true;
    try {
      await showUmengTestConsentDialog(
        context: navigator.context,
        controller: consent,
        strings: Strings(Locale(_model.locale)),
      );
    } finally {
      _openingConsent = false;
      if (mounted) _openPendingNotification();
    }
  }

  void _openPendingNotification() {
    final notifications = widget.notifications;
    if (!mounted ||
        (notifications == null && widget.cloudPush == null) ||
        _openingNotification ||
        _openingConsent ||
        !_model.initialized ||
        !_model.foreground ||
        _model.busy ||
        _cloud?.busy == true) {
      return;
    }
    final tap = widget.cloudPush?.consumeTap() ?? notifications?.consumeTap();
    if (tap == null) return;
    final target = _model.computers
        .where((computer) => computer.id == tap.computerId)
        .firstOrNull;
    if (target?.connectionType == ConnectionType.relay &&
        _cloud?.authorized(target!) != true) {
      _model.reportError(StateError('Sign in to this cloud server again'));
      return;
    }
    _openingNotification = true;
    _navigation.select(AppTab.chats);
    _navigator.currentState?.popUntil((route) => route.isFirst);
    unawaited(
      _model
          .openNotification(
            computerId: tap.computerId,
            scope: tap.scope,
            eventId: tap.eventId,
          )
          .catchError((Object value) => _model.reportError(value))
          .whenComplete(() {
            _openingNotification = false;
            _consentChanged();
          }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_model.setForeground(true));
      _cloud?.setForeground(true);
      unawaited(widget.notifications?.resume());
      unawaited(widget.cloudPush?.resume());
      unawaited(widget.umengConsent?.refresh());
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_model.setForeground(false));
      _cloud?.setForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _model.removeListener(_modelChanged);
    _cloud?.removeListener(_modelChanged);
    _cloud?.dispose();
    widget.notifications?.removeListener(_openPendingNotification);
    widget.notifications?.dispose();
    widget.cloudPush?.removeListener(_openPendingNotification);
    widget.cloudPush?.dispose();
    widget.umengConsent?.removeListener(_consentChanged);
    widget.umengConsent?.dispose();
    if (widget.viewModel == null) _model.dispose();
    _navigation.dispose();
    _accessibility.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _state,
    builder: (context, _) => MaterialApp(
      navigatorKey: _navigator,
      title: 'Bridge',
      debugShowCheckedModeBanner: false,
      theme: bridgeTheme(Brightness.light),
      darkTheme: bridgeTheme(Brightness.dark),
      themeMode: switch (_model.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      locale: Locale(_model.locale),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => BridgeVisualEnvironment(
        reduceTransparency: _accessibility.reduceTransparency,
        nativeGlass: _accessibility.nativeGlass,
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          final s = Strings(Locale(_model.locale));
          return BridgeShell(
            model: _model,
            strings: s,
            navigation: _navigation,
            cloud: _cloud,
            onCloud: () => _openCloud(context, s),
            onComputer: (computer) => _selectComputer(context, s, computer),
            settings: SettingsPage(
              model: _model,
              strings: s,
              notifications: widget.notifications,
              consent: widget.umengConsent,
              cloudAvailable: _cloud != null,
              onCloud: () => _openCloud(context, s),
              onReviewConsent: () => unawaited(_showTestConsent(manual: true)),
            ),
          );
        },
      ),
    ),
  );

  Future<void> _openCloud(
    BuildContext context,
    Strings s, {
    String? requestedOrigin,
  }) async {
    final cloud = _cloud;
    if (cloud == null ||
        !cloud.initialized ||
        !mounted ||
        !context.mounted ||
        !_model.foreground ||
        _openingCloud) {
      return;
    }
    _openingCloud = true;
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (pageContext) => CloudServicePage(
            cloud: cloud,
            strings: s,
            requestedOrigin: requestedOrigin,
          ),
        ),
      );
    } finally {
      _openingCloud = false;
    }
  }

  Future<void> _selectComputer(
    BuildContext context,
    Strings s,
    Computer computer,
  ) async {
    if (_model.busy || !_model.foreground || _cloud?.busy == true) return;
    if (computer.connectionType == ConnectionType.relay &&
        _cloud?.matches(computer) != true) {
      final manage = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(s.t('Cloud login required')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.t(
                  'This saved computer requires its original server and account. Switch explicitly and sign in before reconnecting.',
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                cloudServerLabel(computer.relay?.origin ?? computer.baseUrl, s),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.t('Cancel')),
            ),
            FilledButton(
              key: const Key('open-cloud-for-connection'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.t('Open cloud service')),
            ),
          ],
        ),
      );
      if (manage == true && mounted && context.mounted) {
        await _openCloud(context, s, requestedOrigin: computer.relay?.origin);
      }
      return;
    }
    if (computer.connectionType == ConnectionType.relay &&
        _cloud?.canConnect(computer) != true) {
      final cloud = _cloud;
      if (cloud != null && context.mounted) {
        try {
          final verified = await cloud.hasVerifiedIdentity(computer);
          if (!mounted ||
              !context.mounted ||
              !_model.foreground ||
              _model.busy ||
              cloud.busy ||
              !cloud.matches(computer)) {
            return;
          }
          if (verified) {
            _navigation.select(AppTab.chats);
            await _model.selectComputer(
              computer,
              prepareConnection: () => cloud.prepareConnection(computer),
            );
            return;
          }
        } catch (error) {
          _model.reportError(error);
          return;
        }
        await cloudComputerDialog(
          context,
          _model,
          s,
          cloud: cloud,
          computer: computer,
        );
      }
      return;
    }
    _navigation.select(AppTab.chats);
    // Returning to the same authorized device is navigation, not a reconnect.
    if (_model.computer?.id == computer.id &&
        (_model.authenticated || _model.loading)) {
      return;
    }
    await _model.selectComputer(computer);
  }
}
