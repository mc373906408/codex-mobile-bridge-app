import 'dart:convert';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/ui/business/common.dart';
import 'package:bridge_mobile/ui/business/creation_page.dart';
import 'package:bridge_mobile/ui/business/gateway_settings.dart';
import 'package:bridge_mobile/ui/business/session_controls.dart';
import 'package:bridge_mobile/ui/business/workspace_page.dart';
import 'package:bridge_mobile/ui/business/wsl_accounts_page.dart';
import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _UiRepository extends FakeRepository {
  @override
  Future<String> sessionResource(
    SessionRef session,
    SessionResource resource,
    Map<String, dynamic> parameters,
  ) async => jsonEncode(switch (resource) {
    SessionResource.catalog =>
      parameters['kind'] == 'skills'
          ? {
              'skills': [
                {
                  'id': 'skill',
                  'name': 'Sample skill',
                  'description': 'Read the selected project',
                },
              ],
            }
          : {
              'models': [
                {
                  'id': 'model-a',
                  'name': 'GPT-6 Astra · agent',
                  'efforts': ['low', 'high'],
                  'defaultEffort': 'high',
                },
              ],
            },
    SessionResource.files => {
      'entries': [
        {'path': 'src', 'name': 'src', 'kind': 'directory'},
        {
          'path': 'README.md',
          'name': 'README.md',
          'kind': 'file',
          'size': 4096,
        },
      ],
    },
    SessionResource.gitStatus => {
      'available': true,
      'scope': '.',
      'branch': 'main',
      'entries': [],
    },
    SessionResource.sideChats => {
      'chats': [
        {'id': 'child', 'title': 'Related task', 'status': 'idle'},
      ],
    },
    _ => <String, dynamic>{},
  });

  @override
  Future<GatewayState> gatewayResource(
    Computer computer,
    Provider provider,
    String entry,
    GatewayResource resource,
    Map<String, dynamic> parameters,
  ) async => GatewayState(
    identity: 'gateway',
    data: jsonEncode(switch (resource) {
      GatewayResource.projects => {
        'createModels': true,
        'projects': [
          {
            'key': 'project',
            'name': 'Project',
            'environment': 'local',
            'type': 'desktop',
          },
        ],
        'environments': [
          {
            'key': 'local',
            'name': 'This computer',
            'type': 'desktop',
            'canBrowse': false,
          },
        ],
      },
      GatewayResource.creationModels => {
        'models': [
          {
            'id': 'model-a',
            'name': 'GPT-6 Astra · agent',
            'isDefault': true,
            'efforts': ['low', 'high'],
            'defaultEffort': 'high',
          },
        ],
        'currentModel': 'model-a',
      },
      GatewayResource.clients => {
        'clients': [
          {
            'id': 'codex',
            'family': 'codex',
            'name': 'Codex',
            'enabled': true,
            'connected': true,
          },
        ],
      },
      GatewayResource.accounts => {
        'accounts': [
          {'id': 'a', 'name': 'Development account', 'kind': 'api'},
        ],
      },
      GatewayResource.wslEnvironments => {
        'environments': [
          {
            'id': 'wsl:ubuntu',
            'label': 'Ubuntu',
            'user': 'developer',
            'configDir': '/home/developer/.codex',
            'running': true,
          },
        ],
      },
      _ => <String, dynamic>{},
    }),
  );
}

void main() {
  testWidgets(
    'workspace tab preserves the mounted transcript and reading offset',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _UiRepository()
        ..onSnapshot = (session) async => snapshotFor(
          session,
          messages: [
            for (var i = 0; i < 40; i++)
              message('$i', 'A longer transcript message $i'),
          ],
        );
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<ListView>(find.byKey(const Key('chat-transcript')))
          .controller!;
      controller.jumpTo(300);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open workspace'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListView>(
              find.byKey(const Key('chat-transcript'), skipOffstage: false),
            )
            .controller,
        same(controller),
      );
      await tester.tap(find.text('Chat').first);
      await tester.pumpAndSettle();
      expect(controller.offset, 300);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    },
  );
  for (final language in ['en', 'zh']) {
    for (final page in [
      'workspace',
      'git',
      'terminal',
      'tasks',
      'controls',
      'skills',
      'queue',
      'gateway',
      'accounts',
      'wsl',
      'network',
      'notifications',
      'creation',
    ]) {
      testWidgets('UI surface $page fits narrow large $language text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final repository = _UiRepository();
        final model = BridgeViewModel(repository);
        await model.initialize();
        await model.selectComputer(computerA);
        await model.openSession(sessionA);
        final scope = SessionBusiness(model, model.snapshot!);
        final gateway = GatewayBusiness(model);
        final Widget body = switch (page) {
          'workspace' ||
          'git' ||
          'terminal' ||
          'tasks' => WorkspacePage(scope: scope),
          'controls' => SessionControlsPage(scope: scope),
          'skills' => SkillPickerPage(scope: scope),
          'queue' => MessageQueuePage(scope: scope),
          'gateway' => GatewaySettingsPage(model: model),
          'accounts' => SavedAccountsPage(scope: gateway),
          'wsl' => WslEnvironmentsPage(model: model, provider: Provider.codex),
          'network' => GatewayFormPage(scope: gateway, spec: networkSpec),
          'notifications' => GatewayFormPage(
            scope: gateway,
            spec: notificationDefaultsSpec,
          ),
          _ => const SizedBox.shrink(),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: bridgeTheme(Brightness.light),
            locale: Locale(language),
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: page == 'creation'
                ? Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => CreationDialog(scope: gateway),
                        ),
                        child: const Text('Open'),
                      ),
                    ),
                  )
                : body,
          ),
        );
        await tester.pumpAndSettle();
        if (['git', 'terminal', 'tasks'].contains(page)) {
          final tab = switch (page) {
            'git' => 'Git',
            'terminal' => language == 'zh' ? '终端' : 'Terminal',
            _ => language == 'zh' ? '派生任务' : 'Related tasks',
          };
          await tester.ensureVisible(find.text(tab));
          await tester.tap(find.text(tab));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
            page == 'git'
                ? 1
                : page == 'terminal'
                ? 2
                : 3,
          );
        }
        if (page == 'creation') {
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(repository.sends + repository.stops + repository.creates, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        scope.dispose();
        gateway.dispose();
        model.dispose();
        await tester.pump();
      });
    }
  }
}
