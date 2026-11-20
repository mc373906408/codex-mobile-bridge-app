import 'dart:async';
import 'dart:typed_data';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/chat_attachment_preparation.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attachment_picker.dart';
import 'support/fake_repository.dart';

const photo = Attachment(
  id: 'synthetic-upload',
  name: 'synthetic-photo.jpg',
  image: true,
  source: 'upload',
);

void main() {
  late FakeRepository repository;
  late BridgeViewModel model;
  late Future<Uint8List> Function(Uint8List) encode;

  setUp(() async {
    encode = (_) async => syntheticJpeg;
    repository = FakeRepository()..onUpload = (_, _, _) async => photo;
    model = BridgeViewModel(repository, photoEncoder: (bytes) => encode(bytes));
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
  });
  tearDown(() => model.dispose());

  LocalChatAttachment stage({
    String name = 'synthetic-photo.png',
    bool image = true,
  }) {
    final file = LocalChatAttachment(
      name: name,
      bytes: syntheticImage,
      image: image,
    );
    model.stageAttachment(file, target: model.snapshot!);
    return file;
  }

  for (final resumeBeforeAcknowledgement in [false, true]) {
    test(
      'upload acknowledgement survives background; early resume=$resumeBeforeAcknowledgement',
      () async {
        final result = Completer<Attachment>(), started = Completer<void>();
        repository.onUpload = (_, _, _) {
          started.complete();
          return result.future;
        };
        stage();
        final sending = model.send();
        await started.future;
        await model.setForeground(false);
        if (resumeBeforeAcknowledgement) await model.setForeground(true);
        result.complete(photo);
        await sending;
        if (!resumeBeforeAcknowledgement) await model.setForeground(true);
        expect(model.attachments, [photo]);
        expect(model.stagedAttachments, isEmpty);
        expect((await repository.draft(sessionA, 'account-a')).attachments, [
          photo,
        ]);
        expect(model.canSend, isTrue);
        expect(repository.uploads, 1);
        expect(repository.sends, 0);
        await model.send();
        expect(repository.uploads, 1);
        expect(repository.sentAttachments, [photo.id]);
      },
    );
  }

  test(
    'JPG conversion starts locally and photo-only send uses the upload ID',
    () async {
      final file = stage();
      final prepared = await file.prepared;
      expect(prepared?.bytes, syntheticJpeg);
      expect(prepared?.name, photo.name);
      expect(repository.uploads, 0);
      expect(model.canSend, isTrue);
      await model.send();
      await model.send();
      expect(repository.sentAttachments, [photo.id]);
      expect(repository.sends, 1);
      expect(repository.uploads, 1);
      expect(model.attachments, isEmpty);
      expect(model.stagedAttachments, isEmpty);
    },
  );

  test('ordinary files are deferred without encoding or renaming', () async {
    encode = (_) => throw StateError('Not a photo');
    final file = stage(name: 'data.bin', image: false);
    expect(await file.prepared, (name: 'data.bin', bytes: syntheticImage));
    expect(repository.uploads, 0);
    repository.onUpload = (_, name, bytes) async {
      expect(name, 'data.bin');
      expect(bytes, same(syntheticImage));
      return photo;
    };
    await model.send();
    expect(repository.sends, 1);
  });

  test(
    'a fresh snapshot for another account does not inherit local files',
    () async {
      stage();
      await model.setForeground(false);
      repository.onSnapshot = (session) async =>
          snapshotFor(session, account: 'account-b');
      await model.setForeground(true);
      expect(model.stagedAttachments, isEmpty);
      expect(model.canSend, isFalse);
      expect(repository.uploads, 0);
    },
  );

  test(
    'background during conversion does not dispatch an upload or auto-send',
    () async {
      final encoded = Completer<Uint8List>();
      encode = (_) => encoded.future;
      stage();
      final sending = model.send();
      await model.setForeground(false);
      encoded.complete(syntheticJpeg);
      await sending;
      await model.setForeground(true);
      expect(repository.uploads, 0);
      expect(repository.sends, 0);
      expect(model.stagedAttachments, hasLength(1));
      expect(model.canSend, isTrue);
    },
  );

  test(
    'partial failure retains confirmed IDs and retries only the remaining file',
    () async {
      final names = <String>[];
      repository.onUpload = (_, name, _) async {
        names.add(name);
        if (names.length == 2) throw StateError('Temporary failure');
        if (names.length == 1) return photo;
        return Attachment(
          id: 'other-upload',
          name: name,
          image: true,
          source: 'upload',
        );
      };
      stage();
      final second = stage(name: 'second.png');
      model.editDraft('Keep this until sent');
      await model.send();
      expect(repository.sends, 0);
      expect(model.draftText, 'Keep this until sent');
      expect((await repository.draft(sessionA, 'account-a')).attachments, [
        photo,
      ]);
      expect(model.stagedAttachments, [second]);
      await model.send();
      expect(names, ['synthetic-photo.jpg', 'second.jpg', 'second.jpg']);
      expect(repository.sentAttachments, [photo.id, 'other-upload']);
      expect(repository.sends, 1);
      expect(model.attachments, isEmpty);
    },
  );

  test(
    'uncertain upload is surfaced and not replayed on retry or resume',
    () async {
      repository.onUpload = (snapshot, _, _) async {
        repository.operations[repository.scope(
          snapshot.session,
          snapshot.accountIdentity,
        )] = [
          const PendingOperation(
            id: 'uncertain',
            action: 'upload',
            createdAt: 0,
            message: 'Check on the computer',
          ),
        ];
        throw StateError(
          'Upload was not acknowledged; check it on the computer',
        );
      };
      stage();
      await model.send();
      expect(model.error.toString(), contains('Upload was not acknowledged'));
      expect(model.pending.single.action, 'upload');
      await model.setForeground(false);
      await model.setForeground(true);
      expect(model.canSend, isFalse);
      await model.send();
      expect(model.stagedAttachments, hasLength(1));
      expect(repository.uploads, 1);
      expect(repository.sends, 0);
    },
  );

  test(
    'conversion failure leaves a removable draft and sends nothing',
    () async {
      encode = (_) async => throw StateError('Bad photo');
      final file = stage();
      await model.send();
      expect(
        model.error.toString(),
        contains('Could not convert the image to JPG'),
      );
      expect(model.stagedAttachments, [file]);
      expect(repository.uploads, 0);
      expect(repository.sends, 0);
      model.removeStagedAttachment(file);
      expect(model.stagedAttachments, isEmpty);
    },
  );
}
