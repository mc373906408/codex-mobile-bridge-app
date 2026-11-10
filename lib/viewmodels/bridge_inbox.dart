part of 'bridge_view_model.dart';

extension BridgeInbox on BridgeViewModel {
  Future<void> refreshInbox() async {
    final target = computer, generation = _connectionGeneration;
    if (target == null || !authenticated || !foreground) return;
    try {
      final values = await repository.inbox(target);
      if (_disposed || generation != _connectionGeneration || !foreground) {
        return;
      }
      inbox = values;
      _notify();
    } catch (_) {
      /* An optional inbox failure does not invalidate chat state. */
    }
  }

  void markInboxRead() {
    readInbox.addAll(inbox.map((entry) => entry.id));
    _savePreferences();
    _notify();
  }

  Future<void> openNotification({
    required String computerId,
    required String scope,
    required String eventId,
  }) async {
    if (_disposed || busy || !foreground) return;
    final target = computers
        .where((value) => value.id == computerId)
        .firstOrNull;
    if (target == null) {
      notice = 'This notification has expired; check the inbox.';
      _notify();
      return;
    }
    final generation = _connectionGeneration + 1;
    await selectComputer(target);
    if (_disposed ||
        generation != _connectionGeneration ||
        computer?.id != target.id ||
        !foreground) {
      return;
    }
    _pendingNotification = (
      computerId: computerId,
      scope: scope,
      eventId: eventId,
    );
    await _resolveNotification();
  }

  Future<void> _resolveNotification() async {
    final route = _pendingNotification;
    final target = computer;
    if (route == null ||
        target?.id != route.computerId ||
        !authenticated ||
        busy ||
        !foreground) {
      return;
    }
    _pendingNotification = null;
    final generation = _connectionGeneration;
    try {
      final batch = await repository.notificationEvents(target!);
      if (_disposed || generation != _connectionGeneration || !foreground) {
        return;
      }
      final event = batch.enabled && batch.scope == route.scope
          ? batch.events.where((event) => event.id == route.eventId).firstOrNull
          : null;
      if (event?.session == null) {
        notice = 'This notification has expired; check the inbox.';
        _notify();
        return;
      }
      await openInboxEntry(
        InboxEntry(id: event!.id, title: '', body: '', session: event.session),
      );
      if (selected == event.session) {
        readInbox.add(event.id);
        _savePreferences();
        _notify();
      }
    } catch (value) {
      if (generation == _connectionGeneration) reportError(value);
    }
  }

  Future<void> openInboxEntry(InboxEntry entry) async {
    var session = entry.session;
    final target = computer,
        generation = _connectionGeneration,
        selection = _selectionGeneration;
    if (session == null || target == null || busy || !foreground) return;
    try {
      if (session.provider != Provider.codex) {
        SessionRef? resolved;
        int? offset = 0;
        for (var pageIndex = 0; offset != null && pageIndex < 20; pageIndex++) {
          final page = await repository.sessionsForEntry(
            target,
            session.provider,
            session.entry,
            '',
            offset,
            'all',
            false,
          );
          resolved = page.sessions
              .where((row) => row.session.id == session!.id)
              .firstOrNull
              ?.session;
          if (resolved != null) break;
          offset = page.nextOffset;
        }
        if (resolved == null) {
          throw StateError(
            'Conversation unavailable; find it on the original computer',
          );
        }
        session = resolved;
      }
      if (_disposed ||
          generation != _connectionGeneration ||
          selection != _selectionGeneration ||
          !foreground) {
        return;
      }
      await selectProvider(session.provider);
      await openSession(session);
    } catch (value) {
      if (generation == _connectionGeneration) reportError(value);
    }
  }
}
