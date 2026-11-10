import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../provider_name.dart';
import 'common.dart';

class WslEnvironmentsPage extends StatefulWidget {
  const WslEnvironmentsPage({
    super.key,
    required this.model,
    required this.provider,
  });
  final BridgeViewModel model;
  final Provider provider;
  @override
  State<WslEnvironmentsPage> createState() => _WslEnvironmentsState();
}

class _WslEnvironmentsState extends State<WslEnvironmentsPage> {
  late final scope = GatewayBusiness(
    widget.model,
    provider: widget.provider,
    entry: '',
  );
  Json? data;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    scope.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final value = await scope.read(GatewayResource.wslEnvironments);
      if (mounted) {
        setState(() {
          data = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${providerName(widget.provider)} · WSL'),
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
    ),
    body: data == null
        ? BusinessLoading(error: error, retry: load)
        : ListView(
            children: [
              if (error != null)
                ListTile(title: Text(businessError(context, error))),
              if (jsonRows(data!['environments']).isEmpty)
                ListTile(
                  title: Text(
                    words(
                      context,
                      '尚未登记 WSL 环境，请先扫描环境',
                      'No registered WSL environment. Scan environments first.',
                    ),
                  ),
                ),
              for (final row in jsonRows(data!['environments']))
                ListTile(
                  title: Text(textValue(row['label'] ?? row['distribution'])),
                  subtitle: Text(
                    '${row['user']} · ${row['configDir']}\n${row['running'] == true ? words(context, '正在运行', 'Running') : words(context, '已停止', 'Stopped')}',
                  ),
                  onTap: () async {
                    final target = GatewayBusiness(
                      widget.model,
                      provider: widget.provider,
                      entry: textValue(row['id']),
                    );
                    try {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => WslAccountPage(scope: target),
                        ),
                      );
                    } finally {
                      target.dispose();
                    }
                  },
                ),
            ],
          ),
  );
}

class WslAccountPage extends StatefulWidget {
  const WslAccountPage({super.key, required this.scope});
  final GatewayBusiness scope;
  @override
  State<WslAccountPage> createState() => _WslAccountState();
}

