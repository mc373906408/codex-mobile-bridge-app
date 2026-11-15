import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/ui/business/common.dart';
import 'package:bridge_mobile/ui/business/model_settings.dart';
import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:bridge_mobile/ui/design/selection_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

Map<String, dynamic> catalog({String identity = 'catalog-a'}) => {
  'models': [
    {
      'id': 'model-a',
      'name': 'GPT-6 Astra · agent',
      'efforts': ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
      'defaultEffort': 'high',
    },
    {
      'id': 'model-b',
      'name': 'GPT-6.1 Sol · agent',
      'efforts': ['low', 'high'],
      'defaultEffort': 'low',
    },
    for (var i = 0; i < 12; i++)
      {
        'id': 'route-$i',
        'name': 'Provider $i · A long model name',
        'efforts': ['high'],
        'defaultEffort': 'high',
      },
  ],
  'cache': {
    'identity': identity,
    // The panel displays local time; keep the visible fixture identical in CI.
    'updatedAt': DateTime(2026, 11, 15, 5, 30).millisecondsSinceEpoch ~/ 1000,
  },
};

class CatalogRepository extends FakeRepository {
  int catalogReads = 0, snapshotReads = 0;
  String account = 'account-a', identity = 'catalog-a';
  Completer<String>? waiting;
  Object? failure;
  Map<String, dynamic>? saved;
  final refreshes = <bool>[];
  CatalogRepository() {
    onSnapshot = (session) async {
      snapshotReads++;
      return snapshotFor(
        session,
        account: account,
        metadata: jsonEncode({'modelCatalogIdentity': identity}),
      );
    };
  }
  @override
  Future<String> sessionResource(
    SessionRef session,
    SessionResource resource,
    Map<String, dynamic> parameters,
  ) async {
    if (resource != SessionResource.catalog) {
      throw UnsupportedError('not supported');
    }
    catalogReads++;
    refreshes.add(parameters['refresh'] == true);
    if (failure != null) throw failure!;
    return waiting?.future ?? jsonEncode(catalog(identity: identity));
  }

  @override
  Future<BusinessReply> sessionCommand(
    SessionSnapshot snapshot,
    String id,
    SessionCommand command,
    Map<String, dynamic> parameters,
  ) async {
    saved = parameters;
    return BusinessReply(outcome: accepted(id), data: '{}');
  }
}

Future<BridgeViewModel> connected(CatalogRepository repository) async {
  final model = BridgeViewModel(repository);
  await model.initialize();
  await model.selectComputer(computerA);
  await model.openSession(sessionA);
  return model;
}

