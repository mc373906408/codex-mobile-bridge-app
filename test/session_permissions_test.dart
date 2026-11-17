import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/ui/business/common.dart';
import 'package:bridge_mobile/ui/business/session_permissions.dart';
import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class PermissionRepository extends FakeRepository {
  String runtime = 'desktop', mode = 'ask';
  bool linux = false, confirmed = true;
  int reads = 0;
  final writes = <Map<String, dynamic>>[];
  final disabled = <String>{};
  Completer<BusinessReply>? response;
  PermissionRepository() {
    onSnapshot = (session) async => snapshotFor(
      session,
      metadata: jsonEncode({
        'access': {'runtime': runtime, 'canChangePermissions': true},
        'capabilities': {'permissions': true},
        'permissionMode': mode,
        'linuxPermissionChecks': linux,
      }),
    );
  }

  @override
  Future<String> sessionResource(
    SessionRef session,
    SessionResource resource,
    Map<String, dynamic> parameters,
  ) async {
    if (resource != SessionResource.permissions) return '{}';
    reads++;
    if (session.provider == Provider.codex && runtime == 'desktop' && !linux) {
      throw StateError('This host does not support Linux permission checks');
    }
    return jsonEncode({
      'current': mode,
      'mode': mode,
      'options': session.provider == Provider.codex
          ? [
              for (final preset in ['ask', 'auto-review', 'full-access'])
                {
                  'preset': preset,
                  'available': !disabled.contains(preset),
                  if (disabled.contains(preset))
                    'reason': 'Disabled by runtime policy',
                },
            ]
          : [
              {'value': 'default', 'label': 'Default'},
              {'value': 'acceptEdits', 'label': 'Allow edits'},
            ],
    });
  }

  @override
  Future<BusinessReply> sessionCommand(
    SessionSnapshot snapshot,
    String id,
    SessionCommand command,
    Map<String, dynamic> parameters,
  ) async {
    expect(command, SessionCommand.permissions);
    writes.add(parameters);
    if (response != null) return response!.future;
    if (confirmed) {
      mode = (parameters['preset'] ?? parameters['mode']) as String;
      emit(await this.snapshot(snapshot.session));
    }
    return BusinessReply(
      outcome: accepted(id),
      data: jsonEncode({'confirmed': confirmed, 'mode': mode}),
    );
  }
}

Future<BridgeViewModel> connected(
  PermissionRepository repository, {
  SessionRef session = sessionA,
}) async {
  final model = BridgeViewModel(repository);
  await model.initialize();
  await model.selectComputer(computerA);
  await model.openSession(session);
  return model;
}

