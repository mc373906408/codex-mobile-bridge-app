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
import '../business/session_controls.dart';
import '../business/context_usage.dart';

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
  late final SessionRef? Function() _activityVisibility;
  String? _firstMessage;
  String? _lastMessage;
  int _lastLength = 0;
  int _messageCount = 0;
  bool _pickingAttachment = false, _composerCollapsed = false;
  ({SessionSnapshot target, String name, Uint8List? bytes, bool image})?
  _pendingAttachment;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_queueReadingPosition);
    _activityVisibility = () =>
        mounted &&
            TickerMode.valuesOf(context).enabled &&
            ModalRoute.of(context)?.isCurrent != false &&
            !_workspaceVisible
        ? widget.model.selected
        : null;
    widget.model.visibleActivitySession = _activityVisibility;
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
    if (identical(widget.model.visibleActivitySession, _activityVisibility)) {
      widget.model.visibleActivitySession = null;
    }
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) model.acknowledgeVisibleActivity();
    });
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
    if (current != null &&
        (_workspaceScope?.session != current.session ||
            _workspaceScope?.snapshot.accountIdentity !=
                current.accountIdentity ||
            _workspaceScope?.connection != model.connectionGeneration)) {
      _workspaceScope?.dispose();
      _workspaceScope = SessionBusiness(model, current);
    }
    final header = BridgeGlass(
      style: BridgeGlassStyle.regular,
      radius: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                if (widget.showBack)
                  IconButton(
                    onPressed: model.busy ? null : model.backToSessions,
                    tooltip: s.t('Back to conversations'),
                    icon: const Icon(CupertinoIcons.chevron_back),
                  ),
                Image.asset(
                  'assets/client-icons/${model.selected!.provider.name}.png',
                  width: 22,
                  height: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    current?.title ?? s.t('Reading history…'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (model.presentation['showActivity'] != false &&
                    constraints.maxWidth > 350 &&
                    viewport.textScaler.scale(14) < 21)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      s.t(
                        model.connectingSession
                            ? 'Connecting…'
                            : !model.fresh
                            ? 'Offline'
                            : current?.connected != true
                            ? 'History only'
                            : current!.running
                            ? 'Running'
                            : 'Live',
                      ),
                      style: TextStyle(fontSize: 10, color: colors.primary),
                    ),
                  ),
                IconButton(
                  tooltip: words(context, '聊天工具', 'Chat tools'),
                  icon: const Icon(Icons.more_horiz),
                  onPressed: current == null || model.busy
                      ? null
                      : () => sessionActions(context, model, model.selected!),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 10),
                _chatTab(
                  words(context, '聊天', 'Chat'),
                  !_workspaceVisible,
                  () => setState(() => _workspaceVisible = false),
                ),
                if (_workspaceVisible) ...[
                  const SizedBox(width: 4),
                  _chatTab(
                    words(context, '工作台', 'Workspace'),
                    true,
                    () => setState(() => _workspaceVisible = true),
                  ),
                ],
                const Spacer(),
                IconButton(
                  tooltip: words(context, '打开工作台', 'Open workspace'),
                  onPressed: current == null
                      ? null
                      : () => setState(() => _workspaceVisible = true),
                  icon: const Icon(Icons.add),
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
    final headerHeight =
        106.0 + (viewport.textScaler.scale(17) - 17).clamp(0, 24);
    // Web-style chrome reserves its own space so no transcript text competes
    // with controls. Glass remains a decoration around the tool surfaces.
    final chat = Scaffold(
      primary: false,
      resizeToAvoidBottomInset: false,
      extendBody: false,
      extendBodyBehindAppBar: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(headerHeight),
        child: header,
      ),
      bottomNavigationBar: _workspaceVisible && constraints.maxWidth < 1000
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (model.connectingSession)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        key: const Key('session-connecting'),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              s.t('Connecting to session…'),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (current?.connected == false &&
                      current?.capabilities.resume == true &&
                      !model.hasPendingSessionConnection)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: OutlinedButton.icon(
                        key: const Key('retry-session-connection'),
                        onPressed: model.canConnectSession
                            ? model.connectSession
                            : null,
                        icon: const Icon(Icons.refresh),
                        label: Text(s.t('Retry connection')),
                      ),
                    ),
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
                  if (model.fresh &&
                      current != null &&
                      current.approvals.isNotEmpty)
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
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
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
                    style: BridgeGlassStyle.regular,
                    radius: 14,
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Divider(height: 1),
                        const SizedBox(height: 8),
                        _composerToolbar(context, current),
                        const SizedBox(height: 8),
                        if (!_composerCollapsed) ...[
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
                                        textValue(
                                          model.quotes[index]['source'],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: IconButton(
                                        onPressed: model.busy
                                            ? null
                                            : () {
                                                final values = model.quotes
                                                  ..removeAt(index);
                                                model.setDraftOption(
                                                  'quotes',
                                                  values,
                                                );
                                              },
                                        icon: const Icon(Icons.close),
                                        tooltip: words(
                                          context,
                                          '移除引用',
                                          'Remove quote',
                                        ),
                                      ),
                                      children: [
                                        SelectableText(
                                          textValue(
                                            model.quotes[index]['text'],
                                          ),
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
                                          .where(
                                            (r) => r['path'] != ref['path'],
                                          )
                                          .toList(),
                                    ),
                                  ),
                              ],
                            ),
                          TextField(
                            key: const Key('composer'),
                            controller: _input,
                            minLines: compactInput ? 1 : 2,
                            maxLines: compactInput
                                ? (viewport.textScaler.scale(16) > 24 ? 1 : 2)
                                : 5,
                            maxLength: 100000,
                            enabled: model.draftEditable,
                            onChanged: model.editDraft,
                            style: const TextStyle(fontSize: 16),
                            decoration: InputDecoration(
                              hintText: s.t('Write a message…'),
                              counterText: '',
                              filled: true,
                              fillColor: colors.surfaceContainerLow,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: colors.outlineVariant,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: colors.outlineVariant,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          _sendActions(context, current),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
      body: IndexedStack(
        index: _workspaceVisible && constraints.maxWidth < 1000 ? 1 : 0,
        children: [
          Builder(
            builder: (bodyContext) {
              final insets = MediaQuery.paddingOf(bodyContext);
              return SelectionArea(
                child: ListView.builder(
                  key: const Key('chat-transcript'),
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(
                    20,
                    insets.top + 12,
                    20,
                    insets.bottom + 16,
                  ),
                  itemCount:
                      model.messages.length +
                      1 +
                      (current?.running == true ? 1 : 0),
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
                    if (index > model.messages.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Row(
                          children: [
                            Icon(Icons.circle, size: 7, color: colors.primary),
                            const SizedBox(width: 8),
                            Text(
                              words(
                                context,
                                "${providerName(model.selected!.provider)} 正在工作…",
                                "${providerName(model.selected!.provider)} is working…",
                              ),
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
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
          if (_workspaceVisible &&
              constraints.maxWidth < 1000 &&
              _workspaceScope != null)
            WorkspacePage(
              embedded: true,
              scope: _workspaceScope!,
              onClose: () => setState(() => _workspaceVisible = false),
            )
          else
            const SizedBox.shrink(),
        ],
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

  Widget _chatTab(String label, bool selected, VoidCallback onTap) {
    final colors = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: selected ? colors.onSurface : colors.onSurfaceVariant,
        backgroundColor: selected
            ? colors.surfaceContainerLow
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: selected
              ? BorderSide(color: colors.outlineVariant)
              : BorderSide.none,
        ),
      ),
      child: Text(label),
    );
  }

  Widget _composerToolbar(BuildContext context, SessionSnapshot? current) {
    final model = widget.model, s = widget.strings;
    final colors = Theme.of(context).colorScheme;
    final metadata = jsonObject(current?.metadata);
    final state = metadata['session'] is Map
        ? jsonObject(metadata['session'])
        : metadata;
    Widget pill(String title, VoidCallback? onTap, {double maxWidth = 180}) =>
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              shape: const StadiumBorder(),
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontSize: 12),
            ),
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        );
    final ready = model.fresh && !model.busy && current != null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          pill(
            [
              current?.model.isNotEmpty == true ? current!.model : s.t('Model'),
              if (current?.effort.isNotEmpty == true) current!.effort,
            ].join(' · '),
            ready && current.capabilities.models
                ? () => modelDialog(context, model, s)
                : null,
            maxWidth: (MediaQuery.sizeOf(context).width - 246).clamp(90, 180),
          ),
          const SizedBox(width: 6),
          if (current != null) ...[
            pill(
              'Skill',
              ready
                  ? () => _withScope(
                      (scope) => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SkillPickerPage(scope: scope),
                        ),
                      ),
                    )
                  : null,
              maxWidth: 52,
            ),
            const SizedBox(width: 6),
            pill(
              textValue(state['permissionLabel']).isNotEmpty
                  ? textValue(state['permissionLabel'])
                  : words(context, '权限', 'Permissions'),
              ready
                  ? () => _withScope(
                      (scope) => sessionPermissions(context, scope),
                    )
                  : null,
              maxWidth: 64,
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: words(context, '上下文用量', 'Context usage'),
              style: IconButton.styleFrom(
                minimumSize: const Size(36, 36),
                padding: const EdgeInsets.all(6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: BorderSide(color: colors.outlineVariant),
              ),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  content: SingleChildScrollView(
                    child: ContextUsageCard(state: state),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(s.t('Close')),
                    ),
                  ],
                ),
              ),
              icon: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  value: _contextRatio(state),
                  strokeWidth: 3,
                  backgroundColor: colors.outlineVariant,
                ),
              ),
            ),
          ],
          IconButton(
            style: IconButton.styleFrom(
              minimumSize: const Size(36, 36),
              padding: const EdgeInsets.all(6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            tooltip: words(
              context,
              _composerCollapsed ? '展开输入区' : '收起输入区',
              _composerCollapsed ? 'Expand composer' : 'Collapse composer',
            ),
            onPressed: () =>
                setState(() => _composerCollapsed = !_composerCollapsed),
            icon: Icon(
              _composerCollapsed
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
            ),
          ),
        ],
      ),
    );
  }

  double? _contextRatio(Json state) {
    final usage = jsonObject(state['contextUsage']);
    final used = usage['usedTokens'], total = usage['contextWindow'];
    return used is num && total is num && total > 0
        ? (used / total).clamp(0, 1).toDouble()
        : 0;
  }

  Future<void> _withScope(Future<void> Function(SessionBusiness) task) async {
    final snapshot = widget.model.snapshot;
    if (snapshot == null) return;
    final scope = SessionBusiness(widget.model, snapshot);
    try {
      await task(scope);
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      scope.dispose();
    }
  }

  Widget _sendActions(BuildContext context, SessionSnapshot? current) {
    final model = widget.model, s = widget.strings;
    final enabled = model.draftEditable && !model.busy;
    final modes = <String, String>{
      'send': words(context, '发送新消息', 'New message'),
      if (model.queueAvailable)
        'queue': words(context, '排队发送', 'Queue message'),
      if (current?.capabilities.steer == true)
        'steer': words(context, '补充当前任务', 'Steer current task'),
    };
    final raw = jsonObject(current?.metadata);
    final state = raw['session'] is Map ? jsonObject(raw['session']) : raw;
    final caps = jsonObject(raw['capabilities'] ?? state['capabilities']);
    final access = jsonObject(state['access']);
    final workModes = <String, String>{
      'default': words(context, '普通模式', 'Normal mode'),
      if (caps['plan'] != false) 'plan': words(context, '计划模式', 'Plan mode'),
      if (caps['goal'] == true ||
          current?.session.provider == Provider.codex &&
              access['canUseGoal'] == true &&
              state['goalRuntimeAvailable'] != false)
        'goal': words(context, '目标模式', 'Goal mode'),
    };
    Widget select(
      String label,
      Map<String, String> choices,
      ValueChanged<String> choose, {
      bool active = true,
    }) => PopupMenuButton<String>(
      enabled: enabled && active,
      tooltip: label,
      onSelected: choose,
      itemBuilder: (_) => [
        for (final row in choices.entries)
          PopupMenuItem(value: row.key, child: Text(row.value)),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, size: 14),
          ],
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth < 340 ||
            MediaQuery.textScalerOf(context).scale(13) > 18;
        final selection = <Widget>[
          IconButton(
            onPressed: model.canAttach && !_pickingAttachment
                ? _pickFile
                : null,
            tooltip: s.t('Add attachment'),
            icon: const Icon(Icons.attach_file, size: 22),
          ),
          Expanded(
            child: select(
              modes[model.sendMode] ?? modes['send']!,
              modes,
              (value) => model.setDraftOption('mode', value),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: select(
              workModes[textValue(
                    model.draftOptions['workMode'] ?? 'default',
                  )] ??
                  workModes['default']!,
              workModes,
              (value) => model.setDraftOption('workMode', value),
              active: model.sendMode != 'steer',
            ),
          ),
          const SizedBox(width: 6),
        ];
        final actions = <Widget>[
          if (current?.capabilities.stop == true) ...[
            TextButton(
              onPressed: !model.fresh || model.busy
                  ? null
                  : () => model.perform((value, id) {
                      if (value.controlToken != current!.controlToken) {
                        throw StateError(
                          'The task changed; refresh before stopping',
                        );
                      }
                      return model.repository.stop(current, id);
                    }),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.stop, size: 14),
                  Text(
                    words(context, '停止', 'Stop'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ],
          FilledButton(
            onPressed: model.canSend && !_pickingAttachment ? model.send : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size(52, 40),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontSize: 13),
            ),
            child: model.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('${s.t('Send')} ↑'),
          ),
        ];
        return stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: selection),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions,
                  ),
                ],
              )
            : Row(children: [...selection, ...actions]);
      },
    );
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
