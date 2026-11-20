import '../design/bridge_theme.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';
import '../design/selection_controls.dart';
import 'message_content.dart';
import 'session_actions.dart';

List<Json> subagentTree(List<Json> agents, String parent) {
  final children = <String, List<Json>>{};
  for (final row in agents) {
    children.putIfAbsent(textValue(row['parentId']), () => []).add(row);
  }
  final visited = <String>{};
  final ordered = <Json>[];
  void draw(String id, int depth) {
    for (final row in children[id] ?? <Json>[]) {
      final key = textValue(row['id']);
      if (key.isEmpty || !visited.add(key)) continue;
      ordered.add({...row, '_depth': depth.clamp(0, 6)});
      if (depth < 128) draw(key, depth + 1);
    }
  }

  draw(parent, 0);
  // Incomplete saved trees still expose orphan records without inventing parents.
  for (final row in agents) {
    final id = textValue(row['id']);
    if (visited.add(id)) {
      ordered.add({...row, '_depth': 0});
      draw(id, 1);
    }
  }
  return ordered;
}

enum WorkspaceTaskKind { sideChats, subagents, background }

class TasksPanel extends StatefulWidget {
  const TasksPanel({
    super.key,
    required this.scope,
    this.kind,
    this.active = true,
  });
  final SessionBusiness scope;
  final WorkspaceTaskKind? kind;
  final bool active;
  @override
  State<TasksPanel> createState() => _TasksPanelState();
}

