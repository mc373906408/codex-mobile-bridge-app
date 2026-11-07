import 'dart:async';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/computer_names.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

class _NameStorage extends FlutterSecureStorage {
  String? value;
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) async {
    expect(key, 'bridge.computer_names.v1');
    return value;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) async {
    expect(key, 'bridge.computer_names.v1');
    this.value = value;
  }
}

Future<void> closeApp(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

void main() {
  test(
    'local names survive a new repository without touching native identity',
    () async {
      final storage = _NameStorage();
      final first = NativeBridgeRepository(secureStorage: storage);
      final key = computerNameKey(computerA);
      expect(await first.computerNames(), isEmpty);
      await first.saveComputerNames({key: '工作电脑 🖥️'});
      final restarted = NativeBridgeRepository(secureStorage: storage);
      expect(await restarted.computerNames(), {key: '工作电脑 🖥️'});
      expect(() => decodeComputerNames('{"broken":1}'), throwsFormatException);
    },
  );

  test(
    'renaming the active computer preserves connection, draft and remote name',
    () async {
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      model.editDraft('Keep this draft');
      await model.flushDraft();
      final connections = repository.connects;
      final generation = model.connectionGeneration;
      expect(await model.renameComputer(computerA, '  办公室  '), isTrue);
      expect(model.computerName(computerA), '办公室');
      expect(model.computer, same(computerA));
      expect(model.selected, sessionA);
      expect(model.connectionGeneration, generation);
      expect(model.draftText, 'Keep this draft');
      expect(repository.savedComputers.first.name, 'Studio');
      expect(repository.connects, connections);
      expect(repository.sends + repository.creates + repository.stops, 0);
      await model.reloadComputers();
      expect(model.computerName(computerA), '办公室');
      model.dispose();
      await Future<void>.delayed(Duration.zero);
      final restarted = BridgeViewModel(repository);
      await restarted.initialize();
      expect(restarted.computerName(computerA), '办公室');
      restarted.dispose();
    },
  );

  test('names are isolated by exact cloud identity and survive fresh discovery objects', () async {
    final repository = FakeRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    final original = cloudComputer();
    await model.renameComputer(original, '我的 Mac');
    final sameIdentity = Computer(
      id: original.id,
      name: 'Changed remote name',
      baseUrl: original.baseUrl,
      connectionType: original.connectionType,
      relay: original.relay,
    );
    expect(model.computerName(sameIdentity), '我的 Mac');
    final relay = original.relay!;
    for (final changed in [
      RelayConnection(
        origin: 'https://another.example',
        accountId: relay.accountId,
        gatewayId: relay.gatewayId,
        bindingId: relay.bindingId,
        desktopPublicKey: relay.desktopPublicKey,
      ),
      RelayConnection(
        origin: relay.origin,
        accountId: 'another-account',
        gatewayId: relay.gatewayId,
        bindingId: relay.bindingId,
        desktopPublicKey: relay.desktopPublicKey,
      ),
      RelayConnection(
        origin: relay.origin,
        accountId: relay.accountId,
        gatewayId: relay.gatewayId,
        bindingId: relay.bindingId,
        desktopPublicKey: 'another-key',
      ),
    ]) {
      final other = Computer(
        id: original.id,
        name: 'Other desktop',
        baseUrl: original.baseUrl,
        connectionType: ConnectionType.relay,
        relay: changed,
      );
      expect(model.computerName(other), 'Other desktop');
    }
    expect(repository.connects, 0);
    model.dispose();
  });

  test(
    'failed or overlapping name saves do not overwrite confirmed names',
    () async {
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.renameComputer(computerA, 'Confirmed');
      repository.onSaveComputerNames = (_) async =>
          throw StateError('Storage unavailable');
      await expectLater(
        model.renameComputer(computerA, 'Not saved'),
        throwsStateError,
      );
      expect(model.computerName(computerA), 'Confirmed');
      expect(model.renamingComputer, isFalse);
      final gate = Completer<void>();
      repository.onSaveComputerNames = (_) => gate.future;
      final saving = model.renameComputer(computerA, 'First');
      expect(await model.renameComputer(computerB, 'Second'), isFalse);
      gate.complete();
      await saving;
      expect(model.computerName(computerA), 'First');
      expect(model.computerName(computerB), 'Workshop');
      model.dispose();
    },
  );

  test(
    'removing a saved direct connection removes only its local name',
    () async {
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.renameComputer(computerA, 'Office');
      await model.renameComputer(computerB, 'Home');
      await model.removeComputer(computerA);
      expect(model.computerName(computerA), 'Studio');
      expect(model.computerName(computerB), 'Home');
      expect(repository.savedComputerNames.keys, [computerNameKey(computerB)]);
      model.dispose();
    },
  );

  testWidgets('rename failure keeps the dialog and allows retry', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..onSaveComputerNames = (_) async =>
          throw StateError('Synthetic failure');
    final model = BridgeViewModel(repository);
    await model.initialize();
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('computer-card-${computerA.id}'));
    await tester.ensureVisible(card);
    await tester.longPress(card);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('computer-name')),
      'My desktop',
    );
    await tester.tap(find.byKey(const Key('save-computer-name')));
    await tester.pumpAndSettle();
    expect(find.text('Could not save the name. Try again.'), findsOneWidget);
    expect(model.computerName(computerA), 'Studio');
    repository.onSaveComputerNames = null;
    await tester.tap(find.byKey(const Key('save-computer-name')));
    await tester.pumpAndSettle();
    expect(model.computerName(computerA), 'My desktop');
    expect(find.byKey(const Key('rename-computer-dialog')), findsNothing);
    await closeApp(tester, model);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('long device name fits a narrow chat heading at scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.renameComputer(
        computerA,
        '设计工作室的 MacBook Pro / Design Studio',
      );
      await model.selectComputer(computerA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('设计工作室的 MacBook Pro / Design Studio'),
        findsOneWidget,
      );
      for (final action in ['Inbox', 'New chat', 'Refresh']) {
        expect(
          tester.getRect(find.byTooltip(action)).right,
          lessThanOrEqualTo(320),
        );
      }
      expect(tester.takeException(), isNull);
      await closeApp(tester, model);
    });
  }

  for (final locale in ['zh', 'en']) {
    testWidgets('rename from computer card updates device heading in $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(locale: locale);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      final options = find.byKey(ValueKey('computer-options-${computerA.id}'));
      await tester.ensureVisible(options);
      await tester.tap(options);
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '重命名' : 'Rename computer'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('computer-name')), '');
      await tester.tap(find.byKey(const Key('save-computer-name')));
      await tester.pumpAndSettle();
      expect(
        find.text(locale == 'zh' ? '请输入设备名称' : 'Enter a device name'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('computer-name')), '书房工作电脑');
      await tester.tap(find.byKey(const Key('save-computer-name')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rename-computer-dialog')), findsNothing);
      expect(find.text('书房工作电脑'), findsOneWidget);
      final card = find.byKey(ValueKey('computer-card-${computerA.id}'));
      await tester.ensureVisible(card);
      await tester.tap(
        find.descendant(of: card, matching: find.text('书房工作电脑')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('chats-title'))).data,
        '书房工作电脑',
      );
      expect(find.byKey(const Key('connected-computer')), findsNothing);
      expect(repository.sends + repository.creates + repository.stops, 0);
      expect(tester.takeException(), isNull);
      await closeApp(tester, model);
    });
  }
}
