part of 'bridge_view_model.dart';

extension BridgeSessionWrites on BridgeViewModel {
  void addQuote(String text, String source) {
    if (!draftEditable || busy || text.trim().isEmpty) return;
    if (quotes.length >= 8 || text.length > 100000) {
      reportError('At most 8 quotes, each up to 100000 characters');
      return;
    }
    setDraftOption('quotes', [
      ...quotes,
      {'text': text, 'source': source, 'provider': selected?.provider.name},
    ]);
  }

  void setDraftOption(String key, Object? value) {
    if (!draftEditable || busy) return;
    draftOptions = {...draftOptions, key: value};
    editDraft(draftText);
  }

  Future<void> addFileReference(String path, int line) async {
    final current = snapshot, generation = _selectionGeneration;
    if (current == null || !draftEditable || !fresh || busy) return;
    try {
      if (_attachmentCount >= 10) {
        throw StateError('At most 10 attachments and references');
      }
      final data = jsonDecode(
        await repository.sessionResource(
          current.session,
          SessionResource.fileInfo,
          {'path': path},
        ),
      ) as Map;
      final verified = await repository.snapshot(current.session);
      if (!_current(generation, current.session) ||
          verified.accountIdentity != current.accountIdentity) {
        return;
      }
      if (data['absolutePath'] is! String || data['path'] is! String) {
        throw StateError('File reference is unavailable');
      }
      final refs = fileReferences;
      if (!refs.any((r) => r['absolutePath'] == data['absolutePath'])) {
        if (_attachmentCount >= 10) {
          throw StateError('At most 10 attachments and references');
        }
        refs.add({'path': data['path'], 'absolutePath': data['absolutePath']});
      }
      setDraftOption('references', refs);
      if (line > 1) {
        editDraft(
          '$draftText${draftText.isEmpty ? '' : '\n'}${data['path']}:$line',
        );
      }
    } catch (value) {
      if (_current(generation, current.session)) reportError(value);
      rethrow;
    }
  }

