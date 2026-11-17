import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/ui/business/common.dart';
import 'package:bridge_mobile/ui/business/session_controls.dart';
import 'package:bridge_mobile/ui/business/skill_picker.dart';
import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class SkillsRepository extends FakeRepository {
  final requests = <Map<String, dynamic>>[];
  Future<String> Function(Map<String, dynamic>)? read;
  SkillsRepository() {
    onSnapshot = (session) async => snapshotFor(
      session,
      metadata: jsonEncode({
        'access': {'canSelectSkills': true},
      }),
    );
  }

  @override
  Future<String> sessionResource(
    SessionRef session,
    SessionResource resource,
    Map<String, dynamic> parameters,
  ) async {
    if (resource != SessionResource.catalog || parameters['kind'] != 'skills') {
      return '{}';
    }
    requests.add(parameters);
    if (read != null) return read!(parameters);
    final query = parameters['q'] as String;
    return jsonEncode({
      'skills': [
        for (var i = 0; i < 10; i++)
          if ('Skill $i'.toLowerCase().contains(query.toLowerCase()))
            {
              'id': 'skill-$i',
              'name': 'skill-$i',
              'displayName': 'Skill $i',
              'description': i == 0
                  ? 'Helps discover installed skills for the current task. Choose a skill to include it with the next message.'
                  : 'Read the project and review the selected changes.',
            },
      ],
    });
  }
}

Future<BridgeViewModel> connected(SkillsRepository repository) async {
  final model = BridgeViewModel(repository);
  await model.initialize();
  await model.selectComputer(computerA);
  await model.openSession(sessionA);
  return model;
}

Future<void> mount(
  WidgetTester tester,
  BridgeViewModel model, {
  Brightness brightness = Brightness.light,
  String language = 'en',
  bool settings = false,
}) async {
  final scope = SessionBusiness(model, model.snapshot!);
  addTearDown(scope.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('skill-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: bridgeTheme(brightness),
        locale: Locale(language),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: settings
            ? SessionControlsPage(scope: scope)
            : Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => skillPickerDialog(context, scope),
                      child: const Text('Open Skills'),
                    ),
                  ),
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(settings ? 'Skill' : 'Open Skills'));
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
    'composer opens a dialog and preserves chat and chosen skills on close',
    (tester) async {
      final repository = SkillsRepository();
      final model = await connected(repository);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      final transcript = tester.element(
        find.byKey(const Key('chat-transcript')),
      );
      await tester.tap(find.text('Skill'));
      await tester.pumpAndSettle();
      expect(find.byType(SkillPickerDialog), findsOneWidget);
      expect(
        tester.element(find.byKey(const Key('chat-transcript'))),
        same(transcript),
      );
      expect(
        tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color?.a ??
            0,
        0,
      );
      await tester.tap(find.byKey(const ValueKey('skill-skill-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('done-skills')));
      await tester.pumpAndSettle();
      expect(find.byType(SkillPickerDialog), findsNothing);
      expect(model.draftOptions['skills'], ['skill-0']);
      await tester.tap(find.text('Skill'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('skill-skill-0')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('close-skills')));
      await tester.pumpAndSettle();
      expect(model.draftOptions['skills'], ['skill-0']);
      expect(repository.sends + repository.stops, 0);
      await finish(tester, model);
    },
  );

  testWidgets(
    'settings uses the same picker and search and refresh preserve eight selections',
    (tester) async {
      final repository = SkillsRepository();
      final model = await connected(repository);
      model.setDraftOption('skills', [for (var i = 0; i < 7; i++) 'skill-$i']);
      await mount(tester, model, settings: true);
      expect(find.byType(SkillPickerDialog), findsOneWidget);
      await tester.enterText(find.byKey(const Key('skill-search')), 'Skill 7');
      await tester.pump(const Duration(milliseconds: 201));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('skill-skill-7')));
      await tester.pumpAndSettle();
      expect((model.draftOptions['skills'] as List).length, 8);
      await tester.enterText(find.byKey(const Key('skill-search')), 'Skill 8');
      await tester.pump(const Duration(milliseconds: 201));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('skill-skill-8')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const Key('refresh-skills')));
      await tester.pumpAndSettle();
      expect(repository.requests.last['refresh'], isTrue);
      expect((model.draftOptions['skills'] as List).length, 8);
      await tester.tap(find.byKey(const Key('done-skills')));
      await tester.pumpAndSettle();
      expect(find.byType(SessionControlsPage), findsOneWidget);
      expect(repository.sends + repository.stops, 0);
      await finish(tester, model);
    },
  );

  testWidgets(
    'late searches and a changed chat cannot overwrite results or another draft',
    (tester) async {
      final repository = SkillsRepository();
      final model = await connected(repository);
      await mount(tester, model);
      final old = Completer<String>();
      repository.read = (parameters) async => parameters['q'] == 'old'
          ? old.future
          : jsonEncode({
              'skills': [
                {'id': 'latest', 'name': 'Latest skill'},
              ],
            });
      await tester.enterText(find.byKey(const Key('skill-search')), 'old');
      await tester.pump(const Duration(milliseconds: 201));
      await tester.enterText(find.byKey(const Key('skill-search')), 'new');
      await tester.pump(const Duration(milliseconds: 201));
      await tester.pumpAndSettle();
      old.complete(
        jsonEncode({
          'skills': [
            {'id': 'old', 'name': 'Old result'},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Latest skill'), findsOneWidget);
      expect(find.text('Old result'), findsNothing);
      final choose = tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('skill-latest')))
          .onChanged!;
      await tester.runAsync(() => model.openSession(sessionB));
      await tester.pumpAndSettle();
      choose(true);
      await tester.pumpAndSettle();
      expect(model.draftOptions['skills'] ?? [], isEmpty);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('skill-latest')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const Key('close-skills')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await finish(tester, model);
    },
  );

  testWidgets('keyboard resizing retains the skill search and chosen draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final repository = SkillsRepository();
    final model = await connected(repository);
    await mount(tester, model);
    await tester.enterText(find.byKey(const Key('skill-search')), 'Skill 7');
    await tester.pump(const Duration(milliseconds: 201));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('skill-search')))
          .controller!
          .text,
      'Skill 7',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('skill-skill-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skill-skill-7')));
    await tester.pumpAndSettle();
    expect(model.draftOptions['skills'], ['skill-7']);
    expect(tester.takeException(), isNull);
    await finish(tester, model);
  });

  for (final brightness in Brightness.values) {
    testWidgets('skill picker ${brightness.name} golden', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = SkillsRepository();
      final model = await connected(repository);
      await mount(tester, model, brightness: brightness);
      await expectLater(
        find.byKey(const Key('skill-capture')),
        matchesGoldenFile('goldens/skills-${brightness.name}.png'),
      );
      await finish(tester, model);
    });
  }

  for (final language in ['zh', 'en']) {
    for (final size in [const Size(320, 640), const Size(720, 400)]) {
      testWidgets(
        'skill dialog fits large $language text and keyboard at $size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          tester.view.viewInsets = const FakeViewPadding(bottom: 140);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          addTearDown(tester.view.resetViewInsets);
          final repository = SkillsRepository();
          final model = await connected(repository);
          await mount(tester, model, language: language);
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byKey(const Key('done-skills'))).bottom,
            lessThanOrEqualTo(size.height - 140),
          );
          await tester.tap(find.byKey(const Key('done-skills')));
          await tester.pumpAndSettle();
          expect(find.byType(SkillPickerDialog), findsNothing);
          await finish(tester, model);
        },
      );
    }
  }
}
