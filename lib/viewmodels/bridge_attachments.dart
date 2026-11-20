part of 'bridge_view_model.dart';

typedef _AttachmentDraftScope = (SessionRef, String);

extension BridgeAttachments on BridgeViewModel {
  _AttachmentDraftScope? get _attachmentDraftScope {
    final session = selected;
    return session != null && draftEditable ? (session, _draftAccount) : null;
  }

  List<LocalChatAttachment> get stagedAttachments =>
      _stagedAttachments[_attachmentDraftScope] ?? const [];

  int get _attachmentCount =>
      attachments.length + stagedAttachments.length + fileReferences.length;

  bool matchesAttachmentTarget(SessionSnapshot target) =>
      !_disposed &&
      !_returningHome &&
      selected == target.session &&
      (snapshot == null || snapshot!.accountIdentity == target.accountIdentity);

  void stageAttachment(
    LocalChatAttachment file, {
    required SessionSnapshot target,
  }) {
    if (busy ||
        !matchesAttachmentTarget(target) ||
        target.accountIdentity.isEmpty) {
      return;
    }
    final scope = (target.session, target.accountIdentity);
    final draft = _stagedAttachments[scope] ?? const <LocalChatAttachment>[];
    final capabilities = (snapshot ?? target).capabilities;
    if (file.bytes.isEmpty ||
        file.bytes.length > chatAttachmentMaxBytes ||
        !capabilities.attachments ||
        (!file.image && !capabilities.arbitraryFiles)) {
      throw StateError('Attachment is unsupported or exceeds 20 MiB');
    }
    if (draft.length >= 10 ||
        (_attachmentDraftScope == scope && _attachmentCount >= 10)) {
      throw StateError('At most 10 attachments and references');
    }
    final staged = _stagedAttachments.values.expand((files) => files);
    _checkLocalAttachmentBudget(staged, file.bytes.length);
    _stagedAttachments[scope] = List.unmodifiable([...draft, file]);
    if (file.image) {
      if (file.hasNativeThumbnail) unawaited(file.nativeThumbnail);
      final previous = _photoPreparation;
      Future<ChatAttachmentPayload?> prepare() async {
        await previous;
        return _stagedAttachments[scope]?.contains(file) == true
            ? file.prepare(_photoEncoder)
            : null;
      }

      file.prepared = prepare();
      _photoPreparation = file.prepared.then<void>((_) {});
    } else {
      file.prepared = file.prepare(_photoEncoder);
    }
    _notify();
  }

  void _checkLocalAttachmentBudget(
    Iterable<LocalChatAttachment> files,
    int length,
  ) {
    if (files.length >= 64 ||
        files.fold(length, (sum, value) => sum + value.bytes.length) >
            64 * 1024 * 1024) {
      throw StateError(
        'Too many local attachments. Remove one or choose a smaller file.',
      );
    }
  }

  void replaceStagedPhoto(LocalChatAttachment original, Uint8List jpeg) {
    final scope = _attachmentDraftScope;
    if (busy ||
        scope == null ||
        !original.image ||
        !stagedAttachments.contains(original)) {
      return;
    }
    if (jpeg.isEmpty || jpeg.length > chatAttachmentMaxBytes) {
      throw StateError('Attachment exceeds 20 MiB');
    }
    _checkLocalAttachmentBudget(
      _stagedAttachments.values
          .expand((files) => files)
          .where((file) => file != original),
      jpeg.length,
    );
    final replacement = LocalChatAttachment(
      name: original.jpegName,
      bytes: jpeg,
      image: true,
    );
    replacement.prepared = replacement.prepare(_photoEncoder);
    _stagedAttachments[scope] = List.unmodifiable([
      for (final file in stagedAttachments)
        file == original ? replacement : file,
    ]);
    _notify();
  }

  void _forgetStagedAttachment(
    _AttachmentDraftScope scope,
    LocalChatAttachment file,
  ) {
    final remaining = _stagedAttachments[scope]
        ?.where((value) => value != file)
        .toList();
    if (remaining == null || remaining.isEmpty) {
      _stagedAttachments.remove(scope);
    } else {
      _stagedAttachments[scope] = List.unmodifiable(remaining);
    }
  }

  void removeStagedAttachment(LocalChatAttachment file) {
    final scope = _attachmentDraftScope;
    if (busy || scope == null) return;
    _forgetStagedAttachment(scope, file);
    _notify();
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