class _WslAccountState extends State<WslAccountPage> {
  Json? data;
  Object? error;
  bool busy = false;
  final models = <String, Json>{};
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final value = await widget.scope.read(GatewayResource.wslAccounts);
      if (value['entry'] != widget.scope.entry ||
          value['provider'] != widget.scope.provider.name) {
        throw StateError('WSL account scope changed');
      }
      if (mounted) {
        setState(() {
          data = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<Json?> perform(String action, [Json fields = const {}]) async {
    if (busy || data?['available'] != true) return null;
    setState(() => busy = true);
    try {
      final value = await widget.scope.write(GatewayCommand.wslAccounts, {
        'action': action,
        if (const ['switch', 'recover-restart'].contains(action))
          'expectedIdentity': data!['identity'],
        ...fields,
      });
      if (!mounted) return null;
      if (value['entry'] != null && value['entry'] != widget.scope.entry ||
          value['provider'] != null &&
              value['provider'] != widget.scope.provider.name) {
        throw StateError('WSL account scope changed');
      }
      if (action == 'models') models[textValue(fields['id'])] = value;
      if (value['accounts'] is List) {
        setState(() {
          data = value;
          error = null;
        });
      }
      if (action == 'switch' || action == 'recover-restart') {
        await widget.scope.model.backToSessions();
      }
      return value;
    } catch (e) {
      if (mounted) setState(() => error = e);
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> switchTo(Json? row) async {
    if (!await confirmAction(
      context,
      words(context, '确认 WSL 账号操作', 'Confirm WSL account action'),
      row == null
          ? words(
              context,
              '核验已应用配置并正常恢复共享服务和原会话。不会再次切换账号。',
              'Verify the applied configuration and restore the shared service and original sessions without switching again.',
            )
          : '${row['name']}\n${words(context, '仅切换此 WSL 环境的后续请求。网关会核验任务、审批和未确认发送；全部空闲后可能正常重启共享服务，原终端可能需要重新连接。', 'Switch subsequent requests in this WSL environment. The gateway checks running tasks, approvals and unconfirmed sends. When idle, it may restart the shared service; terminals may need reconnecting.')}',
      danger: true,
    )) {
      return;
    }
    if (!mounted) return;
    await perform(
      row == null ? 'recover-restart' : 'switch',
      row == null ? {} : {'id': row['id']},
    );
  }

  Future<void> edit([Json? row]) async {
    final name = TextEditingController(text: textValue(row?['name']));
    final url = TextEditingController(text: textValue(row?['baseUrl']));
    final model = TextEditingController(text: textValue(row?['model']));
    final key = TextEditingController();
    var scheme = textValue(row?['authScheme']);
    if (!['x-api-key', 'bearer'].contains(scheme)) scheme = 'x-api-key';
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (_, change) => AlertDialog(
            title: Text(
              words(context, '保存 WSL API 接入', 'Save WSL API account'),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: InputDecoration(
                      labelText: words(context, '名称', 'Name'),
                    ),
                  ),
                  TextField(
                    controller: url,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: words(context, 'API 地址', 'API URL'),
                    ),
                  ),
                  TextField(
                    controller: model,
                    decoration: InputDecoration(
                      labelText: words(context, '模型 ID', 'Model ID'),
                    ),
                  ),
                  TextField(
                    controller: key,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      helperText: row == null
                          ? null
                          : words(
                              context,
                              '留空保留已有密钥',
                              'Leave empty to keep the existing key',
                            ),
                    ),
                  ),
                  if (widget.scope.provider == Provider.claude)
                    DropdownButton<String>(
                      value: scheme,
                      items: ['x-api-key', 'bearer']
                          .map(
                            (v) => DropdownMenuItem(value: v, child: Text(v)),
                          )
                          .toList(),
                      onChanged: (v) => change(() => scheme = v!),
                    ),
                  Text(
                    words(
                      context,
                      '只保存接入，不会切换当前账号。',
                      'Saves the account without switching the current account.',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
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
      if (save != true || !mounted) return;
      if (name.text.trim().isEmpty ||
          url.text.trim().isEmpty ||
          model.text.trim().isEmpty ||
          row == null && key.text.isEmpty) {
        throw StateError('Complete the account fields');
      }
      await perform('save-api', {
        'id': ?row?['id'],
        'name': name.text.trim(),
        'baseUrl': url.text.trim(),
        'model': model.text.trim(),
        if (key.text.isNotEmpty) 'apiKey': key.text,
        'authScheme': scheme,
      });
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      key.clear();
      for (final controller in [name, url, model, key]) {
        controller.dispose();
      }
    }
  }

  Future<void> importAccount() async {
    final value = await perform('import-sources');
    if (!mounted || value == null) return;
    final rows = jsonRows(value['sources']);
    final id = await chooseValue(
      context,
      words(
        context,
        '导入本机 API 接入（回环地址仍指向 WSL）',
        'Import a local API account (loopback still points to WSL)',
      ),
      {
        for (final row in rows)
          textValue(row['id']): '${row['name']} · ${row['source']}',
      },
    );
    final row = rows.where((r) => r['id'] == id).firstOrNull;
    if (mounted && row != null) {
      await perform('import-api', {
        'sourceId': row['id'],
        'sourceIdentity': row['sourceIdentity'],
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final caps = jsonObject(data?['capabilities']),
        target = jsonObject(data?['target']);
    final enabled = !busy && data?['available'] == true;
    final blockers = data?['blockers'] as List? ?? [];
    return Scaffold(
      appBar: AppBar(
        title: Text('${providerName(widget.scope.provider)} · WSL'),
        actions: [
          IconButton(
            onPressed: () => reviewGatewayOperations(context, widget.scope),
            icon: const Icon(Icons.fact_check_outlined),
          ),
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
                Text(
                  '${target['distribution']} · ${target['user']}\n${target['configDir']}',
                ),
                if (error != null)
                  SelectableText(businessError(context, error)),
                for (final reason in blockers)
                  Text(
                    reason is Map
                        ? textValue(reason['message'] ?? reason['code'])
                        : textValue(reason),
                  ),
                if (data!['captureNotice'] != null)
                  Text(textValue(data!['captureNotice'])),
                if (data!['restartPending'] == true ||
                    data!['continuationPending'] == true)
                  Text(
                    textValue(
                      data!['restartError'] ?? data!['continuationError'],
                    ),
                  ),
                if (caps['recoverRestart'] == true)
                  FilledButton(
                    onPressed: enabled ? () => switchTo(null) : null,
                    child: Text(
                      words(
                        context,
                        '检查并恢复共享服务',
                        'Check and restore shared service',
                      ),
                    ),
                  ),
                for (final row in jsonRows(data!['accounts']))
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            textValue(row['name'] ?? row['id']),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          SelectableText(
                            '${row['kind']} · ${row['baseUrl'] ?? ''} · ${row['model'] ?? ''}',
                          ),
                          if (row['active'] == true ||
                              row['id'] == data!['activeId'])
                            Text(words(context, '当前接入', 'Current account')),
                          Wrap(
                            children: [
                              if (row['active'] != true &&
                                  row['id'] != data!['activeId'] &&
                                  data!['restartPending'] != true &&
                                  (caps['attemptSwitch'] == true ||
                                      row['id'] == 'native' &&
                                          (caps['restore'] == true ||
                                              caps['attemptRestore'] == true) ||
                                      caps['switch'] == true &&
                                          blockers.isEmpty))
                                TextButton(
                                  onPressed: enabled
                                      ? () => switchTo(row)
                                      : null,
                                  child: Text(
                                    words(context, '检查并切换', 'Check and switch'),
                                  ),
                                ),
                              if (row['kind'] == 'api' &&
                                  caps['models'] == true)
                                TextButton(
                                  onPressed: enabled
                                      ? () => perform('models', {
                                          'id': row['id'],
                                          'refresh': true,
                                        })
                                      : null,
                                  child: Text(
                                    words(context, '刷新模型', 'Refresh models'),
                                  ),
                                ),
                              if (row['id'] != 'native' &&
                                  caps['save'] == true) ...[
                                TextButton(
                                  onPressed: enabled
                                      ? () async {
                                          final name = await promptText(
                                            context,
                                            words(context, '名称', 'Name'),
                                            initial: textValue(row['name']),
                                          );
                                          if (mounted &&
                                              name?.trim().isNotEmpty == true) {
                                            await perform('rename', {
                                              'id': row['id'],
                                              'name': name!.trim(),
                                            });
                                          }
                                        }
                                      : null,
                                  child: Text(words(context, '重命名', 'Rename')),
                                ),
                                if (row['active'] != true &&
                                    row['id'] != data!['activeId']) ...[
                                  TextButton(
                                    onPressed: enabled ? () => edit(row) : null,
                                    child: Text(words(context, '编辑', 'Edit')),
                                  ),
                                  TextButton(
                                    onPressed: enabled
                                        ? () async {
                                            if (await confirmAction(
                                                  context,
                                                  words(
                                                    context,
                                                    '删除保存的接入？',
                                                    'Delete this saved account?',
                                                  ),
                                                  textValue(row['name']),
                                                  danger: true,
                                                ) &&
                                                mounted) {
                                              await perform('delete', {
                                                'id': row['id'],
                                              });
                                            }
                                          }
                                        : null,
                                    child: Text(words(context, '删除', 'Delete')),
                                  ),
                                ],
                              ],
                            ],
                          ),
                          if (models[row['id']] case final result?) ...[
                            for (final model in result['models'] as List? ?? [])
                              ListTile(
                                dense: true,
                                title: Text(
                                  model is Map
                                      ? textValue(model['name'] ?? model['id'])
                                      : textValue(model),
                                ),
                                subtitle:
                                    model is Map && model['efforts'] != null
                                    ? Text(textValue(model['efforts']))
                                    : null,
                              ),
                            if (result['modelError'] != null)
                              Text(textValue(result['modelError'])),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (caps['save'] == true)
                  FilledButton(
                    onPressed: enabled ? edit : null,
                    child: Text(
                      words(context, '添加 WSL API 接入', 'Add WSL API account'),
                    ),
                  ),
                if (caps['save'] == true &&
                    caps['capture'] != false &&
                    !jsonRows(data!['accounts'])
                        .any((r) => r['id'] == 'native'))
                  TextButton(
                    onPressed: enabled ? () => perform('import-current') : null,
                    child: Text(
                      words(context, '保存当前原生接入', 'Save current native account'),
                    ),
                  ),
                if (caps['import'] == true)
                  TextButton(
                    onPressed: enabled ? importAccount : null,
                    child: Text(
                      words(
                        context,
                        '从本机导入 API 接入',
                        'Import a local API account',
                      ),
                    ),
                  ),
                if (data!['loginGuidance'] != null)
                  SelectableText(textValue(data!['loginGuidance'])),
              ],
            ),
    );
  }
}