Future<void> mount(
  WidgetTester tester,
  BridgeViewModel model, {
  Brightness brightness = Brightness.light,
  String language = 'en',
}) async {
  final scope = SessionBusiness(model, model.snapshot!);
  addTearDown(scope.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('permission-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: bridgeTheme(brightness),
        locale: Locale(language),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => sessionPermissions(context, scope),
                child: const Text('Open permissions'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open permissions'));
  await tester.pumpAndSettle();
}

Future<void> finish(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

void main() {
  setUpAll(() async {
    final font = rootBundle.load('assets/fonts/PlexSans.ttf');
    for (final family in ['Ahem', 'Roboto', '.SF UI Text', '.SF UI Display']) {
      await (FontLoader(family)..addFont(font)).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'desktop composer opens presets without Linux GET and shows the saved label',
    (tester) async {
      final repository = PermissionRepository();
      final model = await connected(repository);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask for approval'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('session-permissions-dialog')),
        findsOneWidget,
      );
      expect(repository.reads, 0);
      await tester.tap(find.byKey(const ValueKey('permission-auto-review')));
      await tester.pumpAndSettle();
      expect(repository.writes, [
        {
          'preset': 'auto-review',
          'confirmed': false,
          'expectedRuntime': 'desktop',
        },
      ]);
      expect(find.byKey(const Key('session-permissions-dialog')), findsNothing);
      expect(find.text('Auto review'), findsOneWidget);
      expect(find.text('Permissions updated'), findsOneWidget);
      await finish(tester, model);
    },
  );

  for (final runtime in ['cli', 'linux']) {
    testWidgets(
      '$runtime reads capability options and disables unavailable presets',
      (tester) async {
        final repository = PermissionRepository()
          ..runtime = runtime == 'cli' ? 'cli' : 'desktop'
          ..linux = runtime == 'linux'
          ..disabled.add('auto-review');
        final model = await connected(repository);
        await mount(tester, model);
        expect(repository.reads, 1);
        expect(find.text('Disabled by runtime policy'), findsOneWidget);
        expect(
          tester
              .widget<InkWell>(
                find.byKey(const ValueKey('permission-auto-review')),
              )
              .onTap,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('permission-full-access')));
        await tester.pumpAndSettle();
        expect(repository.writes, isEmpty);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repository.writes, isEmpty);
        await tester.tap(find.byKey(const ValueKey('permission-full-access')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(repository.writes.single, {
          'preset': 'full-access',
          'confirmed': true,
          'expectedRuntime': repository.runtime,
        });
        expect(
          find.byKey(const Key('session-permissions-dialog')),
          findsNothing,
        );
        await finish(tester, model);
      },
    );
  }

  testWidgets(
    'unconfirmed save stays open and refresh confirms without repeating the write',
    (tester) async {
      final repository = PermissionRepository()..confirmed = false;
      final model = await connected(repository);
      await mount(tester, model);
      await tester.tap(find.byKey(const ValueKey('permission-auto-review')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('session-permissions-dialog')),
        findsOneWidget,
      );
      expect(
        find.text('Permission change submitted. Waiting for confirmation.'),
        findsOneWidget,
      );
      expect(find.text('Permissions updated'), findsNothing);
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const ValueKey('permission-auto-review')),
            )
            .onTap,
        isNull,
      );
      repository.mode = 'auto-review';
      await tester.tap(find.byKey(const Key('refresh-permissions')));
      await tester.pumpAndSettle();
      expect(repository.writes.length, 1);
      expect(find.byKey(const Key('session-permissions-dialog')), findsNothing);
      await finish(tester, model);
    },
  );

  testWidgets(
    'runtime change while confirming full access prevents a stale save',
    (tester) async {
      final repository = PermissionRepository();
      final model = await connected(repository);
      await mount(tester, model);
      await tester.tap(find.byKey(const ValueKey('permission-full-access')));
      await tester.pumpAndSettle();
      repository.runtime = 'cli';
      repository.emit(await repository.snapshot(sessionA));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(repository.writes, isEmpty);
      expect(
        find.text('Chat or runtime changed. Reopen permission settings.'),
        findsOneWidget,
      );
      await finish(tester, model);
    },
  );

  testWidgets('other clients retain their native mode contract', (
    tester,
  ) async {
    final repository = PermissionRepository()..mode = 'default';
    final model = await connected(repository, session: sessionB);
    await mount(tester, model);
    expect(repository.reads, 1);
    expect(find.text('Full access'), findsNothing);
    await tester.tap(find.text('Allow edits'));
    await tester.pumpAndSettle();
    expect(repository.writes.single, {'mode': 'acceptEdits'});
    expect(find.byKey(const Key('session-permissions-dialog')), findsNothing);
    await finish(tester, model);
  });

  for (final brightness in Brightness.values) {
    testWidgets('permission dialog ${brightness.name} golden', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = PermissionRepository()..mode = 'full-access';
      final model = await connected(repository);
      await mount(tester, model, brightness: brightness);
      await expectLater(
        find.byKey(const Key('permission-capture')),
        matchesGoldenFile('goldens/permissions-${brightness.name}.png'),
      );
      await finish(tester, model);
    });
  }

  for (final language in ['zh', 'en']) {
    testWidgets('permission dialog fits narrow large $language text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = PermissionRepository();
      final model = await connected(repository);
      await mount(tester, model, language: language);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('permission-full-access')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close-permissions')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-permissions-dialog')), findsNothing);
      await finish(tester, model);
    });
  }
}
