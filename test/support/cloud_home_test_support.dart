import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> closeCloudApp(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

Future<void> enterCloudLogin(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('cloud-login')),
    'user@example.com',
  );
  await tester.enterText(find.byKey(const Key('cloud-password')), 'password');
  final button = find.byKey(const Key('cloud-sign-in'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void expectOfficialAddressHidden() {
  expect(
    find.textContaining(
      Uri.parse(officialCloudOrigin).host,
      skipOffstage: false,
    ),
    findsNothing,
  );
}

void expectHomeCloudSummaryRemoved() {
  for (final key in [
    'cloud-overview',
    'cloud-account-label',
    'cloud-service-status',
    'cloud-direct-notification-status',
    'cloud-background-push-status',
  ]) {
    expect(find.byKey(Key(key), skipOffstage: false), findsNothing);
  }
}

void expectServicePanelsRemoved({
  Strings strings = const Strings(Locale('en')),
}) {
  for (final key in [
    'cloud-service-status',
    'cloud-pair-computer',
    'cloud-direct-notification-status',
    'cloud-background-push-status',
    'cloud-notification-consent',
  ]) {
    expect(find.byKey(Key(key), skipOffstage: false), findsNothing);
  }
  for (final label in [
    'Service status',
    'Cloud task notifications',
    'Private cloud notifications',
  ]) {
    expect(find.text(strings.t(label)), findsNothing);
  }
}

void expectServerSelectionHidden({
  Strings strings = const Strings(Locale('en')),
}) {
  expect(find.text(strings.t('Cloud server')), findsNothing);
  for (final key in [
    'official-cloud-option',
    'selfhost-cloud-option',
    'current-cloud-origin',
    'use-saved-connection-server',
  ]) {
    expect(find.byKey(Key(key)), findsNothing);
  }
}

Future<void> openCloudService(
  WidgetTester tester, {
  Strings strings = const Strings(Locale('en')),
}) async {
  await tester.tap(find.byTooltip(strings.t('Settings')));
  await tester.pumpAndSettle();
  final link = find.byKey(const Key('settings-cloud-service'));
  await tester.ensureVisible(link);
  await tester.pumpAndSettle();
  await tester.tap(link);
  await tester.pumpAndSettle();
}

TextField cloudCredentialField(WidgetTester tester, String key) =>
    tester.widget<TextField>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
      ),
    );

void expectClearCloudLoginFields(WidgetTester tester, Strings strings) {
  expect(find.text(strings.t('Email / Account')), findsOneWidget);
  for (final key in ['cloud-login', 'cloud-password']) {
    final field = cloudCredentialField(tester, key);
    final decoration = field.decoration!;
    expect(decoration.counterText, '');
    expect(decoration.hintText, isNotEmpty);
    expect(decoration.filled, isTrue);
    for (final border in [
      decoration.enabledBorder,
      decoration.focusedBorder,
      decoration.disabledBorder,
      decoration.errorBorder,
      decoration.focusedErrorBorder,
    ]) {
      expect(border, isA<OutlineInputBorder>());
      expect(border!.borderSide.style, BorderStyle.solid);
      expect(border.borderSide.width, greaterThan(0));
    }
    expect(field.maxLength, key == 'cloud-login' ? 320 : 1024);
  }
  expect(cloudCredentialField(tester, 'cloud-password').obscureText, isTrue);
  expect(find.textContaining(RegExp(r'^\d+/(320|1024)$')), findsNothing);
}
