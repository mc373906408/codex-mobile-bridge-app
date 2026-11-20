import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../data/chat_attachment_preparation.dart';
import '../../l10n/strings.dart';
import '../design/bridge_theme.dart';
import '../dialogs.dart';

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../attachment_preview.dart';
import '../chat_photo_editor.dart';
import '../message_card.dart';
import '../activity_summary.dart';
import '../business/appearance_settings.dart';
import '../provider_name.dart';
import '../design/bridge_mark.dart';
import '../business/session_actions.dart';
import '../business/common.dart';
import '../business/approval_page.dart';
import '../business/workspace_tools.dart';
import '../business/skill_picker.dart';
import '../business/session_permissions.dart';
import '../business/context_usage.dart';
import 'chat_transcript.dart';

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
  (int, SessionRef?, String?, String?)? _transcriptScope;
  SessionBusiness? _workspaceScope;
  WorkspaceTool? _activeTool;
  final _workspaceTabs = <WorkspaceTool>{};
  final _mountedTools = <WorkspaceTool>{};
  final _toolKeys = {
    for (final tool in WorkspaceTool.values) tool: GlobalKey(),
  };
  bool _choosingTool = false, _chatVisible = true;
  late final SessionRef? Function() _activityVisibility;
  bool _pickingAttachment = false, _composerCollapsed = false;
  final _expandedActivities = <String>{};
  ({SessionSnapshot target, String name, bool image})? _pendingAttachment;
  @override
  void initState() {
    super.initState();
    _activityVisibility = () =>
        mounted &&
            TickerMode.valuesOf(context).enabled &&
            ModalRoute.of(context)?.isCurrent != false &&
            _chatVisible
        ? widget.model.selected
        : null;
    widget.model.visibleActivitySession = _activityVisibility;
  }

  @override
  void dispose() {
    if (identical(widget.model.visibleActivitySession, _activityVisibility)) {
      widget.model.visibleActivitySession = null;
    }
    _input.dispose();
    _workspaceScope?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildContent);

  void _updateWorkspace(SessionSnapshot? snapshot) {
    final scope = _workspaceScope;
    final model = widget.model;
    if (snapshot == null ||
        scope?.session != snapshot.session ||
        scope?.snapshot.accountIdentity != snapshot.accountIdentity ||
        scope?.connection != model.connectionGeneration) {
      scope?.dispose();
      _workspaceScope = snapshot == null
          ? null
          : SessionBusiness(model, snapshot);
      _activeTool = null;
      _mountedTools.clear();
      _workspaceTabs.clear();
      if (snapshot != null) {
        final saved = jsonObject(
          model.presentation['chatToolTabs'],
        )[model.viewKey(snapshot)];
        if (saved is List) {
          for (final name in saved) {
            final tool = WorkspaceTool.values
                .where((tool) => tool.name == name)
                .firstOrNull;
            if (tool != null) _workspaceTabs.add(tool);
          }
        }
      }
    } else if (scope != null) {
      scope.snapshot = snapshot;
    }
  }

  void _rememberWorkspaceTabs(SessionBusiness scope) {
    widget.model.rememberView(
      'chatToolTabs',
      widget.model.viewKey(scope.snapshot),
      _workspaceTabs.map((tool) => tool.name).toList(),
    );
  }

  Future<void> _chooseTool(SessionBusiness scope) async {
    if (_choosingTool || !scope.current) return;
    final generation = widget.model.selectionGeneration;
    _choosingTool = true;
    try {
      final tool = await chooseWorkspaceTool(context, scope);
      if (tool == null ||
          !mounted ||
          _workspaceScope != scope ||
          generation != widget.model.selectionGeneration ||
          widget.model.snapshot?.accountIdentity !=
              scope.snapshot.accountIdentity ||
          !scope.current ||
          !tool.available(scope)) {
        return;
      }
      if (_workspaceTabs.add(tool)) _rememberWorkspaceTabs(scope);
      _selectTool(tool);
    } finally {
      _choosingTool = false;
    }
  }

  void _selectTool(WorkspaceTool? tool) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _activeTool = tool;
      if (tool != null) _mountedTools.add(tool);
    });
    if (tool != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _toolKeys[tool]?.currentContext;
        if (mounted && _activeTool == tool && context != null) {
          Scrollable.ensureVisible(context);
        }
      });
    }
  }

  void _closeTool(SessionBusiness scope, WorkspaceTool tool) {
    if (_activeTool == tool) _selectTool(null);
    setState(() {
      _workspaceTabs.remove(tool);
      _mountedTools.remove(tool);
    });
    _rememberWorkspaceTabs(scope);
  }

  Widget _buildContent(BuildContext context, BoxConstraints constraints) {
    final model = widget.model,
        s = widget.strings,
        current = widget.model.snapshot;
    final preview = model.chatPreview;
    final session = model.selected;
    _updateWorkspace(
      model.authenticated && model.foreground && current?.session == session
          ? current
          : null,
    );
    final scope = _workspaceScope;
    final tools = [
      if (scope != null)
        for (final tool in _workspaceTabs)
          if (tool.available(scope)) tool,
    ];
    if (!tools.contains(_activeTool)) _activeTool = null;
    _mountedTools.retainAll(tools);
    final activeTool = _activeTool;
    final split = activeTool != null && constraints.maxWidth >= 1000;
    final chatVisible = activeTool == null || split;
    _chatVisible = chatVisible;
    final syncing = current == null && model.loadingHistory;
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.of(context);
    final compactInput = constraints.maxHeight < 500;
    final transcriptScope = (
      model.selectionGeneration,
      session,
      current?.accountIdentity ?? preview?.account,
      current?.history.epoch ?? preview?.epoch,
    );
    if (_transcriptScope != transcriptScope) {
      _transcriptScope = transcriptScope;
      _expandedActivities.clear();
    }
    final transcript = groupTranscriptRows(
      preview?.messages ?? model.messages,
      ChatAppearanceScope.of(context),
    );
    final running =
        model.foreground &&
        model.authenticated &&
        model.fresh &&
        current?.connected == true &&
        current?.running == true &&
        current!.approvals.isEmpty;
    final activeRow =
        running &&
        transcript.isNotEmpty &&
        (transcript.last.activity || transcript.last.reconnect != null) &&
        transcript.last.belongsToRunningTurn(current);
    final rowKeys = [
      for (final row in transcript)
        if (row.reconnect != null)
          ValueKey(('reconnect', row.messages.first.id))
        else if (row.activity)
          ValueKey(('activity', row.messages.first.id))
        else
          ValueKey(row.messages.single.id),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) model.acknowledgeVisibleActivity();
    });
    if (_input.text != model.draftText) {
      _input.value = TextEditingValue(
        text: model.draftText,
        selection: TextSelection.collapsed(offset: model.draftText.length),
      );
    }
    if (session == null) {
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
                    onPressed: model.busy
                        ? null
                        : chatVisible
                        ? model.backToSessions
                        : () => _selectTool(null),
                    tooltip: chatVisible
                        ? s.t('Back to conversations')
                        : words(context, '返回聊天', 'Back to chat'),
                    icon: const Icon(CupertinoIcons.chevron_back),
                  ),
                Image.asset(
                  'assets/client-icons/${session.provider.name}.png',
                  width: 22,
                  height: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    current?.title ??
                        preview?.title ??
                        model.sessions
                            .where((row) => row.session == session)
                            .firstOrNull
                            ?.title ??
                        s.t('Reading history…'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (preview != null ||
                    model.presentation['showActivity'] != false &&
                        constraints.maxWidth > 350 &&
                        viewport.textScaler.scale(14) < 21)
                  Container(
                    constraints: const BoxConstraints(maxWidth: 116),
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
                            : syncing
                            ? 'Syncing…'
                            : !model.fresh
                            ? 'Offline'
                            : current?.connected != true
                            ? 'History only'
                            : current!.running
                            ? 'Running'
                            : 'Live',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: colors.primary),
                    ),
                  ),
                IconButton(
                  tooltip: words(context, '聊天工具', 'Chat tools'),
                  icon: const Icon(Icons.more_horiz),
                  onPressed: current == null || model.busy
                      ? null
                      : () => sessionActions(context, model, session),
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
                  chatVisible,
                  () => _selectTool(null),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      spacing: 4,
                      children: [
                        if (scope != null)
                          for (final tool in tools)
                            _workspaceTab(context, scope, tool),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: words(context, '新标签页', 'New tab'),
                  onPressed: scope == null ? null : () => _chooseTool(scope),
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
    final chat = Scaffold(
      primary: false,
      resizeToAvoidBottomInset: true,
      extendBody: false,
      extendBodyBehindAppBar: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      bottomNavigationBar: !chatVisible
          ? null
          : BridgeGlass(
              style: BridgeGlassStyle.regular,
              framed: false,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: LayoutBuilder(
                builder: (context, composerBounds) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      child: SingleChildScrollView(
                        primary: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
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
                                          trailing: const Icon(
                                            Icons.chevron_right,
                                          ),
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
                            const Divider(height: 1),
                            const SizedBox(height: 10),
                            _composerToolbar(context, current),
                            const SizedBox(height: 8),
                            if (!_composerCollapsed)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: constraints.maxHeight * .23,
                                ),
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _attachmentStrip(),
                                      if (model.quotes.isNotEmpty)
                                        ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxHeight:
                                                constraints.maxHeight * .2,
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
                                                    textValue(
                                                      model
                                                          .quotes[index]['text'],
                                                    ),
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  subtitle: Text(
                                                    textValue(
                                                      model
                                                          .quotes[index]['source'],
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  trailing: IconButton(
                                                    onPressed: model.busy
                                                        ? null
                                                        : () {
                                                            final values =
                                                                model.quotes
                                                                  ..removeAt(
                                                                    index,
                                                                  );
                                                            model
                                                                .setDraftOption(
                                                                  'quotes',
                                                                  values,
                                                                );
                                                          },
                                                    icon: const Icon(
                                                      Icons.close,
                                                    ),
                                                    tooltip: words(
                                                      context,
                                                      '移除引用',
                                                      'Remove quote',
                                                    ),
                                                  ),
                                                  children: [
                                                    SelectableText(
                                                      textValue(
                                                        model
                                                            .quotes[index]['text'],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                            ],
                                          ),
                                        ),
                                      if (model.fileReferences.isNotEmpty)
                                        ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxHeight:
                                                MediaQuery.viewInsetsOf(context)
                                                        .bottom >
                                                    0
                                                ? 44
                                                : 76,
                                          ),
                                          child: SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: Row(
                                              children: [
                                                for (final ref
                                                    in model.fileReferences)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          right: 6,
                                                        ),
                                                    child: InputChip(
                                                      label: Text(
                                                        textValue(ref['path']),
                                                      ),
                                                      onDeleted: () =>
                                                          model.setDraftOption(
                                                            'references',
                                                            model.fileReferences
                                                                .where(
                                                                  (r) =>
                                                                      r['path'] !=
                                                                      ref['path'],
                                                                )
                                                                .toList(),
                                                          ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (!_composerCollapsed)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: composerBounds.maxHeight,
                        ),
                        child: SingleChildScrollView(
                          primary: false,
                          reverse: true,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                key: const Key('composer'),
                                controller: _input,
                                minLines: 1,
                                maxLines: compactInput
                                    ? (viewport.textScaler.scale(16) > 24
                                          ? 1
                                          : 2)
                                    : 5,
                                maxLength: 100000,
                                enabled: model.draftEditable,
                                onChanged: model.editDraft,
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.4,
                                ),
                                decoration: InputDecoration(
                                  hintText: s.t('Write a message…'),
                                  counterText: '',
                                  isDense: true,
                                  constraints: const BoxConstraints(
                                    minHeight: 44,
                                  ),
                                  filled: true,
                                  fillColor: colors.surfaceContainerLow,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
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
                              const SizedBox(height: 10),
                              _sendActions(context, current),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
      body: current == null && !syncing
          ? Center(
              child: OutlinedButton.icon(
                onPressed: model.authenticated && !model.busy
                    ? () => model.openSession(session)
                    : null,
                icon: const Icon(Icons.refresh),
                label: Text(s.t('Retry')),
              ),
            )
          : ChatTranscript(
              key: ValueKey(transcriptScope),
              rowKeys: rowKeys,
              onOlderEdge: model.canLoadOlder
                  ? () {
                      if (model.selectionGeneration == transcriptScope.$1 &&
                          _chatVisible) {
                        model.loadOlder();
                      }
                    }
                  : null,
              oldest: Column(
                children: [
                  if (!model.fresh && !model.loadingHistory)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        s.t(
                          'History is not live control state. Refresh before taking action.',
                        ),
                        style: TextStyle(color: colors.secondary, fontSize: 12),
                      ),
                    ),
                  if ((model.hasMoreHistory || model.loadingHistory) &&
                      preview == null)
                    SizedBox(
                      height: 28,
                      child: model.loadingHistory
                          ? Center(
                              child: SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  semanticsLabel: s.t('Reading history…'),
                                ),
                              ),
                            )
                          : null,
                    )
                  else
                    const SizedBox(height: 8),
                ],
              ),
              newest: running && !activeRow
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: WorkActivityLabel(
                        running: true,
                        label: words(
                          context,
                          '${providerName(session.provider)} 正在思考…',
                          '${providerName(session.provider)} is thinking…',
                        ),
                      ),
                    )
                  : null,
              rowBuilder: (context, index) {
                final row = transcript[index], rowKey = rowKeys[index];
                final rowRunning = activeRow && index == transcript.length - 1;
                if (row.reconnect != null) {
                  return ReconnectStatusRow(
                    key: rowKey,
                    status: row.reconnect!,
                    running: rowRunning,
                  );
                }
                if (row.activity) {
                  final expanded = row.messages.any(
                    (message) => _expandedActivities.contains(message.id),
                  );
                  return ActivitySummary(
                    key: rowKey,
                    messages: row.messages,
                    running: rowRunning,
                    expanded: expanded,
                    onToggle: () => setState(() {
                      if (expanded) {
                        _expandedActivities.removeAll(
                          row.messages.map((message) => message.id),
                        );
                      } else {
                        _expandedActivities.add(row.messages.first.id);
                      }
                    }),
                    detailsBuilder: (_) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final message in row.messages)
                          MessageCard(
                            key: ValueKey(message.id),
                            message: message,
                            compactActivity: true,
                            session: session,
                            repository: model.repository,
                            strings: s,
                            model: preview == null ? model : null,
                          ),
                      ],
                    ),
                  );
                }
                return MessageCard(
                  key: rowKey,
                  message: row.messages.single,
                  session: session,
                  repository: model.repository,
                  strings: s,
                  model: preview == null ? model : null,
                );
              },
            ),
    );
    final paneWidth = (constraints.maxWidth - 1) / 2;
    return Scaffold(
      primary: false,
      resizeToAvoidBottomInset: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(headerHeight),
        child: header,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            right: split ? paneWidth + 1 : 0,
            child: Offstage(
              offstage: !chatVisible,
              child: TickerMode(
                enabled: chatVisible,
                child: ExcludeFocus(excluding: !chatVisible, child: chat),
              ),
            ),
          ),
          if (split)
            Positioned(
              left: paneWidth,
              top: 0,
              bottom: 0,
              child: const VerticalDivider(width: 1),
            ),
          if (scope != null)
            Positioned.fill(
              key: ValueKey(scope),
              left: split ? paneWidth + 1 : 0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final tool in _mountedTools)
                    Offstage(
                      key: ValueKey(tool),
                      offstage: tool != activeTool,
                      child: TickerMode(
                        enabled: tool == activeTool,
                        child: ExcludeFocus(
                          excluding: tool != activeTool,
                          child: Material(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            child: tool.panel(
                              scope,
                              active: tool == activeTool,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _workspaceTab(
    BuildContext context,
    SessionBusiness scope,
    WorkspaceTool tool,
  ) {
    final selected = tool == _activeTool;
    final colors = Theme.of(context).colorScheme;
    final label = tool.label(context);
    return DecoratedBox(
      key: _toolKeys[tool],
      decoration: BoxDecoration(
        color: selected ? colors.surfaceContainerLow : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? colors.outlineVariant : Colors.transparent,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            selected: selected,
            child: TextButton(
              onPressed: () => _selectTool(tool),
              style: TextButton.styleFrom(
                foregroundColor: selected
                    ? colors.onSurface
                    : colors.onSurfaceVariant,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 40),
              ),
              child: Text(label, maxLines: 1),
            ),
          ),
          IconButton(
            tooltip: words(context, '关闭$label标签页', 'Close $label tab'),
            onPressed: () => _closeTool(scope, tool),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
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
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                pill(
                  [
                    current?.model.isNotEmpty == true
                        ? current!.model
                        : s.t('Model'),
                    if (current?.effort.isNotEmpty == true) current!.effort,
                  ].join(' · '),
                  ready && current.capabilities.models
                      ? () => modelDialog(context, model, s)
                      : null,
                  maxWidth: (MediaQuery.sizeOf(context).width - 246).clamp(
                    90,
                    180,
                  ),
                ),
                const SizedBox(width: 6),
                if (current != null) ...[
                  pill(
                    'Skill',
                    ready
                        ? () => _withScope(
                            (scope) => skillPickerDialog(context, scope),
                          )
                        : null,
                    maxWidth: 52,
                  ),
                  const SizedBox(width: 6),
                  pill(
                    sessionPermissionLabel(context, state),
                    ready
                        ? () => _withScope(
                            (scope) => sessionPermissions(context, scope),
                          )
                        : null,
                    maxWidth:
                        textValue(state['permissionLabel']).isNotEmpty ||
                            const {
                              'ask',
                              'auto-review',
                              'full-access',
                            }.contains(state['permissionMode'])
                        ? 120
                        : 64,
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
                    onPressed: () => _withScope(
                      (scope) => contextUsageDialog(context, scope),
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
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          key: const Key('composer-toggle'),
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
      String option,
      String selected,
      Map<String, String> choices, {
      bool active = true,
    }) {
      final selectedChoice = choices.containsKey(selected)
          ? selected
          : choices.keys.first;
      final label = choices[selectedChoice]!;
      return PopupMenuButton<String>(
        enabled: enabled && active,
        tooltip: label,
        onSelected: (value) => model.setDraftOption(option, value),
        itemBuilder: (_) => [
          for (final row in choices.entries)
            CheckedPopupMenuItem<String>(
              value: row.key,
              checked: row.key == selectedChoice,
              height: bridgeChoiceMenuItemHeight,
              child: Text(row.value),
            ),
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
    }

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
          Expanded(child: select('mode', model.sendMode, modes)),
          const SizedBox(width: 6),
          Expanded(
            child: select(
              'workMode',
              textValue(model.draftOptions['workMode'] ?? 'default'),
              workModes,
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
            onPressed:
                (model.canSend && !_pickingAttachment) ||
                    model.sendingChatAttachments
                ? model.send
                : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size(52, 40),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontSize: 13),
            ),
            child: model.busy && !model.sendingChatAttachments
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

  bool _matchesPickerTarget(SessionSnapshot target) =>
      mounted && widget.model.matchesAttachmentTarget(target);

  Widget _attachmentStrip() {
    final model = widget.model, s = widget.strings;
    final selection = _pendingAttachment;
    final pending = selection != null && _matchesPickerTarget(selection.target)
        ? selection
        : null;
    if (model.attachments.isEmpty &&
        model.stagedAttachments.isEmpty &&
        pending == null) {
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
                      model: model,
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
          for (final file in model.stagedAttachments)
            FutureBuilder<ChatAttachmentPayload?>(
              key: ObjectKey(file),
              future: file.prepared,
              builder: (context, preparation) => ComposerAttachment(
                name: file.name,
                strings: s,
                progressLabel: model.uploadingChatAttachment == file
                    ? s.t('Uploading attachment…')
                    : file.image &&
                          preparation.connectionState != ConnectionState.done
                    ? s.t('Preparing JPG…')
                    : null,
                preview: file.image
                    ? _localPhoto(file)
                    : const Icon(Icons.insert_drive_file_outlined, size: 30),
                onRemove: model.busy || !model.draftEditable
                    ? null
                    : () => model.removeStagedAttachment(file),
              ),
            ),
          if (pending != null)
            ComposerAttachment(
              key: const Key('pending-attachment'),
              name: pending.name,
              strings: s,
              progressLabel: s.t('Adding attachment...'),
              preview: Icon(
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

  Widget _localPhoto(LocalChatAttachment file) {
    final model = widget.model;
    AttachmentImage preview(Uint8List bytes) => AttachmentImage(
      bytes: bytes,
      name: file.name,
      strings: widget.strings,
      width: 104,
      height: 76,
      decodeSize: 320,
      compact: true,
      loadOriginal: file.hasNativeThumbnail
          ? () async => (await file.prepared)?.bytes ?? bytes
          : null,
      access: (
        changes: model,
        allowed: () => model.stagedAttachments.contains(file),
      ),
      onEdit: model.busy ? null : () => _editLocalPhoto(file),
    );
    if (!file.hasNativeThumbnail) return preview(file.bytes);
    return FutureBuilder<Uint8List?>(
      future: file.nativeThumbnail,
      builder: (context, thumbnail) =>
          thumbnail.connectionState == ConnectionState.done
          ? preview(thumbnail.data ?? file.bytes)
          : const Icon(Icons.photo_outlined, size: 30),
    );
  }

  Future<void> _editLocalPhoto(LocalChatAttachment file) async {
    final model = widget.model;
    bool allowed() => !model.busy && model.stagedAttachments.contains(file);
    if (!allowed()) return;
    final edited = await Navigator.of(context, rootNavigator: true)
        .push<Uint8List>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => ChatPhotoEditor(
              file: file,
              strings: widget.strings,
              access: (changes: model, allowed: allowed),
            ),
          ),
        );
    if (!mounted || edited == null || !allowed()) return;
    try {
      model.replaceStagedPhoto(file, edited);
    } catch (error) {
      model.reportError(error);
    }
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
      final file = await FilePicker.pickFile(
        type: type,
        darwinOptions: const DarwinOptions(
          assetRepresentationMode: DarwinAssetRepresentationMode.current,
        ),
      );
      if (file == null || !_matchesPickerTarget(current)) return;
      const limit = chatAttachmentMaxBytes;
      if ((file.lengthSync() ?? 0) > limit) {
        throw StateError('Attachment exceeds 20 MiB');
      }
      final image = type == FileType.image || isChatImage(file.name);
      setState(() {
        _pendingAttachment = (target: current, name: file.name, image: image);
      });
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (!_matchesPickerTarget(current)) return;
        if (builder.length + chunk.length > limit) {
          throw StateError('Attachment exceeds 20 MiB');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (!_matchesPickerTarget(current)) return;
      model.stageAttachment(
        LocalChatAttachment(name: file.name, bytes: bytes, image: image),
        target: current,
      );
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
