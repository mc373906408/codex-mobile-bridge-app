import 'bridge_types.dart';

class ChatPreview {
  const ChatPreview({
    required this.session,
    required this.account,
    required this.epoch,
    required this.title,
    required this.messages,
    this.listRevision,
  });

  final SessionRef session;
  final String account;
  final String epoch;
  final String title;
  final List<ChatMessage> messages;
  final String? listRevision;

  bool matches(SessionSnapshot snapshot) =>
      snapshot.session == session &&
      snapshot.accountIdentity == account &&
      snapshot.history.epoch == epoch &&
      !snapshot.history.reset;
}

class ChatPreviewCache {
  ChatPreviewCache({Duration Function()? now}) : _now = now ?? _clock();

  static const _maxChats = 8;
  static const _maxRows = 40;
  static const _maxTextUnits = 128 * 1024;
  static const _maxAge = Duration(minutes: 2);

  final Duration Function() _now;
  final _pages = <SessionRef, (ChatPreview, Duration)>{};

  static Duration Function() _clock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  ChatPreview? read(SessionRef session) {
    final entry = _pages.remove(session);
    if (entry == null || _now() - entry.$2 >= _maxAge) return null;
    _pages[session] = entry;
    return entry.$1;
  }

  void remember(SessionSnapshot snapshot, {String? listRevision}) {
    final session = snapshot.session;
    _pages.remove(session);
    if (snapshot.accountIdentity.isEmpty) return;
    final messages = <ChatMessage>[];
    var remaining = _maxTextUnits - snapshot.title.length;
    for (final message in snapshot.history.messages.reversed.take(_maxRows)) {
      remaining -=
          message.id.length +
          message.role.length +
          message.title.length +
          message.text.length +
          message.output.length +
          message.metadata.length;
      if (remaining < 0) break;
      messages.add(
        ChatMessage(
          id: message.id,
          role: message.role,
          title: message.title,
          text: message.text,
          output: message.output,
          truncated: message.truncated,
          attachments: const [],
          metadata: message.metadata,
        ),
      );
    }
    if (messages.isEmpty) return;
    final page = ChatPreview(
      session: session,
      account: snapshot.accountIdentity,
      epoch: snapshot.history.epoch,
      title: snapshot.title,
      messages: List.unmodifiable(messages.reversed),
      listRevision: listRevision,
    );
    _pages[session] = (page, _now());
    if (_pages.length > _maxChats) _pages.remove(_pages.keys.first);
  }

  void discardMismatch(SessionSnapshot snapshot) {
    if (_pages[snapshot.session]?.$1.matches(snapshot) == false) {
      discard(snapshot.session);
    }
  }

  void discard(SessionRef session) => _pages.remove(session);

  void clear() => _pages.clear();
}
