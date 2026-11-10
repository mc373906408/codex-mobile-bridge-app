part of 'bridge_view_model.dart';

extension BridgeAttachments on BridgeViewModel {
  Future<bool> _waitForAttachmentTarget(SessionSnapshot target) async {
    bool? ready() {
      if (_disposed || selected != target.session) return false;
      final current = snapshot;
      if (current != null &&
          current.accountIdentity != target.accountIdentity) {
        return false;
      }
      if (foreground && authenticated && fresh && draftEditable) return true;
      return null;
    }

    if (ready() case final bool value) return value;
    final completion = Completer<bool>();
    void changed() {
      if (ready() case final bool value) {
        if (!completion.isCompleted) completion.complete(value);
      }
    }

    // Android may return the selected file before resume/authentication finishes.
    // Wait for the original scope, without queuing or replaying a gateway write.
    addListener(changed);
    _attachmentWaiters.add(changed);
    try {
      return await completion.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError(
          'Connection is not ready. Reconnect and select the attachment again.',
        ),
      );
    } finally {
      _attachmentWaiters.remove(changed);
      removeListener(changed);
    }
  }

  Future<void> attach(
    String name,
    Uint8List bytes, {
    SessionSnapshot? pickedFor,
  }) async {
    if (pickedFor != null) {
      try {
        if (!await _waitForAttachmentTarget(pickedFor)) return;
      } catch (value) {
        if (!_disposed && selected == pickedFor.session) reportError(value);
        return;
      }
    }
    final current = snapshot;
    if (_disposed ||
        current == null ||
        !canAttach ||
        (pickedFor != null &&
            (selected != pickedFor.session ||
                current.accountIdentity != pickedFor.accountIdentity))) {
      return;
    }
    busy = true;
    error = null;
    _notify();
    try {
      final attachment = await repository.upload(current, name, bytes);
      // Acknowledged uploads still belong in the draft after backgrounding.
      if (_disposed ||
          selected != current.session ||
          _draftAccount != current.accountIdentity) {
        return;
      }
      attachments = [...attachments, attachment];
      ++_draftRevision;
      await flushDraft();
    } catch (value) {
      if (selected == current.session &&
          _draftAccount == current.accountIdentity) {
        error = value;
      }
    } finally {
      if (!_disposed) await _reloadPending(current);
      busy = false;
      _notify();
      await _resumeAfterWrite(current.session);
    }
  }

  void removeAttachment(Attachment value) {
    if (busy || !draftEditable) return;
    attachments = attachments.where((item) => item.id != value.id).toList();
    ++_draftRevision;
    unawaited(flushDraft());
    _notify();
  }

  void setSteer(bool value) {
    setDraftOption(
      'mode',
      value && snapshot?.capabilities.steer == true ? 'steer' : 'send',
    );
  }
}
