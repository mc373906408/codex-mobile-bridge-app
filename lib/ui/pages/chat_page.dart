import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../l10n/strings.dart';
import '../design/bridge_theme.dart';
import '../dialogs.dart';

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../attachment_preview.dart';
import '../message_card.dart';
import '../provider_name.dart';
import '../design/bridge_mark.dart';
import '../business/session_actions.dart';
import '../business/common.dart';
import '../business/approval_page.dart';
import '../business/workspace_page.dart';

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
  String? _shownView;
  Timer? _readingTimer;
  ({String key, Json position})? _pendingReading;
  bool _restoringReading = false, _workspaceVisible = false;
  SessionBusiness? _workspaceScope;
  String? _firstMessage;
  String? _lastMessage;
  int _lastLength = 0;
  int _messageCount = 0;
  bool _pickingAttachment = false;
  ({SessionSnapshot target, String name, Uint8List? bytes, bool image})?
  _pendingAttachment;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_queueReadingPosition);
  }

  void _queueReadingPosition() {
    if (_restoringReading || _shownView == null || !_scroll.hasClients) return;
    final key = _shownView!, position = _scroll.offset;
    final oldest = widget.model.messages.firstOrNull?.id;
    _readingTimer?.cancel();
    _pendingReading = (
      key: key,
      position: {'offset': position, 'oldest': oldest},
    );
    _readingTimer = Timer(const Duration(milliseconds: 500), _saveReading);
  }

  void _saveReading() {
    _readingTimer?.cancel();
    final value = _pendingReading;
    _pendingReading = null;
    if (value != null) {
      widget.model.rememberView('readingPositions', value.key, value.position);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _saveReading();
    _workspaceScope?.dispose();
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
                  if (model.presentation['showComputer'] != false)
                    const SizedBox(height: 4),
                  if (model.presentation['showComputer'] != false)
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
          if (model.presentation['showActivity'] != false &&
              MediaQuery.sizeOf(context).width > 360 &&
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
          IconButton(
            tooltip: words(context, '聊天工具', 'Chat tools'),
            icon: const Icon(Icons.more_horiz),
            onPressed: current == null || model.busy
                ? null
                : () => sessionActions(context, model, model.selected!),
          ),
          if (constraints.maxWidth >= 1000)
            IconButton(
              tooltip: words(
                context,
                '并排打开工作台',
                'Open workspace alongside chat',
              ),
              icon: const Icon(Icons.view_sidebar_outlined),
              onPressed: current == null
                  ? null
                  : () =>
                        setState(() => _workspaceVisible = !_workspaceVisible),
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
    final chat = Scaffold(
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
            if (model.notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Text(
                  s.notice(model.notice!),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (model.fresh && current != null && current.approvals.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .27,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final request in current.approvals)
                      Card(
                        child: ListTile(
                          title: Text(request.title),
                          subtitle: Text(
                            request.detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: model.busy
                              ? null
                              : () => reviewApproval(
                                  context,
                                  model,
                                  current,
                                  request,
                                ),
                        ),
                      ),
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
                  if (model.quotes.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .2,
                      ),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (
                            var index = 0;
                            index < model.quotes.length;
                            index++
                          )
                            ExpansionTile(
                              title: Text(
                                textValue(model.quotes[index]['text']),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                textValue(model.quotes[index]['source']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                onPressed: model.busy
                                    ? null
                                    : () {
                                        final values = model.quotes
                                          ..removeAt(index);
                                        model.setDraftOption('quotes', values);
                                      },
                                icon: const Icon(Icons.close),
                                tooltip: words(context, '移除引用', 'Remove quote'),
                              ),
                              children: [
                                SelectableText(
                                  textValue(model.quotes[index]['text']),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  if (model.fileReferences.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final ref in model.fileReferences)
                          InputChip(
                            label: Text(textValue(ref['path'])),
                            onDeleted: () => model.setDraftOption(
                              'references',
                              model.fileReferences
                                  .where((r) => r['path'] != ref['path'])
                                  .toList(),
                            ),
                          ),
                      ],
                    ),
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
                  model: model,
                );
              },
            ),
          );
        },
      ),
    );
    if (constraints.maxWidth >= 1000 && current != null && _workspaceVisible) {
      if (_workspaceScope?.session != current.session ||
          _workspaceScope?.snapshot.accountIdentity !=
              current.accountIdentity ||
          _workspaceScope?.connection != model.connectionGeneration) {
        _workspaceScope?.dispose();
        _workspaceScope = SessionBusiness(model, current);
      }
      return Row(
        children: [
          Expanded(child: chat),
          const VerticalDivider(width: 1),
          Expanded(
            child: WorkspacePage(
              key: ValueKey(model.viewKey(current)),
              scope: _workspaceScope!,
              onClose: () => setState(() => _workspaceVisible = false),
            ),
          ),
        ],
      );
    }
    return chat;
  }

  void _scheduleScroll(BridgeViewModel model) {
    final rows = model.messages;
    final first = rows.firstOrNull?.id, last = rows.lastOrNull?.id;
    final length =
        (rows.lastOrNull?.text.length ?? 0) +
        (rows.lastOrNull?.output.length ?? 0);
    final view = model.snapshot == null ? null : model.viewKey(model.snapshot!);
    final newSession = _shownSession != model.selected || _shownView != view;
    if (newSession) _saveReading();
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
    _shownView = view;
    _firstMessage = first;
    _lastMessage = last;
    _messageCount = rows.length;
    _lastLength = length;
    if (_restoringReading) return;
    if ((newSession || initial) && view != null) {
      final saved = jsonObject(
        jsonObject(model.presentation['readingPositions'])[view],
      );
      if (saved['offset'] is num) {
        _restoringReading = true;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            final oldest = saved['oldest'];
            while (mounted &&
                _shownView == view &&
                model.hasMoreHistory &&
                !model.loadingHistory &&
                oldest != null &&
                !model.messages.any((m) => m.id == oldest)) {
              final count = model.messages.length;
              await model.loadOlder();
              if (model.messages.length <= count) break;
            }
            await WidgetsBinding.instance.endOfFrame;
            if (mounted && _shownView == view && _scroll.hasClients) {
              _scroll.jumpTo(
                (saved['offset'] as num).toDouble().clamp(
                  0,
                  _scroll.position.maxScrollExtent,
                ),
              );
            }
          } finally {
            _restoringReading = false;
          }
        });
        return;
      }
    }
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