class _TasksPanelState extends State<TasksPanel>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  Json data = {};
  Object? error;
  late WorkspaceTaskKind mode;
  bool busy = false;
  int revision = 0;
  Timer? timer;
  bool get codex => widget.scope.session.provider == Provider.codex;
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    mode =
        widget.kind ??
        (codex ? WorkspaceTaskKind.sideChats : WorkspaceTaskKind.background);
    load();
  }

  @override
  void didUpdateWidget(TasksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    timer?.cancel();
    revision++;
    if (widget.active) load();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    revision++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    timer?.cancel();
    revision++;
    if (state == AppLifecycleState.resumed && widget.active) {
      timer = Timer(const Duration(seconds: 1), load);
    }
  }

  Future<void> load() async {
    timer?.cancel();
    if (!widget.active || !widget.scope.current) return;
    final request = ++revision, requestedMode = mode;
    try {
      final value = await widget.scope.read(
        switch (requestedMode) {
          WorkspaceTaskKind.sideChats => SessionResource.sideChats,
          WorkspaceTaskKind.subagents => SessionResource.subagents,
          WorkspaceTaskKind.background => SessionResource.tasks,
        },
        requestedMode == WorkspaceTaskKind.sideChats ? {'view': 'native'} : {},
      );
      if (mounted && request == revision) {
        setState(() {
          data = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && request == revision) setState(() => error = e);
    } finally {
      if (mounted &&
          request == revision &&
          requestedMode != WorkspaceTaskKind.sideChats) {
        timer = Timer(const Duration(seconds: 10), load);
      }
    }
  }

  SessionRef reference(Json row) => SessionRef(
    computerId: widget.scope.session.computerId,
    provider: widget.scope.session.provider,
    entry: widget.scope.session.entry,
    environment: textValue(row['host'] ?? widget.scope.session.environment),
    id: textValue(row['id']),
  );

  Future<void> open(Json row) async {
    if (!widget.active || !widget.scope.current) return;
    if (mode == WorkspaceTaskKind.sideChats) {
      final target = reference(row);
      if (target.id.isEmpty) return;
      await widget.scope.model.openSession(target, activate: true);
      if (widget.kind == null &&
          mounted &&
          widget.scope.model.selected == target &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
      return;
    }
    if (mode != WorkspaceTaskKind.subagents) return;
    final request = revision;
    try {
      final detail = await widget.scope.read(SessionResource.subagents, {
        'id': row['id'],
      });
      if (!mounted || request != revision) return;
      final turns = jsonRows(detail['turns']);
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: BridgeNavigationBar(
              title: Text(
                textValue(row['nickname'] ?? row['title'] ?? row['name']),
              ),
            ),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  words(
                    context,
                    '已保存记录，非实时任务状态',
                    'Saved history; status is not live',
                  ),
                ),
                if (detail['historyComplete'] != true)
                  Text(
                    words(
                      context,
                      '仅展示最近 10 轮记录',
                      'Only the latest 10 turns are available',
                    ),
                  ),
                for (final turn in turns) ...[
                  Text(
                    textValue(turn['status']),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  for (final message in jsonRows(turn['messages']))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: ['user', 'assistant'].contains(message['role'])
                          ? RichMessageText(text: textValue(message['text']))
                          : ExpansionTile(
                              title: Text(
                                textValue(
                                  message['name'] ?? message['kind'] ?? 'Tool',
                                ),
                              ),
                              children: [
                                SelectableText(
                                  textValue(
                                    message['output'] ?? message['text'],
                                  ),
                                ),
                              ],
                            ),
                    ),
                ],
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> create() async {
    if (busy || !widget.active || !widget.scope.current) return;
    setState(() => busy = true);
    try {
      final created = await widget.scope.write(SessionCommand.sideChat, {
        'action': 'create',
        'creationId': widget.scope.model.repository.newId(),
      });
      if (mounted) {
        if (widget.active && mode == WorkspaceTaskKind.sideChats) {
          await open(created);
        }
        await load();
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final rawRows = jsonRows(
      data[switch (mode) {
        WorkspaceTaskKind.sideChats => 'chats',
        WorkspaceTaskKind.subagents => 'agents',
        WorkspaceTaskKind.background => 'tasks',
      }],
    );
    final rows = mode == WorkspaceTaskKind.subagents
        ? subagentTree(rawRows, widget.scope.session.id)
        : rawRows;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (widget.kind == null && codex)
          BridgeChoiceGrid(
            options: {
              '0': words(context, '侧边聊天', 'Side chats'),
              '1': words(context, '子智能体', 'Subagents'),
            },
            value: mode == WorkspaceTaskKind.sideChats ? '0' : '1',
            onChanged: (value) {
              setState(() {
                mode = value == '0'
                    ? WorkspaceTaskKind.sideChats
                    : WorkspaceTaskKind.subagents;
                data = {};
                error = null;
              });
              load();
            },
          ),
        Row(
          children: [
            if (mode == WorkspaceTaskKind.sideChats)
              Expanded(
                child: TextButton.icon(
                  onPressed: busy ? null : create,
                  icon: const Icon(Icons.add),
                  label: Text(words(context, '新建侧边聊天', 'New side chat')),
                ),
              ),
            const Spacer(),
            IconButton(
              tooltip: words(context, '刷新', 'Refresh'),
              onPressed: load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (error != null) SelectableText(businessError(context, error)),
        if (data['limited'] == true)
          Text(
            words(
              context,
              '显示前 128 项已保存记录',
              'Showing the first 128 saved records',
            ),
          ),
        for (final row in rows)
          ListTile(
            contentPadding: EdgeInsets.only(
              left: 16 + (row['_depth'] as int? ?? 0) * 16,
              right: 16,
            ),
            title: Text(
              textValue(
                row['nickname'] ?? row['title'] ?? row['name'] ?? row['id'],
              ),
            ),
            subtitle: Text(
              mode == WorkspaceTaskKind.subagents
                  ? [
                      row['role'],
                      row['path'],
                      words(
                        context,
                        row['archived'] == true ? '已归档' : '已保存记录',
                        row['archived'] == true ? 'Archived' : 'Saved record',
                      ),
                    ].where((v) => v != null && v != '').join(' · ')
                  : textValue(row['status']),
            ),
            onTap: mode == WorkspaceTaskKind.background
                ? null
                : () => open(row),
            trailing: mode == WorkspaceTaskKind.sideChats
                ? IconButton(
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => sessionActions(
                      context,
                      widget.scope.model,
                      reference(row),
                    ),
                  )
                : mode == WorkspaceTaskKind.background &&
                      row['cancellable'] == true
                ? IconButton(
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: () async {
                      if (!await confirmAction(
                        context,
                        words(context, '停止后台任务？', 'Stop background task?'),
                        textValue(row['title'] ?? row['id']),
                      )) {
                        return;
                      }
                      try {
                        await widget.scope.write(SessionCommand.stopTask, {
                          'taskId': row['id'],
                        });
                        await load();
                      } catch (e) {
                        if (context.mounted) showFailure(context, e);
                      }
                    },
                  )
                : null,
          ),
        if (rows.isEmpty && error == null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(words(context, '暂无记录', 'No records')),
          ),
      ],
    );
  }
}
