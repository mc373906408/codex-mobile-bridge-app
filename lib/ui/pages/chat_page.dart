import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../l10n/strings.dart';
import '../../viewmodels/bridge_view_model.dart';
import '../design/bridge_theme.dart';
import '../dialogs.dart';

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../attachment_preview.dart';
import '../message_card.dart';
import '../provider_name.dart';
import '../design/bridge_mark.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.model,
    required this.strings,
    required this.showBack,
  });
  final BridgeViewModel model;
  final Strings strings;
  final bool showBack;
  @override
  State<ChatPage> createState() => ChatPageState();
}

class ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  SessionRef? _shownSession;
  String? _firstMessage;
  String? _lastMessage;
  int _lastLength = 0;
  int _messageCount = 0;
  bool _pickingAttachment = false;
  ({SessionSnapshot target, String name, Uint8List? bytes, bool image})?
  _pendingAttachment;
  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildContent);

  Widget _buildContent(BuildContext context, BoxConstraints constraints) {
    final model = widget.model,
        s = widget.strings,
        current = widget.model.snapshot;
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.of(context);
    final compactInput = constraints.maxHeight < 500;
    _scheduleScroll(model);
    if (_input.text != model.draftText) {
      _input.value = TextEditingValue(
        text: model.draftText,
        selection: TextSelection.collapsed(offset: model.draftText.length),
      );
    }
    if (model.selected == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: BridgeMark(color: colors.outlineVariant),
              ),
              const SizedBox(height: 24),
              Text(
                s.t('Choose a conversation'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                s.t(
                  'Continue without changing its original execution environment.',
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final header = BridgeGlass(
      radius: 28,
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
      child: Row(
        children: [
          if (widget.showBack)
            IconButton(
              onPressed: model.busy ? null : model.backToSessions,
              tooltip: s.t('Back to conversations'),
              icon: const Icon(CupertinoIcons.chevron_back),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    current?.title ?? s.t('Reading history…'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(height: 1.25),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${providerName(model.selected!.provider)}  /  ${model.selected!.environment}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (MediaQuery.sizeOf(context).width > 360 &&
              MediaQuery.textScalerOf(context).scale(14) < 20)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                s.t(
                  !model.fresh
                      ? 'Offline'
                      : current?.connected != true
                      ? 'History only'
                      : current!.running
                      ? 'Running'
                      : 'Live',
                ),
                style: TextStyle(
                  fontSize: 10,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ),
          IconButton(
            onPressed: model.busy
                ? null
                : () => model.openSession(model.selected!),
            tooltip: s.t('Refresh'),
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 20),
          ),
        ],
      ),
    );
    final headerHeight =
        viewport.textScaler.scale(17) * 1.35 +
        viewport.textScaler.scale(12) * 1.4 +
        20;
    // Scaffold measures chrome in the same layout pass. The transcript fills
    // the whole viewport and receives insets for its first/last visible rows.
    return Scaffold(
      primary: false,
      resizeToAvoidBottomInset: false,
      extendBody: true,
      extendBodyBehindAppBar: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(headerHeight + 14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: header,
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (model.fresh && current != null && current.approvals.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .27,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final request in current.approvals)
                      _approval(context, current, request),
                  ],
                ),
              ),
            if (model.pending.isNotEmpty)
              Container(
                color: colors.secondaryContainer,
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.help_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.t('Pending verification'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _pending(context),
                      child: Text(s.t('Check on the computer')),
                    ),
                  ],
                ),
              ),
            BridgeGlass(
              radius: 24,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed:
                                !model.fresh ||
                                    model.busy ||
                                    current?.capabilities.models != true
                                ? null
                                : () => modelDialog(context, model, s),
                            icon: const Icon(
                              CupertinoIcons.slider_horizontal_3,
                              size: 15,
                            ),
                            label: Text(
                              current?.model.isNotEmpty == true
                                  ? current!.model
                                  : s.t('Model'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ),
                      if (current?.capabilities.steer == true)
                        FilterChip(
                          label: Text(
                            s.t('Add to current task'),
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: model.steer,
                          onSelected: model.setSteer,
                        ),
                      if (current?.capabilities.stop == true)
                        IconButton(
                          onPressed: model.busy || !model.fresh
                              ? null
                              : () => model.perform((value, id) {
                                  if (value.controlToken !=
                                      current!.controlToken) {
                                    throw StateError(
                                      'The task changed; refresh before stopping',
                                    );
                                  }
                                  return model.repository.stop(current, id);
                                }),
                          tooltip: s.t('Stop task'),
                          color: colors.error,
                          icon: const Icon(CupertinoIcons.stop_circle),
                        ),
                    ],
                  ),
                  _attachmentStrip(),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        onPressed: model.canAttach && !_pickingAttachment
                            ? _pickFile
                            : null,
                        tooltip: s.t('Add attachment'),
                        icon: const Icon(CupertinoIcons.plus_circle),
                      ),
                      Expanded(
                        child: TextField(
                          key: const Key('composer'),
                          controller: _input,
                          minLines: 1,
                          maxLines: compactInput
                              ? (viewport.textScaler.scale(16) > 24 ? 1 : 2)
                              : 5,
                          maxLength: 100000,
                          enabled: model.draftEditable,
                          onChanged: model.editDraft,
                          decoration: InputDecoration(
                            hintText: s.t('Write a message…'),
                            filled: false,
                            fillColor: Colors.transparent,
                            counterText: '',
                            contentPadding: const EdgeInsets.all(14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: model.canSend && !_pickingAttachment
                            ? model.send
                            : null,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.all(14),
                          minimumSize: const Size(48, 48),
                        ),
                        child: model.busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                CupertinoIcons.arrow_up,
                                semanticLabel: s.t('Send'),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Builder(
        builder: (bodyContext) {
          final insets = MediaQuery.paddingOf(bodyContext);
          return SelectionArea(
            child: ListView.builder(
              key: const Key('chat-transcript'),
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                18,
                insets.top + 12,
                18,
                insets.bottom + 16,
              ),
              itemCount: model.messages.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    children: [
                      if (!model.fresh && !model.loadingHistory)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            s.t(
                              'History is not live control state. Refresh before taking action.',
                            ),
                            style: TextStyle(
                              color: colors.secondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (model.notice != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Text(
                            s.notice(model.notice!),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      if (current?.capabilities.resume == true)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: OutlinedButton.icon(
                            onPressed: model.busy
                                ? null
                                : () => model.perform(
                                    (value, id) =>
                                        model.repository.resume(value, id),
                                  ),
                            icon: const Icon(Icons.play_arrow),
                            label: Text(s.t('Continue session')),
                          ),
                        ),

                      Center(
                        child: model.loadingHistory
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : model.hasMoreHistory
                            ? TextButton(
                                onPressed: model.loadOlder,
                                child: Text(s.t('Older messages')),
                              )
                            : const SizedBox(height: 8),
                      ),
                    ],
                  );
                }
                return MessageCard(
                  key: ValueKey(model.messages[index - 1].id),
                  message: model.messages[index - 1],
                  session: model.selected!,
                  repository: model.repository,
                  strings: s,
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _scheduleScroll(BridgeViewModel model) {
    final rows = model.messages;
    final first = rows.firstOrNull?.id, last = rows.lastOrNull?.id;
    final length =
        (rows.lastOrNull?.text.length ?? 0) +
        (rows.lastOrNull?.output.length ?? 0);
    final newSession = _shownSession != model.selected;
    final initial = _messageCount == 0 && rows.isNotEmpty;
    final prepend =
        !newSession &&
        first != _firstMessage &&
        last == _lastMessage &&
        rows.length > _messageCount;
    final oldMax = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    final oldOffset = _scroll.hasClients ? _scroll.offset : 0.0;
    final nearEnd = !_scroll.hasClients || _scroll.position.extentAfter < 140;
    final changed = last != _lastMessage || length != _lastLength;
    _shownSession = model.selected;
    _firstMessage = first;
    _lastMessage = last;
    _messageCount = rows.length;
    _lastLength = length;
    if (!prepend && !newSession && !initial && !(nearEnd && changed)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _shownSession != model.selected) {
        return;
      }
      final position = _scroll.position;
      final target = prepend
          ? oldOffset + position.maxScrollExtent - oldMax
          : position.maxScrollExtent;
      _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
    });
  }

  bool _matchesPickerTarget(SessionSnapshot target) =>
      mounted &&
      widget.model.selected == target.session &&
      (widget.model.snapshot == null ||
          widget.model.snapshot!.accountIdentity == target.accountIdentity);

  Widget _attachmentStrip() {
    final model = widget.model, s = widget.strings;
    final selection = _pendingAttachment;
    final pending = selection != null && _matchesPickerTarget(selection.target)
        ? selection
        : null;
    if (model.attachments.isEmpty && pending == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      key: ValueKey((model.selected, model.snapshot?.accountIdentity)),
      height: 108,
      child: ListView(
        key: const Key('attachment-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        children: [
          for (final file in model.attachments)
            ComposerAttachment(
              key: ValueKey('draft-attachment-${file.id}'),
              name: file.name,
              strings: s,
              preview: file.image
                  ? GatewayImage(
                      session: model.selected!,
                      attachment: file,
                      repository: model.repository,
                      strings: s,
                      width: 104,
                      height: 76,
                      decodeSize: 320,
                      compact: true,
                    )
                  : const Icon(Icons.insert_drive_file_outlined, size: 30),
              onRemove: model.busy || _pickingAttachment || !model.draftEditable
                  ? null
                  : () => model.removeAttachment(file),
            ),
          if (pending != null)
            ComposerAttachment(
              key: const Key('pending-attachment'),
              name: pending.name,
              strings: s,
              adding: true,
              preview: pending.image && pending.bytes != null
                  ? AttachmentImage(
                      bytes: pending.bytes!,
                      name: pending.name,
                      strings: s,
                      width: 104,
                      height: 76,
                      decodeSize: 320,
                      compact: true,
                    )
                  : Icon(
                      pending.image
                          ? Icons.photo_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 30,
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    final model = widget.model, s = widget.strings;
    final current = model.snapshot;
    if (current == null || _pickingAttachment || !model.canAttach) return;
    setState(() => _pickingAttachment = true);
    try {
      final type = await showModalBottomSheet<FileType>(
        context: context,
        useRootNavigator: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const Key('pick-photo'),
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(s.t('Photos')),
                subtitle: Text(s.t('Choose a photo or screenshot')),
                onTap: () => Navigator.pop(context, FileType.image),
              ),
              if (current.capabilities.arbitraryFiles)
                ListTile(
                  key: const Key('pick-file'),
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(s.t('Files')),
                  subtitle: Text(s.t('Browse other files')),
                  onTap: () => Navigator.pop(context, FileType.any),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
      if (type == null || !_matchesPickerTarget(current)) return;
      final file = await FilePicker.pickFile(type: type);
      if (file == null || !_matchesPickerTarget(current)) return;
      const limit = 20 * 1024 * 1024;
      if ((file.lengthSync() ?? 0) > limit) {
        throw StateError('Attachment exceeds 20 MiB');
      }
      final image =
          type == FileType.image ||
          const {
            'png',
            'jpg',
            'jpeg',
            'gif',
            'webp',
          }.contains(file.extension?.toLowerCase());
      setState(() {
        _pendingAttachment = (
          target: current,
          name: file.name,
          bytes: null,
          image: image,
        );
      });
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (builder.length + chunk.length > limit) {
          throw StateError('Attachment exceeds 20 MiB');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (!_matchesPickerTarget(current)) return;
      setState(() {
        _pendingAttachment = (
          target: current,
          name: file.name,
          bytes: bytes,
          image: image,
        );
      });
      await model.attach(file.name, bytes, pickedFor: current);
    } catch (error) {
      if (_matchesPickerTarget(current)) model.reportError(error);
    } finally {
      if (mounted) {
        setState(() {
          _pickingAttachment = false;
          _pendingAttachment = null;
        });
      }
    }
  }

  Widget _approval(
    BuildContext context,
    SessionSnapshot authority,
    ApprovalRequest request,
  ) {
    final model = widget.model, s = widget.strings;
    Future<void> respond(bool accept) async {
      if (request.kind != ApprovalKind.questions) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s.t('Review request')),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: SelectableText(
                  request.detail,
                  style: const TextStyle(fontFamily: 'PlexMono', fontSize: 12),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.t('Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.t(accept ? 'Accept once' : 'Decline')),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      if (!context.mounted) return;
      final answers = request.kind == ApprovalKind.questions && accept
          ? await answerDialog(context, request, s)
          : <QuestionAnswer>[];
      if (answers == null) return;
      await model.perform((current, id) {
        if (current.controlToken != authority.controlToken ||
            !current.approvals.any(
              (value) =>
                  value.id == request.id &&
                  value.fingerprint == request.fingerprint,
            )) {
          throw StateError(
            'This approval changed or expired. Read the current request first',
          );
        }
        return model.repository.respond(
          authority,
          id,
          request,
          accept,
          answers,
        );
      });
    }

    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.t('Approval'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              request.detail.isEmpty ? request.title : request.detail,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'PlexMono', fontSize: 11),
            ),
            if (!request.supported)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(s.t('Handle this request on the computer.')),
              ),
            Wrap(
              spacing: 10,
              children: [
                if (request.canDecline)
                  TextButton(
                    onPressed: model.busy ? null : () => respond(false),
                    child: Text(s.t('Decline')),
                  ),
                if (request.canAccept)
                  FilledButton(
                    onPressed: model.busy ? null : () => respond(true),
                    child: Text(
                      s.t(
                        request.kind == ApprovalKind.questions
                            ? 'Answer'
                            : 'Accept once',
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pending(BuildContext context) async {
    final s = widget.strings, operations = [...widget.model.pending];
    final authority = widget.model.snapshot;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('Pending verification')),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.t(
                    'This operation may already have been submitted. It will never be replayed automatically.',
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  s.t(
                    'Only confirm after checking the original conversation. This does not resend anything or claim that the operation succeeded.',
                  ),
                ),
                for (final operation in operations)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(operation.action),
                    subtitle: Text(
                      operation.id,
                      style: const TextStyle(
                        fontFamily: 'PlexMono',
                        fontSize: 10,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: s.t('I checked on the computer'),
                      icon: const Icon(Icons.check_circle_outline),
                      onPressed: () async {
                        Navigator.pop(context);
                        try {
                          await widget.model.markReviewed(
                            operation,
                            authority: authority,
                          );
                        } catch (error) {
                          widget.model.reportError(error);
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.t('Cancel')),
          ),
        ],
      ),
    );
  }
}
