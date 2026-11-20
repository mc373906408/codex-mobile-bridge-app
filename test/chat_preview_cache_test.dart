import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/chat_preview_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  test('stores only the bounded newest rows without attachment handles', () {
    final cache = ChatPreviewCache();
    final messages = [
      for (var index = 0; index < 49; index++)
        message('message-$index', 'Text'),
      const ChatMessage(
        id: 'last',
        role: 'assistant',
        title: '',
        text: 'Message with an image',
        output: '',
        truncated: false,
        attachments: [
          Attachment(
            id: 'image',
            name: 'image.png',
            image: true,
            source: 'upload',
          ),
        ],
      ),
    ];
    cache.remember(snapshotFor(sessionA, messages: messages));
    final page = cache.read(sessionA)!;
    expect(page.messages, hasLength(40));
    expect(page.messages.first.id, 'message-10');
    expect(page.messages.last.id, 'last');
    expect(page.messages.last.attachments, isEmpty);
    expect(messages.last.attachments, hasLength(1));

    cache.remember(
      snapshotFor(
        sessionA,
        messages: [
          message('large', 'x' * (129 * 1024)),
          message('last', 'Latest text'),
        ],
      ),
    );
    expect(cache.read(sessionA)!.messages.single.id, 'last');
  });

  test('ages expire even after a cache hit', () {
    var now = Duration.zero;
    final cache = ChatPreviewCache(now: () => now);
    cache.remember(snapshotFor(sessionA));
    now = const Duration(seconds: 119);
    expect(cache.read(sessionA), isNotNull);
    now = const Duration(minutes: 2);
    expect(cache.read(sessionA), isNull);
  });

  test('exact session scope and account changes invalidate cached pages', () {
    final cache = ChatPreviewCache();
    cache.remember(snapshotFor(sessionA));
    const otherEntry = SessionRef(
      computerId: 'computer-a',
      provider: Provider.codex,
      entry: 'other',
      environment: 'local',
      id: '11111111-1111-4111-8111-111111111111',
    );
    expect(cache.read(otherEntry), isNull);
    cache.discardMismatch(snapshotFor(sessionA, account: 'another-account'));
    expect(cache.read(sessionA), isNull);
    cache.remember(snapshotFor(sessionA, account: ''));
    expect(cache.read(sessionA), isNull);
  });

  test('bounds the number of retained chats and evicts least recent', () {
    final cache = ChatPreviewCache();
    final sessions = [
      for (var index = 0; index < 9; index++)
        SessionRef(
          computerId: computerA.id,
          provider: Provider.codex,
          environment: 'local',
          id: 'session-$index',
        ),
    ];
    for (final session in sessions.take(8)) {
      cache.remember(snapshotFor(session));
    }
    expect(cache.read(sessions.first), isNotNull);
    cache.remember(snapshotFor(sessions.last));
    expect(cache.read(sessions[1]), isNull);
    expect(cache.read(sessions.first), isNotNull);
    expect(cache.read(sessions.last), isNotNull);
  });
}
