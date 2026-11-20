import 'dart:async';
import 'dart:typed_data';

import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/data/chat_attachment_cache.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const scope = (
  session: sessionA,
  account: 'account-a',
  historyEpoch: 'history-a',
  generation: 1,
);

Attachment attachment(String id) => Attachment(
  id: id,
  name: '$id.png',
  image: true,
  source: 'upload',
  hasThumbnail: true,
);

AttachmentImageData image(int length, {bool original = true}) =>
    AttachmentImageData(bytes: Uint8List(length), isOriginal: original);

void main() {
  test(
    'concurrent thumbnail reads coalesce and share a fallback original',
    () async {
      final cache = ChatAttachmentCache();
      final photo = attachment('one');
      final pending = Completer<AttachmentImageData>();
      final reads = <bool>[];
      Future<AttachmentImageData> fetch(bool thumbnail) async {
        reads.add(thumbnail);
        return pending.future;
      }

      final first = cache.read(scope, photo, thumbnail: true, fetch: fetch);
      final second = cache.read(scope, photo, thumbnail: true, fetch: fetch);
      expect(second, same(first));
      final original = image(10);
      pending.complete(original);
      expect(await first, same(original));
      final full = cache.read(scope, photo, thumbnail: false, fetch: fetch);
      final preview = cache.read(scope, photo, thumbnail: true, fetch: fetch);
      expect(full, isA<SynchronousFuture<AttachmentImageData>>());
      expect(await full, same(original));
      expect(await preview, same(original));
      expect(reads, [true]);
    },
  );

  test(
    'bounds entries and bytes, expires without renewing the age on a hit',
    () async {
      var now = Duration.zero;
      var reads = 0;
      final cache = ChatAttachmentCache(
        maxBytes: 7,
        maxEntries: 2,
        maxAge: const Duration(seconds: 5),
        now: () => now,
      );
      Future<AttachmentImageData> read(String id, int length) => cache.read(
        scope,
        attachment(id),
        thumbnail: false,
        fetch: (_) async {
          reads++;
          return image(length);
        },
      );

      final first = await read('first', 3);
      final second = await read('second', 3);
      now = const Duration(seconds: 4);
      expect(await read('first', 3), same(first));
      await read('third', 2);
      expect(reads, 3);
      now = const Duration(seconds: 5);
      expect(await read('first', 3), isNot(same(first)));
      expect(await read('second', 3), isNot(same(second)));
      final oversized = await read('large', 8);
      expect(await read('large', 8), isNot(same(oversized)));
      expect(reads, 7);
    },
  );

  test(
    'account, history, and session keys isolate the same attachment',
    () async {
      final cache = ChatAttachmentCache();
      final photo = attachment('same');
      final otherScopes = <AttachmentReadScope>[
        (
          session: sessionB,
          account: scope.account,
          historyEpoch: scope.historyEpoch,
          generation: scope.generation,
        ),
        (
          session: scope.session,
          account: 'other-account',
          historyEpoch: scope.historyEpoch,
          generation: scope.generation,
        ),
        (
          session: scope.session,
          account: scope.account,
          historyEpoch: 'different-history',
          generation: scope.generation,
        ),
        (
          session: scope.session,
          account: '',
          historyEpoch: scope.historyEpoch,
          generation: scope.generation,
        ),
      ];
      Future<AttachmentImageData> read(AttachmentReadScope key) => cache.read(
        key,
        photo,
        thumbnail: false,
        fetch: (_) async => image(1),
      );
      final first = await read(scope);
      for (final other in otherScopes) {
        expect(await read(other), isNot(same(first)));
      }
      final anonymous = await read(otherScopes.last);
      expect(await read(otherScopes.last), isNot(same(anonymous)));
      expect(await read(scope), same(first));
    },
  );

  test('late completions do not repopulate discarded entries', () async {
    final cache = ChatAttachmentCache();
    final photo = attachment('one');
    final pending = Completer<AttachmentImageData>();
    Future<AttachmentImageData> read(
      Future<AttachmentImageData> Function(bool) fetch,
    ) => cache.read(scope, photo, thumbnail: false, fetch: fetch);

    final old = read((_) => pending.future);
    cache.discardOtherScopes((
      session: scope.session,
      account: 'new-account',
      historyEpoch: scope.historyEpoch,
      generation: scope.generation,
    ));
    final current = image(2);
    expect(await read((_) async => current), same(current));
    pending.complete(image(3));
    await old;
    expect(await read((_) async => image(4)), same(current));
    cache.clear();
    await expectLater(
      read((_) async => throw StateError('offline')),
      throwsStateError,
    );
    expect((await read((_) async => image(4))).bytes.length, 4);
  });
}
