import 'dart:async';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/computer_names.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
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
}
