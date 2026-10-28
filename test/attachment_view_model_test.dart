import 'dart:async';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attachment_picker.dart';
import 'support/fake_repository.dart';

const photo = Attachment(
  id: 'synthetic-upload',
  name: 'synthetic-photo.png',
  image: true,
  source: 'upload',
);

Future<void> tick() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeRepository repository;
  late BridgeViewModel model;
  var disposed = false;

  setUp(() async {
    disposed = false;
    repository = FakeRepository()..onUpload = (_, _, _) async => photo;
    model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
  });
  tearDown(() async {
    if (!disposed) model.dispose();
    await tick();
  });

  for (final resumeBeforeAcknowledgement in [false, true]) {
    test(
      'acknowledged upload survives background; early resume=$resumeBeforeAcknowledgement',
      () async {
        final result = Completer<Attachment>();
        repository.onUpload = (_, _, _) => result.future;
        final uploading = model.attach(photo.name, syntheticImage);
        await tick();
        expect(repository.uploads, 1);
        await model.setForeground(false);
        if (resumeBeforeAcknowledgement) await model.setForeground(true);
        result.complete(photo);
        await uploading;
        expect(model.attachments, [photo]);
        expect((await repository.draft(sessionA, 'account-a')).attachments, [
          photo,
        ]);
        if (!resumeBeforeAcknowledgement) await model.setForeground(true);
        expect(model.attachments, [photo]);
        expect(model.fresh, isTrue);
        expect(model.canSend, isTrue);
        expect(repository.uploads, 1);
        expect(repository.sends, 0);
      },
    );
  }

  test(
    'image-only message sends the stored attachment id exactly once',
    () async {
      await model.attach(photo.name, syntheticImage);
      expect(model.draftText, isEmpty);
      expect(model.canSend, isTrue);
      await model.send();
      await model.send();
      expect(repository.sentAttachments, [photo.id]);
      expect(repository.sends, 1);
      expect(repository.uploads, 1);
      expect(model.attachments, isEmpty);
    },
  );

  test(
    'pending picker is discarded if resume authenticates a different account',
    () async {
      final target = model.snapshot!;
      await model.setForeground(false);
      final attaching = model.attach(
        photo.name,
        syntheticImage,
        pickedFor: target,
      );
      repository.onSnapshot = (session) async =>
          snapshotFor(session, account: 'account-b');
      await model.setForeground(true);
      await attaching;
      expect(model.snapshot!.accountIdentity, 'account-b');
      expect(model.attachments, isEmpty);
      expect(repository.uploads, 0);
    },
  );

  test(
    'uncertain upload is surfaced and never replayed after resume',
    () async {
      repository.onUpload = (snapshot, _, _) async {
        repository.operations[repository.scope(
          snapshot.session,
          snapshot.accountIdentity,
        )] = [
          const PendingOperation(
            id: 'uncertain-upload',
            action: 'upload',
            createdAt: 0,
            message: 'Check on the computer',
          ),
        ];
        throw StateError(
          'Upload was not acknowledged; check it on the computer',
        );
      };
      await model.attach(photo.name, syntheticImage);
      expect(model.error.toString(), contains('Upload was not acknowledged'));
      expect(model.pending.single.action, 'upload');
      expect(model.attachments, isEmpty);
      await model.setForeground(false);
      await model.setForeground(true);
      expect(repository.uploads, 1);
      expect(repository.sends, 0);
      expect(model.attachments, isEmpty);
    },
  );

  test('disposing cancels an attachment waiting for foreground', () async {
    final target = model.snapshot!;
    await model.setForeground(false);
    final attaching = model.attach(
      photo.name,
      syntheticImage,
      pickedFor: target,
    );
    model.dispose();
    disposed = true;
    await attaching;
    expect(repository.uploads, 0);
  });
}