  void editDraft(String value) {
    if (!_draftReady || _returningHome) return;
    draftText = value;
    ++_draftRevision;
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(flushDraft()),
    );
    _notify();
  }

  Future<void> flushDraft() async {
    _draftTimer?.cancel();
    final session = selected, account = _draftAccount;
    if (session == null || account.isEmpty || !_draftReady) return;
    final draft = Draft(
      text: draftText,
      attachments: [...attachments],
      revision: _draftRevision,
      options: jsonEncode(draftOptions),
    );
    try {
      await repository.saveDraft(session, account, draft);
      if (selected == session &&
          _draftAccount == account &&
          _draftRevision == draft.revision) {
        _draftFailed = false;
        _notify();
      }
    } catch (value) {
      if (selected == session && _draftAccount == account) {
        _draftFailed = true;
        error = value;
        _notify();
      }
    }
  }

  Future<void> send() async {
    if (!canSend) return;
    final current = snapshot!, local = stagedAttachments;
    final scope = (current.session, current.accountIdentity);
    final generation = _selectionGeneration;
    var revision = _draftRevision;
    final text = composedText, options = draftOptions, mode = sendMode;
    final references = fileReferences;
    final files = attachments.map((item) => item.id).toList();
    bool sameDraft() => !_disposed && _attachmentDraftScope == scope;
    bool canContinue() {
      if (!sameDraft() ||
          _draftFailed ||
          !foreground ||
          !authenticated ||
          !fresh ||
          !_current(generation, current.session)) {
        return false;
      }
      if (snapshot?.controlToken != current.controlToken) {
        throw StateError(
          'Session state or account changed. Refresh before trying again',
        );
      }
      return !pending.any(
        (operation) =>
            operation.action == 'send' ||
            operation.action == 'upload' && local.isNotEmpty,
      );
    }

    busy = true;
    sendingChatAttachments = local.isNotEmpty;
    error = null;
    _notify();
    try {
      if (text.runes.length > 100000) {
        throw StateError('Message including quotes exceeds 100000 characters');
      }
      await flushDraft();
      if (!canContinue()) return;
      for (final file in local) {
        final payload = await file.prepared;
        if (!canContinue()) return;
        if (payload == null) {
          throw StateError('Could not convert the image to JPG');
        }
        uploadingChatAttachment = file;
        _notify();
        final uploaded = await repository.upload(
          current,
          payload.name,
          payload.bytes,
        );
        uploadingChatAttachment = null;
        if (!sameDraft() || !stagedAttachments.contains(file)) return;
        _forgetStagedAttachment(scope, file);
        files.add(uploaded.id);
        attachments = [...attachments, uploaded];
        if (revision == _draftRevision) ++revision;
        ++_draftRevision;
        await flushDraft();
        if (!canContinue()) return;
      }
      final OperationOutcome result;
      if (options.isNotEmpty) {
        final body = <String, Object?>{
          'text': text,
          'attachments': files,
          'mode': mode,
          'workMode': mode == 'steer' ? null : options['workMode'] ?? 'default',
          'skills': options['skills'] ?? [],
          'references': references,
          'uiLocale': locale == 'zh' ? 'zh-CN' : 'en-US',
        };
        result = (await repository.sessionCommand(
          current,
          repository.newId(),
          SessionCommand.send,
          body,
        )).outcome;
      } else {
        result = await repository.send(
          current,
          repository.newId(),
          text,
          files,
          mode == 'steer',
        );
      }
      // A background transition invalidates read generations, not an acknowledged write.
      if (!sameDraft()) return;
      if (result.kind == OutcomeKind.accepted && _draftRevision == revision) {
        draftText = '';
        attachments = [];
        draftOptions = {};
        ++_draftRevision;
        await flushDraft();
      }
      if (result.kind != OutcomeKind.accepted) error = result.message;
      if (repository.storageWarning case final warning?) notice = warning;
    } catch (value) {
      if (sameDraft()) error = value;
    } finally {
      await _reloadPending(current);
      sendingChatAttachments = false;
      uploadingChatAttachment = null;
      busy = false;
      _notify();
      await _resumeAfterWrite(current.session);
    }
  }

  Future<void> _reloadPending(SessionSnapshot current) async {
    try {
      final values = await repository.pending(
        current.session,
        current.accountIdentity,
      );
      if (!_disposed &&
          selected == current.session &&
          _draftAccount == current.accountIdentity) {
        pending = values;
      }
    } catch (value) {
      if (!_disposed &&
          selected == current.session &&
          _draftAccount == current.accountIdentity) {
        _draftFailed = true;
        error = value;
      }
    }
  }

  Future<void> _resumeAfterWrite(SessionRef session) async {
    if (!_disposed &&
        foreground &&
        authenticated &&
        selected == session &&
        !fresh) {
      await openSession(session);
    }
  }

  Future<void> perform(
    Future<OperationOutcome> Function(SessionSnapshot value, String id) action,
  ) async {
    if (busy || !foreground || !authenticated || !fresh || snapshot == null) {
      return;
    }
    final current = snapshot!, generation = _selectionGeneration;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await action(current, repository.newId());
      if (!_current(generation, current.session)) return;
      if (result.kind != OutcomeKind.accepted) error = result.message;
      await _applySnapshot(
        await repository.snapshot(current.session),
        generation,
      );
    } catch (value) {
      if (_current(generation, current.session)) error = value;
    } finally {
      await _reloadPending(current);
      busy = false;
      _notify();
      await _resumeAfterWrite(current.session);
    }
  }

  Future<void> connectSession() async {
    if (!canConnectSession) return;
    final generation = _selectionGeneration;
    _sessionConnectGeneration = generation;
    try {
      await perform((value, id) async {
        final unresolved = await repository.pending(
          value.session,
          value.accountIdentity,
        );
        if (!_current(generation, value.session) ||
            !foreground ||
            !authenticated) {
          throw StateError('Operation cancelled');
        }
        if (!fresh || snapshot?.accountIdentity != value.accountIdentity) {
          throw StateError(
            'Session state or account changed. Refresh before trying again',
          );
        }
        if (unresolved.any(
          (operation) =>
              const {'resume', 'reconnect'}.contains(operation.action),
        )) {
          throw StateError(
            'Previous submission is unresolved; it was not replayed',
          );
        }
        return repository.resume(value, id);
      });
    } finally {
      if (_sessionConnectGeneration == generation) {
        _sessionConnectGeneration = null;
      }
      _notify();
    }
  }

  Future<void> markReviewed(
    PendingOperation operation, {
    SessionSnapshot? authority,
  }) async {
    final current = authority ?? snapshot;
    if (current == null || busy) return;
    await repository.markReviewed(
      current.session,
      current.accountIdentity,
      operation.id,
    );
    await _reloadPending(current);
    _notify();
  }

  Future<void> createChat(
    ProjectOption project,
    String title,
    String text, {
    int? expectedConnection,
    Map<String, Object?> options = const {},
  }) async {
    final target = computer;
    if (target == null || busy || !foreground || !authenticated) return;
    if ((expectedConnection != null &&
            expectedConnection != _connectionGeneration) ||
        project.provider != provider ||
        project.entry != entry) {
      reportError('Connection changed; reopen the new chat dialog');
      return;
    }
    final generation = _connectionGeneration;
    busy = true;
    _notify();
    try {
      final result = options.isNotEmpty
          ? await repository.createWithOptions(
              target,
              project,
              title,
              text,
              repository.newId(),
              options,
            )
          : await repository.create(
              target,
              project,
              title,
              text,
              repository.newId(),
            );
      if (_disposed || generation != _connectionGeneration || !foreground) {
        return;
      }
      if (result.kind != OutcomeKind.accepted) {
        error = result.message;
        return;
      }
      await refreshSessions();
      busy = false;
      if (result.createdSession case final session?) await openSession(session);
    } catch (value) {
      if (computer?.id == target.id) error = value;
    } finally {
      await refreshPendingCreations();
      busy = false;
      _notify();
    }
  }

  Future<void> refreshPendingCreations() async {
    final target = computer;
    if (target == null) return;
    final generation = _connectionGeneration;
    final previousError = _creationReadErrorRevision;
    try {
      final values = await repository.pendingCreations(target);
      if (!_disposed && generation == _connectionGeneration) {
        pendingCreations = values;
        _clearRecoveredReadError(previousError);
        if (_creationReadErrorRevision == previousError) {
          _creationReadErrorRevision = null;
        }
        _notify();
      }
    } catch (value) {
      if (generation == _connectionGeneration) {
        error = value;
        _creationReadErrorRevision = _errorRevision;
        _notify();
      }
    }
  }

  Future<void> reviewCreation(Computer target, PendingCreation value) async {
    await repository.reviewCreation(
      target,
      value.operation.id,
      value.accountIdentity,
    );
    await refreshPendingCreations();
    _notify();
  }
}
