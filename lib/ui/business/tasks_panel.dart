import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';
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

class TasksPanel extends StatefulWidget {
  const TasksPanel({super.key, required this.scope, this.onOpenSession});
  final SessionBusiness scope;
  final VoidCallback? onOpenSession;
  @override
  State<TasksPanel> createState() => _TasksPanelState();
}

class _TasksPanelState extends State<TasksPanel>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  Json data = {};
  Object? error;
  int mode = 0;
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
    mode = codex ? 0 : 2;
    load();
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
    if (state == AppLifecycleState.resumed) {
      timer = Timer(const Duration(seconds: 1), load);
    }
  }

  Future<void> load() async {
    timer?.cancel();
    if (!widget.scope.current) return;
    final request = ++revision, requestedMode = mode;
    try {
      final value = await widget.scope.read(
        [
          SessionResource.sideChats,
          SessionResource.subagents,
          SessionResource.tasks,
        ][requestedMode],
        requestedMode == 0 ? {'view': 'native'} : {},
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
      if (mounted && request == revision) {
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
    if (mode == 0) {
      await widget.scope.model.openSession(reference(row));
      if (mounted) {
        if (widget.onOpenSession != null) {
          widget.onOpenSession!();
        } else {
          Navigator.pop(context);
        }
      }
      return;
    }
    if (mode != 1) return;
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
            appBar: AppBar(
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
    if (busy) return;
    setState(() => busy = true);
    try {
      final created = await widget.scope.write(SessionCommand.sideChat, {
        'action': 'create',
        'creationId': widget.scope.model.repository.newId(),
      });
      if (mounted) await open(created);
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
      data[mode == 0
          ? 'chats'
          : mode == 1
          ? 'agents'
          : 'tasks'],
    );
    final rows = mode == 1
        ? subagentTree(rawRows, widget.scope.session.id)
        : rawRows;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (codex)
          SegmentedButton<int>(
            segments: [
              ButtonSegment(
                value: 0,
                label: Text(words(context, '侧边聊天', 'Side chats')),
              ),
              ButtonSegment(
                value: 1,
                label: Text(words(context, '子智能体', 'Subagents')),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (v) {
              setState(() {
                mode = v.single;
                data = {};
                error = null;
              });
              load();
            },
          ),
        Row(
          children: [
            if (mode == 0)
              TextButton.icon(
                onPressed: busy ? null : create,
                icon: const Icon(Icons.add),
                label: Text(words(context, '新建侧边聊天', 'New side chat')),
              ),
            const Spacer(),
            IconButton(onPressed: load, icon: const Icon(Icons.refresh)),
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
              mode == 1
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
            onTap: mode == 2 ? null : () => open(row),
            trailing: mode == 0
                ? IconButton(
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => sessionActions(
                      context,
                      widget.scope.model,
                      reference(row),
                    ),
                  )
                : mode == 2 && row['cancellable'] == true
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
