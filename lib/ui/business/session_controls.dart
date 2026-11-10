import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';
import 'model_settings.dart';
import 'context_usage.dart';

class SessionControlsPage extends StatefulWidget {
  const SessionControlsPage({super.key, required this.scope});
  final SessionBusiness scope;
  @override
  State<SessionControlsPage> createState() => _SessionControlsState();
}

class _SessionControlsState extends State<SessionControlsPage> {
  SessionBusiness get scope => widget.scope;
  bool busy = false;
  Future<void> run(Future<void> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await task();
      if (scope.current) {
        await scope.refresh();
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = scope.model, caps = scope.capabilities, state = scope.state;
    final editing = model.selected == scope.session && model.draftEditable;
    final goal = jsonObject(state['goal']);
    final access = jsonObject(state['access']);
    return Scaffold(
      appBar: AppBar(
        title: Text(words(context, '任务与聊天设置', 'Task & chat settings')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (busy) const LinearProgressIndicator(),
          ListTile(
            title: Text(words(context, '模型与思考强度', 'Model & reasoning')),
            subtitle: Text(
              '${scope.snapshot.model} · ${scope.snapshot.effort}',
            ),
            enabled: !busy && scope.snapshot.capabilities.models,
            onTap: () => run(() async {
              await scopedModelDialog(context, scope);
            }),
          ),
          if (editing) ...[
            ListTile(
              title: Text(words(context, '发送方式', 'Send mode')),
              subtitle: Text(model.sendMode),
              onTap: busy
                  ? null
                  : () async {
                      final value = await chooseValue(
                        context,
                        words(context, '发送方式', 'Send mode'),
                        {
                          'send': words(context, '普通发送', 'Send'),
                          if (caps['queue'] != false)
                            'queue': words(context, '排队发送', 'Queue'),
                          if (scope.snapshot.capabilities.steer)
                            'steer': words(
                              context,
                              '补充当前任务',
                              'Steer current task',
                            ),
                        },
                      );
                      if (value != null && mounted) {
                        model.setDraftOption('mode', value);
                        setState(() {});
                      }
                    },
            ),
            ListTile(
              title: Text(words(context, '工作模式', 'Work mode')),
              subtitle: Text(
                textValue(model.draftOptions['workMode'] ?? 'default'),
              ),
              enabled: model.sendMode != 'steer',
              onTap: busy
                  ? null
                  : () async {
                      final value = await chooseValue(
                        context,
                        words(context, '工作模式', 'Work mode'),
                        {
                          'default': words(context, '普通', 'Default'),
                          if (caps['plan'] != false)
                            'plan': words(context, '先规划再执行', 'Plan'),
                          if (caps['goal'] == true ||
                              scope.session.provider == Provider.codex &&
                                  access['canUseGoal'] == true &&
                                  state['goalRuntimeAvailable'] != false)
                            'goal': words(
                              context,
                              '目标：持续执行至完成、暂停或取消',
                              'Goal: continue until complete, paused or canceled',
                            ),
                        },
                      );
                      if (value != null && mounted) {
                        model.setDraftOption('workMode', value);
                        setState(() {});
                      }
                    },
            ),
            if (caps['skills'] == true ||
                scope.session.provider == Provider.codex &&
                    access['canSelectSkills'] == true)
              ListTile(
                title: const Text('Skill'),
                subtitle: Text(
                  (model.draftOptions['skills'] as List? ?? []).join(', '),
                ),
                onTap: busy
                    ? null
                    : () => run(() async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => SkillPickerPage(scope: scope),
                          ),
                        );
                      }),
              ),
            for (final ref in model.fileReferences)
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(textValue(ref['path'])),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    model.setDraftOption(
                      'references',
                      model.fileReferences
                          .where((r) => r['path'] != ref['path'])
                          .toList(),
                    );
                    setState(() {});
                  },
                ),
              ),
          ],
          if (caps['permissions'] == true ||
              access['canChangePermissions'] == true)
            ListTile(
              title: Text(words(context, '权限', 'Permissions')),
              subtitle: Text(
                textValue(state['permissionLabel'] ?? state['permissionMode']),
              ),
              onTap: busy ? null : () => run(permissions),
            ),
          ListTile(
            title: Text(
              words(context, '队列与未确认消息', 'Queued & unconfirmed messages'),
            ),
            onTap: busy
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => MessageQueuePage(scope: scope),
                    ),
                  ),
          ),
          ContextUsageCard(state: state),
          if (caps['compact'] == true)
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      if (await confirmAction(
                        context,
                        words(context, '压缩上下文？', 'Compact context?'),
                        words(
                          context,
                          '由当前客户端压缩此聊天的上下文。',
                          'Ask the current client to compact this conversation.',
                        ),
                      )) {
                        await scope.write(SessionCommand.compact, {});
                      }
                    }),
              child: Text(words(context, '压缩上下文', 'Compact context')),
            ),
          if (goal.isNotEmpty) ...[
            ListTile(
              title: Text(words(context, '目标', 'Goal')),
              subtitle: SelectableText(textValue(goal['objective'])),
            ),
            Text(
              '${goal['status']} · ${goal['tokensUsed'] ?? 0} / ${goal['tokenBudget'] ?? "∞"} tokens',
            ),
            Wrap(
              spacing: 8,
              children: [
                if (goal['status'] == 'paused' || caps['goalResume'] == true)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(
                            () => goalAction('status', {'status': 'active'}),
                          ),
                    child: Text(words(context, '恢复目标', 'Resume goal')),
                  ),
                if (goal['status'] != 'paused' &&
                    goal['status'] != 'complete' &&
                    caps['goalPause'] != false)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(
                            () => goalAction('status', {'status': 'paused'}),
                          ),
                    child: Text(words(context, '暂停目标', 'Pause goal')),
                  ),
                if (goal['status'] == 'paused' && caps['goalEdit'] != false)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            final text = await promptText(
                              context,
                              words(context, '修改目标', 'Edit goal'),
                              initial: textValue(goal['objective']),
                              multiline: true,
                            );
                            if (text?.trim().isNotEmpty == true) {
                              await goalAction('edit', {
                                'objective': text!.trim(),
                              });
                            }
                          }),
                    child: Text(words(context, '修改目标', 'Edit goal')),
                  ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                          if (await confirmAction(
                            context,
                            words(context, '关闭目标？', 'Cancel goal?'),
                            words(
                              context,
                              '关闭目标不会撤销已经执行的操作；当前回复可能继续运行。',
                              'Canceling does not undo completed operations. The current reply may continue.',
                            ),
                          )) {
                            await goalAction('cancel', {});
                          }
                        }),
                  child: Text(words(context, '关闭目标', 'Cancel goal')),
                ),
              ],
            ),
          ],
          if (caps['notifications'] != false)
            ListTile(
              title: Text(words(context, '此聊天的通知', 'Chat notifications')),
              onTap: busy ? null : () => run(notifications),
            ),
          if (scope.session.provider == Provider.codex &&
              access['runtime'] == 'cli')
            ListTile(
              title: Text(
                words(context, 'CLI 网络诊断', 'CLI network diagnostics'),
              ),
              onTap: busy
                  ? null
                  : () => run(() async {
                      final value = await scope.read(
                        SessionResource.cliNetwork,
                      );
                      if (context.mounted) {
                        await Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => DetailTextPage(
                              title: 'CLI',
                              text: const JsonEncoder.withIndent('  ')
                                  .convert(value),
                            ),
                          ),
                        );
                      }
                    }),
            ),
        ],
      ),
    );
  }

  Future<void> permissions() async {
    final value = await scope.read(SessionResource.permissions);
    if (!mounted) return;
    final codex = scope.session.provider == Provider.codex;
    final choices = jsonRows(value['options'])
        .where((o) => o['available'] != false)
        .toList();
    final selected = await chooseValue(
      context,
      words(context, '权限', 'Permissions'),
      <String, String>{
        for (final o in choices)
          textValue(
            o['preset'] ?? o['value'] ?? o['id'],
          ): '${o['label'] ?? o['name'] ?? o['preset'] ?? o['value']}\n${o['description'] ?? o['reason'] ?? ""}',
      },
    );
    if (selected == null || !mounted) return;
    final option = choices.firstWhere(
      (o) => textValue(o['preset'] ?? o['value'] ?? o['id']) == selected,
    );
    final elevated =
        selected == 'full-access' ||
        selected == 'bypassPermissions' ||
        option['requiresConfirmation'] == true;
    if (elevated &&
        !await confirmAction(
          context,
          words(context, '启用完全访问？', 'Enable full access?'),
          words(
            context,
            '允许直接修改电脑文件和执行命令。请确认你信任当前任务。',
            'Allows direct file changes and commands on the computer. Confirm that you trust this task.',
          ),
          danger: true,
        )) {
      return;
    }
    await scope.write(
      SessionCommand.permissions,
      codex
          ? {
              'preset': selected,
              'confirmed': elevated,
              'expectedRuntime': jsonObject(scope.state['access'])['runtime'],
            }
          : {'mode': selected, if (elevated) 'confirmed': true},
    );
  }

  Future<void> goalAction(String action, Json fields) async {
    final goal = jsonObject(scope.state['goal']);
    final expected = <String, dynamic>{
      for (final key in [
        'objective',
        'status',
        'createdAt',
        'createdAtMs',
        'goalId',
        'revision',
      ])
        if (goal[key] != null) key: goal[key],
    };
    await scope.write(
      scope.session.provider == Provider.codex
          ? {
              'edit': SessionCommand.goalEdit,
              'status': SessionCommand.goalStatus,
              'cancel': SessionCommand.goalCancel,
            }[action]!
          : SessionCommand.goal,
      {
        ...fields,
        'expected': expected,
        if (scope.session.provider != Provider.codex) 'operation': action,
      },
    );
  }

  Future<void> notifications() async {
    final value = await scope.read(SessionResource.notifications);
    if (!mounted) return;
    var watching = textValue(value['requests'] ?? 'inherit'),
        complete = textValue(value['completion'] ?? 'inherit');
    final save = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(words(context, '聊天通知', 'Chat notifications')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: watching,
                decoration: InputDecoration(
                  labelText: words(context, '请求处理通知', 'Request notifications'),
                ),
                items: [
                  for (final entry in {
                    'inherit': words(context, '跟随全局', 'Use global setting'),
                    'on': words(context, '开启', 'On'),
                    'off': words(context, '关闭', 'Off'),
                  }.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (v) => set(() => watching = v!),
              ),
              DropdownButtonFormField<String>(
                initialValue: complete,
                decoration: InputDecoration(
                  labelText: words(
                    context,
                    '运行完成通知',
                    'Completion notifications',
                  ),
                ),
                items: [
                  for (final entry in {
                    'inherit': words(context, '跟随全局', 'Use global setting'),
                    'on': words(context, '开启', 'On'),
                    'off': words(context, '关闭', 'Off'),
                  }.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (v) => set(() => complete = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(words(context, '取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(words(context, '保存', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      await scope.write(SessionCommand.notifications, {
        'requests': watching,
        'completion': complete,
      });
    }
  }
}

class SkillPickerPage extends StatefulWidget {
  const SkillPickerPage({super.key, required this.scope});
  final SessionBusiness scope;
  @override
  State<SkillPickerPage> createState() => _SkillPickerState();
}

class _SkillPickerState extends State<SkillPickerPage> {
  List<Json> rows = [];
  String query = '';
  int total = 0, revision = 0;
  bool loading = true;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool more = false, bool refresh = false}) async {
    final request = ++revision;
    setState(() => loading = true);
    try {
      final data = await widget.scope.read(SessionResource.catalog, {
        'kind': 'skills',
        'q': query,
        'offset': more ? rows.length : 0,
        'limit': 200,
        'refresh': refresh,
      });
      if (!mounted || request != revision) return;
      setState(() {
        final offered = jsonRows(data['skills']).where(
          (row) =>
              widget.scope.session.provider == Provider.codex ||
              query.isEmpty ||
              '${row['name']} ${row['description']}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
        );
        rows = [if (more) ...rows, ...offered];
        total = (data['total'] as num?)?.toInt() ?? rows.length;
        error = null;
      });
    } catch (e) {
      if (mounted && request == revision) setState(() => error = e);
    } finally {
      if (mounted && request == revision) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.scope.model;
    final selected = (model.draftOptions['skills'] as List? ?? [])
        .cast<String>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Skill'),
        actions: [
          IconButton(
            onPressed: loading ? null : () => load(refresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: InputDecoration(
                labelText: words(context, '搜索 Skill', 'Search skills'),
              ),
              onSubmitted: (v) {
                query = v;
                load();
              },
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null) Text(businessError(context, error)),
          Expanded(
            child: ListView(
              children: [
                for (final row in rows)
                  CheckboxListTile(
                    title: Text(textValue(row['name'] ?? row['id'])),
                    subtitle: Text(textValue(row['description'])),
                    value: selected.contains(row['id']),
                    onChanged:
                        row['selectable'] == false ||
                            (!selected.contains(row['id']) &&
                                selected.length >= 8)
                        ? null
                        : (v) {
                            final next = [...selected];
                            v == true
                                ? next.add(textValue(row['id']))
                                : next.remove(row['id']);
                            model.setDraftOption(
                              'skills',
                              next.toSet().toList(),
                            );
                            setState(() {});
                          },
                  ),
                if (rows.length < total)
                  TextButton(
                    onPressed: loading ? null : () => load(more: true),
                    child: Text(words(context, '加载更多', 'Load more')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MessageQueuePage extends StatefulWidget {
  const MessageQueuePage({super.key, required this.scope});
  final SessionBusiness scope;
  @override
  State<MessageQueuePage> createState() => _MessageQueueState();
}

class _MessageQueueState extends State<MessageQueuePage> {
  Json? data;
  Object? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.scope.read(SessionResource.messageManagement);
      if (mounted) {
        setState(() {
          data = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> change(String action, Json fields) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.scope.write(SessionCommand.messageManagement, {
        'action': action,
        'version': data!['version'],
        'expectedAccount': data!['draftAccountIdentity'],
        ...fields,
      });
      await load();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = jsonRows(data?['queue']),
        caps = jsonObject(data?['capabilities']);
    return Scaffold(
      appBar: AppBar(
        title: Text(words(context, '消息管理', 'Message management')),
        actions: [
          IconButton(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: data == null
          ? BusinessLoading(error: error, retry: load)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (busy) const LinearProgressIndicator(),
                if (error != null) Text(businessError(context, error)),
                if (data!['reason'] != null) Text(textValue(data!['reason'])),
                if (rows.isEmpty)
                  Text(words(context, '当前没有待发送消息', 'No queued messages')),
                for (var i = 0; i < rows.length; i++)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(textValue(rows[i]['text'])),
                          Wrap(
                            children: [
                              if (caps['withdraw'] != false)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => change('withdraw', {
                                          'id': rows[i]['id'],
                                        }),
                                  child: Text(words(context, '撤回', 'Withdraw')),
                                ),
                              if (caps['edit'] != false)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          final text = await promptText(
                                            context,
                                            words(
                                              context,
                                              '编辑待发送消息',
                                              'Edit queued message',
                                            ),
                                            initial: textValue(rows[i]['text']),
                                            multiline: true,
                                          );
                                          if (text != null) {
                                            await change('edit', {
                                              'id': rows[i]['id'],
                                              'text': text,
                                              'editId': widget
                                                  .scope
                                                  .model
                                                  .repository
                                                  .newId(),
                                            });
                                          }
                                        },
                                  child: Text(words(context, '编辑', 'Edit')),
                                ),
                              if (caps['reorder'] != false) ...[
                                for (final delta in [-1, 1])
                                  IconButton(
                                    icon: Icon(
                                      delta < 0
                                          ? Icons.arrow_upward
                                          : Icons.arrow_downward,
                                    ),
                                    onPressed:
                                        busy ||
                                            i + delta < 0 ||
                                            i + delta >= rows.length
                                        ? null
                                        : () {
                                            final ids = rows
                                                .map((r) => r['id'])
                                                .toList();
                                            final item = ids.removeAt(i);
                                            ids.insert(i + delta, item);
                                            change('reorder', {'ids': ids});
                                          },
                                  ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                for (final row in jsonRows(data!['unknown']))
                  ListTile(
                    title: Text(textValue(row['text'])),
                    subtitle: Text(
                      words(
                        context,
                        '结果未确认，不会自动重发',
                        'Unconfirmed; will not be resent',
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (await confirmAction(
                                context,
                                words(context, '忽略记录？', 'Ignore record?'),
                                words(
                                  context,
                                  '消息可能已送达，此操作不会撤回或重新发送。',
                                  'The message may have arrived. This will neither withdraw nor resend it.',
                                ),
                              )) {
                                await change('ignore', {'id': row['id']});
                              }
                            },
                      child: Text(words(context, '忽略', 'Ignore')),
                    ),
                  ),
              ],
            ),
    );
  }
}