void main() {
  test(
    'prefetch shares its in-flight read and warm opens make no requests',
    () async {
      final repository = CatalogRepository()..waiting = Completer<String>();
      final model = await connected(repository);
      final one = model.loadModelCatalog(model.snapshot!);
      final two = model.loadModelCatalog(model.snapshot!);
      expect(identical(one, two), isTrue);
      expect(repository.catalogReads, 1);
      final before = repository.snapshotReads;
      repository.waiting!.complete(jsonEncode(catalog()));
      await one;
      expect(
        repository.snapshotReads - before,
        1,
        reason:
            'one post-read account verification, no duplicate pre-read history',
      );
      final reads = repository.snapshotReads;
      await model.loadModelCatalog(model.snapshot!);
      expect(repository.catalogReads, 1);
      expect(repository.snapshotReads, reads);
      repository.waiting = null;
      await model.loadModelCatalog(model.snapshot!, refresh: true);
      expect(repository.refreshes, [false, true]);
      model.dispose();
    },
  );

  test('remote account change cannot populate cache', () async {
    final repository = CatalogRepository()..waiting = Completer<String>();
    final model = await connected(repository);
    final pending = model.loadModelCatalog(model.snapshot!);
    repository.account = 'account-b';
    final rejected = expectLater(pending, throwsStateError);
    repository.waiting!.complete(jsonEncode(catalog()));
    await rejected;
    expect(model.cachedModelCatalog(model.snapshot!), isNull);
    model.dispose();
  });

  test(
    'catalog identity mismatch and connection change reject late reads',
    () async {
      for (final background in [false, true]) {
        final repository = CatalogRepository()..waiting = Completer<String>();
        final model = await connected(repository);
        final pending = model.loadModelCatalog(model.snapshot!);
        final rejected = expectLater(pending, throwsStateError);
        if (background) await model.setForeground(false);
        repository.waiting!.complete(
          jsonEncode(catalog(identity: background ? 'catalog-a' : 'other')),
        );
        await rejected;
        model.dispose();
      }
    },
  );

  test('failed prefetch is silent and explicit retry succeeds', () async {
    final repository = CatalogRepository()..failure = StateError('offline');
    final model = await connected(repository);
    await Future<void>.delayed(Duration.zero);
    expect(model.error, isNull);
    expect(model.fresh, isTrue);
    repository.failure = null;
    expect(
      (await model.loadModelCatalog(model.snapshot!))['models'],
      isNotEmpty,
    );
    model.dispose();
  });

  test(
    'same account catalogs remain isolated by session, host and instance',
    () async {
      final repository = CatalogRepository();
      final model = await connected(repository);
      await model.loadModelCatalog(model.snapshot!);
      final first = repository.catalogReads;
      for (final target in [
        const SessionRef(
          computerId: 'computer-a',
          provider: Provider.codex,
          environment: 'ssh:lab',
          id: '11111111-1111-4111-8111-111111111111',
        ),
        const SessionRef(
          computerId: 'computer-a',
          provider: Provider.codex,
          entry: 'codex:other',
          environment: 'local',
          id: '11111111-1111-4111-8111-111111111111',
        ),
        const SessionRef(
          computerId: 'computer-a',
          provider: Provider.codex,
          environment: 'local',
          id: '22222222-2222-4222-8222-222222222222',
        ),
      ]) {
        final snapshot = await repository.snapshot(target);
        expect(model.cachedModelCatalog(snapshot), isNull);
        await model.loadModelCatalog(snapshot);
      }
      expect(repository.catalogReads, first + 3);
      model.dispose();
    },
  );

  setUpAll(() async {
    final bytes = rootBundle.load('assets/fonts/PlexSans.ttf');
    for (final family in ['Ahem', 'Roboto', '.SF UI Text', '.SF UI Display']) {
      await (FontLoader(family)..addFont(bytes)).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final theme in ['light', 'dark']) {
    testWidgets(
      'web model settings $theme golden and applies selected capability',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = CatalogRepository();
        final model = await connected(repository);
        await model.loadModelCatalog(model.snapshot!);
        await mountDialog(tester, model, theme: theme);
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        expect(find.byType(BridgeChoiceGrid), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(const Key('model-capture')),
          matchesGoldenFile('goldens/model-settings-$theme.png'),
        );
        await tester.tap(find.text('GPT-6.1 Sol · agent'));
        await tester.pumpAndSettle();
        expect(find.text('Ultra'), findsNothing);
        await tester.tap(find.byKey(const Key('apply-model')));
        await tester.pumpAndSettle();
        expect(repository.saved, {'model': 'model-b', 'effort': 'high'});
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final size in [const Size(320, 640), const Size(720, 400)]) {
      testWidgets(
        'model dialog fits $language $size with large text and keyboard',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          tester.view.viewInsets = const FakeViewPadding(bottom: 140);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          addTearDown(tester.view.resetViewInsets);
          final repository = CatalogRepository();
          final model = await connected(repository);
          await model.loadModelCatalog(model.snapshot!);
          await mountDialog(tester, model, language: language);
          expect(tester.takeException(), isNull);
          final apply = tester.getRect(find.byKey(const Key('apply-model')));
          expect(apply.bottom, lessThanOrEqualTo(size.height - 140));
          await tester.pumpWidget(const SizedBox.shrink());
          model.dispose();
          await tester.pump();
        },
      );
    }
  }
}

Future<void> mountDialog(
  WidgetTester tester,
  BridgeViewModel model, {
  String theme = 'light',
  String language = 'en',
}) async {
  final scope = SessionBusiness(model, model.snapshot!);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('model-capture'),
      child: MaterialApp(
        theme: bridgeTheme(
          theme == 'dark' ? Brightness.dark : Brightness.light,
        ),
        locale: Locale(language),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => scopedModelDialog(context, scope),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}
