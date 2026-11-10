import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../provider_name.dart';
import 'common.dart';
import 'wsl_accounts_page.dart';
import 'account_details.dart';

// WSL is an execution environment within a family, not a separate chat instance.
List<Json> managedClientRows(Json inventory) => [
  for (final row in jsonRows(inventory['clients'])) ...[
    if (row['id'] == 'codex' &&
        jsonRows(row['entries']).any((e) => e['id'] == 'desktop'))
      {
        ...jsonRows(row['entries']).firstWhere((e) => e['id'] == 'desktop'),
        'id': 'codex',
        'family': 'codex',
      }
    else
      {
        ...row,
        if (row['id'] == 'claude' && row['nativeEnabled'] is bool)
          'enabled': row['nativeEnabled'],
      },
    for (final child in jsonRows(row['entries']))
      if (child['id'] != 'desktop')
        {...child, 'family': row['family'] ?? row['id']},
  ],
];

class GatewaySettingsPage extends StatefulWidget {
  const GatewaySettingsPage({super.key, required this.model});
  final BridgeViewModel model;
  @override
  State<GatewaySettingsPage> createState() => _GatewaySettingsState();
}

class _GatewaySettingsState extends State<GatewaySettingsPage> {
  late final scope = GatewayBusiness(widget.model);
  Json? clients;
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
      final value = await scope.read(GatewayResource.clients);
      if (mounted) {
        setState(() {
          clients = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> open(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => page),
    );
    if (mounted) await load();
  }

  Future<void> clientAction(Json row) async {
    final rawFamily = textValue(row['family'] ?? row['id']).split(':').first;
    final family = rawFamily == 'wsl'
        ? 'codex'
        : rawFamily == 'wsl-claude'
        ? 'claude'
        : rawFamily;
    final provider = Provider.values.where((p) => p.name == family).firstOrNull;
    if (provider == null) return;
    final id = textValue(row['id']);
    final target = GatewayBusiness(
      widget.model,
      provider: provider,
      entry: id == family ? '' : id,
    );
    try {
      final inventory = await target.read(GatewayResource.clients);
      row =
          managedClientRows(inventory)
              .where((candidate) => candidate['id'] == id)
              .firstOrNull ??
          (throw StateError('The selected client is unavailable'));
      if (!mounted) return;
      final waiting =
          row['pendingEnable'] == true ||
          const ['starting', 'connecting'].contains(row['connectionState']);
      final ready =
          row['connected'] == true ||
          row['pipeReady'] == true ||
          row['setupStatus'] == 'session-access';
      final modes = jsonRows(row['connectionModes'])
          .where(
            (m) =>
                m['available'] != false &&
                m['configured'] == true &&
                m['id'] is String,
          )
          .toList();
      final canReconnect =
          row['canReconnect'] == true &&
          row['reconnectSupported'] == true &&
          !ready &&
          !waiting &&
          !const [
            'recovery-required',
            'restart-required',
          ].contains(row['setupStatus']);
      final action = await chooseValue(context, textValue(row['name'] ?? id), {
        'review': words(context, '核对未确认操作', 'Review unconfirmed operations'),
        if (widget.model.presentation['showAccounts'] != false)
          'accounts': words(context, '已保存账号及额度', 'Saved accounts & usage'),
        if (row['enabled'] != true) 'enable': words(context, '启用', 'Enable'),
        if (row['enabled'] == true)
          'disable': words(
            context,
            '停用接入（保留客户端运行）',
            'Disable access (keep client running)',
          ),
        if (row['enabled'] == true &&
            row['canQuitDesktop'] != false &&
            row['bindingMode'] != 'manual')
          'quit': words(context, '退出客户端', 'Quit client'),
        if (row['canForceQuit'] == true)
          'force': words(context, '强制关闭客户端', 'Force quit client'),
        if (!ready &&
            !waiting &&
            row['installed'] != false &&
            (row['canInitializeDesktop'] == true ||
                row['setupStatus'] == 'needs-initialization'))
          'initialize': words(context, '初始化连接', 'Initialize connection'),
        if (canReconnect) 'reconnect': words(context, '重新连接', 'Reconnect'),
        if (modes.length > 1)
          'mode': words(context, '切换连接方式', 'Connection mode'),
        if (row['canStartDesktop'] == true && !ready && !waiting)
          'start': words(context, '启动客户端', 'Start client'),
        if (row['retryable'] == true && !ready && !waiting)
          'retry': words(context, '重试连接', 'Retry connection'),
      });
      if (action == null || !mounted) return;
      if (action == 'review') {
        await reviewGatewayOperations(context, target);
        return;
      }
      if (action == 'accounts') {
        await open(
          id.startsWith('wsl:') || id.startsWith('wsl-claude:')
              ? WslAccountPage(scope: target)
              : SavedAccountsPage(scope: target),
        );
        return;
      }
      if (action == 'initialize' || action == 'quit' || action == 'force') {
        if (!await confirmAction(
          context,
          words(context, '确认客户端操作', 'Confirm client operation'),
          action == 'force'
              ? words(
                  context,
                  '将立即结束客户端进程，可能中断任务并丢失未保存内容。确认所有任务已结束后再继续。',
                  'This immediately ends the client process and may interrupt tasks or lose unsaved work. Confirm all tasks are finished before continuing.',
                )
              : words(
                  context,
                  '请确认此客户端中的任务已结束。初始化或退出可能关闭并重新启动客户端，聊天记录保留。',
                  'Confirm that tasks in this client have finished. Initialization or quitting may close and restart it; history is kept.',
                ),
          danger: true,
        )) {
          return;
        }
      }
      if (action == 'reconnect') {
        await target.write(GatewayCommand.reconnectClaude, {});
      } else if (action == 'initialize' && provider == Provider.codex) {
        await target.write(GatewayCommand.initializeCodex, {
          'requestId': widget.model.repository.newId(),
          'confirmed': true,
          'tasksConfirmed': true,
        });
      } else {
        Json fields = {
          'enabled': !const ['quit', 'force', 'disable'].contains(action),
          if (const ['quit', 'force', 'disable'].contains(action))
            'quitDesktop': action != 'disable',
          if (action == 'force') ...{
            'forceDesktop': true,
            'forceConfirmed': true,
          },
          if (const ['quit', 'initialize'].contains(action) &&
              (row['confirmTaskState'] == true ||
                  provider == Provider.codex &&
                      row['desktopRestartRecommended'] == true))
            'acknowledgeUnavailable': true,
        };
        if (action == 'initialize') fields['initializeDesktop'] = true;
        if (provider == Provider.zcode && action == 'initialize') {
          if (row['pipeSupported'] != true) {
            throw StateError('Native pipe initialization is unavailable');
          }
          fields['connectionMode'] = 'private-pipe';
        } else if (action == 'mode' || action == 'enable' && modes.length > 1) {
          if (!mounted) return;
          final mode = await chooseValue(
            context,
            words(context, '连接方式', 'Connection mode'),
            {
              for (final mode in modes)
                textValue(mode['id']): textValue(mode['label']),
            },
          );
          if (mode == null) return;
          if (!mounted) return;
          if (mode != row['connectionMode'] &&
              !await confirmAction(
                context,
                words(context, '切换连接方式？', 'Change connection mode?'),
                textValue(
                  modes.where((m) => m['id'] == mode).first['description'],
                ),
              )) {
            return;
          }
          fields['connectionMode'] = mode;
        }
        await target.write(GatewayCommand.client, fields);
      }
      await load();
      widget.model.clients = await widget.model.repository.clients(
        scope.computer,
      );
      await widget.model.refreshSessions();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      target.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(words(context, '电脑功能与设置', 'Computer features & settings')),
      actions: [
        IconButton(
          onPressed: () => reviewGatewayOperations(context, scope),
          icon: const Icon(Icons.fact_check_outlined),
          tooltip: words(context, '待核对操作', 'Pending verification'),
        ),
        IconButton(onPressed: load, icon: const Icon(Icons.refresh)),
      ],
    ),
    body: clients == null
        ? BusinessLoading(error: error, retry: load)
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (error != null) SelectableText(businessError(context, error)),
              for (final row in managedClientRows(clients!))
                ListTile(
                  leading: Icon(
                    row['connected'] == true
                        ? Icons.computer
                        : Icons.computer_outlined,
                  ),
                  title: Text(textValue(row['name'] ?? row['id'])),
                  subtitle: Text(
                    textValue(
                      row['reason'] ??
                          row['setupStatus'] ??
                          row['connectionStage'],
                    ),
                  ),
                  onTap: () => clientAction(row),
                ),
              if (clients!['wslSupported'] == true)
                ListTile(
                  title: Text(
                    words(context, '扫描 WSL 环境', 'Scan WSL environments'),
                  ),
                  onTap: () async {
                    try {
                      await scope.write(GatewayCommand.client, {
                        'action': 'scan-wsl',
                      });
                      await load();
                    } catch (e) {
                      if (context.mounted) showFailure(context, e);
                    }
                  },
                ),
              ListTile(
                title: Text(words(context, 'CLI 连接管理', 'CLI connections')),
                onTap: () => open(CliConnectionsPage(scope: scope)),
              ),
              if (clients!['wslSupported'] == true)
                for (final provider in [Provider.codex, Provider.claude])
                  ListTile(
                    leading: const Icon(Icons.terminal),
                    title: Text('${providerName(provider)} · WSL'),
                    onTap: () => open(
                      WslEnvironmentsPage(
                        model: widget.model,
                        provider: provider,
                      ),
                    ),
                  ),
              ListTile(
                title: Text(words(context, '全局通知', 'Global notifications')),
                onTap: () => open(
                  GatewayFormPage(scope: scope, spec: notificationDefaultsSpec),
                ),
              ),
              ListTile(
                title: Text(
                  words(context, '通知内容与安全', 'Notification content & security'),
                ),
                onTap: () => open(
                  GatewayFormPage(scope: scope, spec: notificationCommonSpec),
                ),
              ),
              for (final spec in notificationChannelSpecs)
                if (spec.title != 'PushPlus' ||
                    widget.model.presentation['showPushplus'] != false)
                  ListTile(
                    title: Text(spec.title),
                    onTap: () =>
                        open(GatewayFormPage(scope: scope, spec: spec)),
                  ),
              ListTile(
                title: const Text('Webhook'),
                onTap: () => open(WebhookEndpointsPage(scope: scope)),
              ),
              ListTile(
                title: Text(words(context, '文件传输设置', 'File transfer')),
                onTap: () =>
                    open(GatewayFormPage(scope: scope, spec: fileTransferSpec)),
              ),
              ListTile(
                title: Text(
                  words(context, '网络变化自动恢复', 'Automatic network recovery'),
                ),
                onTap: () =>
                    open(GatewayFormPage(scope: scope, spec: networkSpec)),
              ),
            ],
          ),
  );
}

class SavedAccountsPage extends StatefulWidget {
  const SavedAccountsPage({super.key, required this.scope});
  final GatewayBusiness scope;
  @override
  State<SavedAccountsPage> createState() => _SavedAccountsState();
}

class _SavedAccountsState extends State<SavedAccountsPage>
    with WidgetsBindingObserver {
  Json? data;
  Object? error;
  bool busy = false;
  bool loading = false;
  Timer? timer;
  final syncLocalCli = <String>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    timer?.cancel();
    if (state == AppLifecycleState.resumed) {
      timer = Timer(const Duration(seconds: 1), load);
    }
  }

  void schedule() {
    timer?.cancel();
    if (!mounted || !widget.scope.model.foreground || error != null) return;
    final changing =
        ![
          'idle',
          'ready',
          'failed',
        ].contains(jsonObject(data?['switch'])['phase'] ?? 'idle') ||
        [
          'checking',
          'requesting',
        ].contains(jsonObject(data?['desktopUpdate'])['state']) ||
        jsonRows(data?['accounts']).any(
          (row) =>
              jsonObject(jsonObject(row['details'])['usage'])['status'] ==
                  'loading' ||
              jsonObject(jsonObject(row['details'])['models'])['status'] ==
                  'loading',
        );
    timer = Timer(Duration(seconds: changing ? 2 : 30), load);
  }

  Future<void> load() async {
    if (loading || busy || !widget.scope.model.foreground) {
      schedule();
      return;
    }
    loading = true;
    try {
      final value = await widget.scope.read(GatewayResource.accounts);
      if (mounted) {
        setState(() {
          data = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      loading = false;
      schedule();
    }
  }

  Future<void> act(Json row, bool switching, {String section = 'usage'}) async {
    if (busy) return;
    if (switching &&
        !await confirmAction(
          context,
          words(context, '切换已保存账号？', 'Switch saved account?'),
          '${row['name'] ?? row['email'] ?? row['id']}\n\n${words(context, '请确认所有任务（包括未在此处显示的任务）已结束。客户端可能重新启动。', 'Confirm all tasks, including those not shown here, have finished. The client may restart.')}',
          danger: true,
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final codex = widget.scope.provider == Provider.codex;
      final result = await widget.scope.write(
        switching
            ? GatewayCommand.switchAccount
            : GatewayCommand.accountDetails,
        {
          'id': row['id'],
          if (!switching) ...{'refresh': true, if (codex) 'section': section},
          if (switching && !codex && syncLocalCli.contains(row['id']))
            'syncLocalCli': true,
          if (switching && codex) ...{
            'requestId': widget.scope.model.repository.newId(),
            'confirmed': true,
            'tasksConfirmed': true,
            'syncLocalCli': true,
          },
        },
      );
      if (mounted) {
        setState(() => data = result['accounts'] is List ? result : data);
      }
      if (switching) {
        await widget.scope.model.backToSessions();
        await load();
      } else if (mounted) {
        final updated =
            jsonRows(result['accounts'])
                .where((r) => r['id'] == row['id'])
                .firstOrNull ??
            jsonObject(result['account']);
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(
                title: Text(words(context, '账号详情', 'Account details')),
              ),
              body: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  AccountDetails(row: updated.isEmpty ? result : updated),
                ],
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        schedule();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        '${providerName(widget.scope.provider)} · ${words(context, '已保存账号', 'Saved accounts')}',
      ),
      actions: [
        IconButton(
          onPressed: () => reviewGatewayOperations(context, widget.scope),
          icon: const Icon(Icons.fact_check_outlined),
          tooltip: words(context, '待核对操作', 'Pending verification'),
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
              if (error != null) Text(businessError(context, error)),
              for (final row in jsonRows(data!['accounts']))
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          textValue(row['name'] ?? row['email'] ?? row['id']),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(textValue(row['email'] ?? row['kind'])),
                        AccountDetails(row: row),
                        Wrap(
                          children: [
                            if (row['canReadQuota'] != false &&
                                (widget.scope.provider != Provider.codex ||
                                    row['kind'] == 'chatgpt'))
                              TextButton(
                                onPressed: busy ? null : () => act(row, false),
                                child: Text(
                                  words(context, '查询额度', 'Check usage'),
                                ),
                              ),
                            if (widget.scope.provider == Provider.codex)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => act(row, false, section: 'models'),
                                child: Text(
                                  words(context, '可用模型', 'Available models'),
                                ),
                              ),
                            if (data!['canSwitch'] == true &&
                                data!['readOnly'] != true &&
                                row['canSwitch'] != false)
                              TextButton(
                                onPressed:
                                    busy ||
                                        data!['activeId'] == row['id'] ||
                                        (data!['activeIds'] is List &&
                                            (data!['activeIds'] as List)
                                                .contains(row['id']))
                                    ? null
                                    : () => act(row, true),
                                child: Text(
                                  words(context, '切换账号', 'Switch account'),
                                ),
                              ),
                          ],
                        ),
                        if (widget.scope.provider == Provider.claude &&
                            data!['canSyncLocalCli'] == true &&
                            row['kind'] == 'api')
                          CheckboxListTile(
                            value: syncLocalCli.contains(row['id']),
                            title: Text(
                              words(
                                context,
                                '同时应用到本机 CLI',
                                'Also apply to local CLI',
                              ),
                            ),
                            onChanged: busy
                                ? null
                                : (v) => setState(() {
                                    if (v == true) {
                                      syncLocalCli.add(textValue(row['id']));
                                    } else {
                                      syncLocalCli.remove(row['id']);
                                    }
                                  }),
                          ),
                      ],
                    ),
                  ),
                ),
              for (final host in jsonRows(data!['sshHosts']))
                ListTile(
                  title: Text('SSH · ${host['label'] ?? host['host']}'),
                  subtitle: Text(
                    textValue(host['error'] ?? host['state'] ?? host['status']),
                  ),
                  trailing: TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            setState(() => busy = true);
                            try {
                              await widget.scope.write(
                                GatewayCommand.sshRetry,
                                {'host': host['host']},
                              );
                              await load();
                            } catch (e) {
                              if (context.mounted) showFailure(context, e);
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                    child: Text(words(context, '重试连接', 'Retry connection')),
                  ),
                ),
              if (widget.scope.provider == Provider.codex)
                SwitchListTile(
                  title: Text(words(context, '额度重置动态', 'Quota reset activity')),
                  value: data!['resetDynamicEnabled'] == true,
                  onChanged: busy
                      ? null
                      : (enabled) async {
                          try {
                            await widget.scope.write(
                              GatewayCommand.resetDynamic,
                              {'enabled': enabled},
                            );
                            await load();
                          } catch (e) {
                            if (context.mounted) showFailure(context, e);
                          }
                        },
                ),
              if (widget.scope.provider == Provider.codex) ...[
                for (final setting in const {
                  'globalReset': ('重置动态提醒', 'Reset activity reminders'),
                  'lowQuota': (
                    '额度不足 10% 时提醒',
                    'Notify when quota falls below 10%',
                  ),
                  'quotaReset': ('确认额度恢复后提醒', 'Notify after quota recovery'),
                  'resetExpiry': (
                    '重置卡到期前 24 小时提醒',
                    'Notify 24 hours before reset credits expire',
                  ),
                  'subscriptionExpiry': (
                    '订阅周期截止前提醒',
                    'Notify before subscription expiry',
                  ),
                  'desktopUpdate': (
                    'Codex Desktop 新版本提醒',
                    'Codex Desktop update reminders',
                  ),
                }.entries)
                  if (data!['scope'] != 'profile' ||
                      setting.key != 'desktopUpdate')
                    SwitchListTile(
                      title: Text(
                        words(context, setting.value.$1, setting.value.$2),
                      ),
                      value:
                          jsonObject(data!['reminders'])[setting.key] == true,
                      onChanged: busy
                          ? null
                          : (value) => manage(GatewayCommand.accountReminders, {
                              'preferences': {setting.key: value},
                            }),
                    ),
                if (data!['reminderError'] != null)
                  Text(textValue(data!['reminderError'])),
                ListTile(
                  title: const Text('Codex Desktop'),
                  subtitle: Text(
                    '${jsonObject(data!['desktopUpdate'])['currentVersion'] ?? ''}\n${jsonObject(data!['desktopUpdate'])['message'] ?? jsonObject(data!['desktopUpdate'])['state'] ?? ''}',
                  ),
                ),
                if ((data!['canManageDesktop'] ?? data!['canSwitch']) == true)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => manage(GatewayCommand.desktopUpdate, {
                            'action': 'checkDesktopUpdate',
                          }),
                    child: Text(
                      words(context, '查看 Codex 新版本', 'Check Codex updates'),
                    ),
                  ),
                if (jsonObject(data!['desktopUpdate'])['canRequest'] == true &&
                    jsonObject(data!['desktopUpdate'])['currentBuild'] != null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            if (!await confirmAction(
                              context,
                              words(
                                context,
                                '打开电脑端更新窗口？',
                                'Open desktop updater?',
                              ),
                              words(
                                context,
                                '确认所有桌面任务已结束。后续检查、下载与安装由电脑端处理。',
                                'Confirm all desktop tasks have finished. The desktop handles further checks, downloads and installation.',
                              ),
                            )) {
                              return;
                            }
                            await manage(GatewayCommand.desktopUpdate, {
                              'action': 'requestDesktopUpdate',
                              'currentBuild': jsonObject(
                                data!['desktopUpdate'],
                              )['currentBuild'],
                              'requestId': widget.scope.model.repository
                                  .newId(),
                              'confirmed': true,
                              'tasksConfirmed': true,
                            });
                          },
                    child: Text(
                      words(context, '打开电脑端更新窗口', 'Open desktop updater'),
                    ),
                  ),
              ],
            ],
          ),
  );

  Future<void> manage(GatewayCommand command, Json fields) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await widget.scope.write(command, fields);
      if (mounted) {
        setState(() {
          data = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        schedule();
      }
    }
  }
}

class CliConnectionsPage extends StatefulWidget {
  const CliConnectionsPage({super.key, required this.scope});
  final GatewayBusiness scope;
  @override
  State<CliConnectionsPage> createState() => _CliConnectionsState();
}

class _CliConnectionsState extends State<CliConnectionsPage>
    with WidgetsBindingObserver {
  Json? data;
  Object? error;
  bool busy = false;
  bool loading = false;
  Timer? timer;
  final selected = <String>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    timer?.cancel();
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    timer?.cancel();
    if (loading || !widget.scope.model.foreground) return;
    loading = true;
    try {
      final value = await widget.scope.read(GatewayResource.cliConnections);
      if (mounted) {
        setState(() {
          data = value;
          error = null;
          final available = jsonRows(value['connections'])
              .map((row) => row['key'])
              .toSet();
          selected.removeWhere((key) => !available.contains(key));
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      loading = false;
      if (mounted && widget.scope.model.foreground && error == null) {
        timer = Timer(const Duration(seconds: 2), load);
      }
    }
  }

  Future<void> release(bool stop) async {
    if (selected.isEmpty || busy) return;
    if (!await confirmAction(
      context,
      words(
        context,
        stop ? '停止并释放连接？' : '完成任务后释放连接？',
        stop ? 'Stop and release connections?' : 'Release after tasks finish?',
      ),
      words(
        context,
        '将释放所选网关连接，保留聊天历史。',
        'Releases the selected gateway connections and keeps chat history.',
      ),
      danger: stop,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.scope.write(GatewayCommand.cliConnections, {
        'id': widget.scope.model.repository.newId(),
        'connections': selected.toList(),
        'mode': stop ? 'stop' : 'wait',
      });
      selected.clear();
      await load();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(words(context, 'CLI 连接管理', 'CLI connections')),
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
              for (final row in jsonRows(data!['connections']))
                CheckboxListTile(
                  title: Text(textValue(row['title'] ?? row['sessionId'])),
                  subtitle: Text(
                    '${row['provider']} · ${row['location'] ?? row['host']}',
                  ),
                  value: selected.contains(row['key']),
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                          v == true
                              ? selected.add(textValue(row['key']))
                              : selected.remove(row['key']);
                        }),
                ),
              Wrap(
                children: [
                  TextButton(
                    onPressed: busy ? null : () => release(false),
                    child: Text(words(context, '释放所选', 'Release selected')),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => release(true),
                    child: Text(words(context, '停止并释放', 'Stop and release')),
                  ),
                ],
              ),
              for (final job in jsonRows(data!['operations']))
                for (final row in jsonRows(job['results']))
                  ListTile(
                    title: Text(textValue(row['title'])),
                    subtitle: Text(
                      '${row['status']}\n${row['error'] ?? row['notice'] ?? ''}',
                    ),
                  ),
            ],
          ),
  );
}

typedef SettingField = ({String key, String zh, String en, String type});

class SettingSpec {
  const SettingSpec(
    this.title,
    this.resource,
    this.command,
    this.fields, {
    this.test,
  });
  final String title;
  final GatewayResource resource;
  final GatewayCommand command;
  final List<SettingField> fields;
  final GatewayCommand? test;
}

const notificationDefaultsSpec = SettingSpec(
  '通知 / Notifications',
  GatewayResource.notificationDefaults,
  GatewayCommand.notificationDefaults,
  [
    (key: 'requests', zh: '请求处理通知', en: 'Request notifications', type: 'bool'),
    (
      key: 'completion',
      zh: '运行完毕通知',
      en: 'Completion notifications',
      type: 'bool',
    ),
  ],
);
const notificationCommonSpec = SettingSpec(
  '通知内容 / Content',
  GatewayResource.notificationCommon,
  GatewayCommand.notificationCommon,
  [
    (key: 'securityEnabled', zh: '安全提醒', en: 'Security alerts', type: 'bool'),
    (
      key: 'addressEnabled',
      zh: '入口通知',
      en: 'Gateway address notifications',
      type: 'bool',
    ),
    (key: 'addressName', zh: '网关名称', en: 'Gateway name', type: 'text'),
    (key: 'includeTitle', zh: '包含聊天标题', en: 'Include chat title', type: 'bool'),
    (
      key: 'clickBase',
      zh: '通知跳转地址',
      en: 'Notification destination',
      type: 'text',
    ),
  ],
);
const fileTransferSpec = SettingSpec(
  '文件传输 / File transfer',
  GatewayResource.fileTransfer,
  GatewayCommand.fileTransfer,
  [
    (
      key: 'clickDownloadMiB',
      zh: '点击下载阈值（MiB）',
      en: 'Click download limit (MiB)',
      type: 'number',
    ),
  ],
);
const networkSpec = SettingSpec(
  '网络恢复 / Network recovery',
  GatewayResource.networkAdaptation,
  GatewayCommand.networkAdaptation,
  [
    (
      key: 'enabled',
      zh: '网络变化自动恢复',
      en: 'Recover when the network changes',
      type: 'bool',
    ),
  ],
);
const notificationChannelSpecs = [
  SettingSpec('Bark', GatewayResource.bark, GatewayCommand.bark, [
    (key: 'barkEnabled', zh: '启用 Bark', en: 'Enable Bark', type: 'bool'),
    (key: 'barkServer', zh: '服务地址', en: 'Server URL', type: 'text'),
    (
      key: 'barkKey',
      zh: 'Device Key（留空保留）',
      en: 'Device key (blank keeps saved key)',
      type: 'secret',
    ),
    (key: 'clearBarkKey', zh: '清除已保存密钥', en: 'Clear saved key', type: 'bool'),
  ], test: GatewayCommand.testBark),
  SettingSpec('ntfy', GatewayResource.ntfy, GatewayCommand.ntfy, [
    (key: 'enabled', zh: '启用 ntfy', en: 'Enable ntfy', type: 'bool'),
    (key: 'server', zh: '服务地址', en: 'Server URL', type: 'text'),
    (key: 'topic', zh: '主题', en: 'Topic', type: 'text'),
    (
      key: 'token',
      zh: 'Token（留空保留）',
      en: 'Token (blank keeps saved token)',
      type: 'secret',
    ),
    (
      key: 'clearToken',
      zh: '清除已保存 Token',
      en: 'Clear saved token',
      type: 'bool',
    ),
  ], test: GatewayCommand.testNtfy),
  SettingSpec('PushPlus', GatewayResource.pushplus, GatewayCommand.pushplus, [
    (
      key: 'pushplusEnabled',
      zh: '启用 PushPlus',
      en: 'Enable PushPlus',
      type: 'bool',
    ),
    (
      key: 'pushplusToken',
      zh: 'Token（留空保留）',
      en: 'Token (blank keeps saved token)',
      type: 'secret',
    ),
    (
      key: 'clearPushplusToken',
      zh: '清除已保存 Token',
      en: 'Clear saved token',
      type: 'bool',
    ),
  ], test: GatewayCommand.testPushplus),
];

class GatewayFormPage extends StatefulWidget {
  const GatewayFormPage({
    super.key,
    required this.scope,
    required this.spec,
    this.parameters = const {},
  });
  final GatewayBusiness scope;
  final SettingSpec spec;
  final Json parameters;
  @override
  State<GatewayFormPage> createState() => _GatewayFormState();
}

class _GatewayFormState extends State<GatewayFormPage> {
  Json? data;
  Object? error;
  bool busy = false;
  final fields = <String, TextEditingController>{};
  final flags = <String, bool>{};
  bool revealUrl = false;
  Json templates = {};
  static const webhookProviders = {
    'auto': ('自动识别', 'Automatic'),
    'generic': ('自定义 Webhook', 'Custom webhook'),
    'feishu': ('飞书', 'Feishu'),
    'dingtalk': ('钉钉', 'DingTalk'),
    'discord': ('Discord', 'Discord'),
    'telegram': ('Telegram', 'Telegram'),
  };
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      var value = await widget.scope.read(widget.spec.resource);
      templates = jsonObject(value['webhookTemplates']);
      if (widget.parameters['webhookId'] != null) {
        value =
            jsonRows(value['webhookEndpoints'])
                .where((r) => r['webhookId'] == widget.parameters['webhookId'])
                .firstOrNull ??
            value;
      }
      if (!mounted) return;
      for (final f in widget.spec.fields) {
        if (f.type == 'bool') {
          flags[f.key] = value[f.key] == true;
        } else {
          fields.putIfAbsent(f.key, () => TextEditingController()).text =
              f.type == 'secret' ? '' : textValue(value[f.key]);
        }
      }
      setState(() {
        data = value;
        error = null;
        revealUrl = false;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  void useTemplate({bool onlyDefault = false}) {
    final controller = fields['webhookBodyTemplate']!;
    if (onlyDefault &&
        controller.text.trim().isNotEmpty &&
        !templates.values.contains(controller.text)) {
      return;
    }
    final provider = fields['webhookProvider']!.text;
    final selected = provider == 'auto'
        ? (data?['webhookResolvedProvider'] ?? 'generic')
        : provider;
    controller.text = textValue(templates[selected] ?? templates['generic']);
  }

  Future<void> toggleUrl() async {
    final controller = fields['webhookUrl']!;
    if (revealUrl || controller.text.isNotEmpty) {
      setState(() => revealUrl = !revealUrl);
      return;
    }
    setState(() => busy = true);
    try {
      final value = await widget.scope.write(
        GatewayCommand.webhookUrl,
        widget.parameters,
      );
      if (mounted) {
        setState(() {
          controller.text = textValue(value['webhookUrl']);
          revealUrl = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save({bool test = false}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final body = <String, dynamic>{...widget.parameters};
      if (!test && widget.spec.resource == GatewayResource.webhook) {
        body['action'] = 'upsert';
      }
      if (!test) {
        for (final f in widget.spec.fields) {
          body[f.key] = f.type == 'bool'
              ? flags[f.key]
              : f.type == 'number'
              ? num.parse(fields[f.key]!.text)
              : f.key == 'webhookHeaders'
              ? (fields[f.key]!.text.trim().isEmpty
                    ? <String, dynamic>{}
                    : jsonObject(fields[f.key]!.text))
              : fields[f.key]!.text;
        }
      }
      final result = await widget.scope.write(
        test ? widget.spec.test! : widget.spec.command,
        body,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              textValue(result['message'] ?? words(context, '已保存', 'Saved')),
            ),
          ),
        );
        if (!test) await load();
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.spec.title)),
    body: data == null
        ? BusinessLoading(error: error, retry: load)
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              for (final f in widget.spec.fields)
                f.key == 'webhookProvider'
                    ? DropdownButtonFormField<String>(
                        initialValue:
                            webhookProviders.containsKey(fields[f.key]!.text)
                            ? fields[f.key]!.text
                            : 'auto',
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: words(context, '服务类型', 'Provider'),
                        ),
                        items: [
                          for (final p in webhookProviders.entries)
                            DropdownMenuItem(
                              value: p.key,
                              child: Text(
                                words(context, p.value.$1, p.value.$2),
                              ),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) => setState(() {
                                fields[f.key]!.text = value!;
                                useTemplate(onlyDefault: true);
                              }),
                      )
                    : f.type == 'bool'
                    ? SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(words(context, f.zh, f.en)),
                        value: flags[f.key] ?? false,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => flags[f.key] = v),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: TextField(
                          controller: fields[f.key],
                          enabled: !busy,
                          obscureText:
                              f.type == 'secret' &&
                              !(f.key == 'webhookUrl' && revealUrl),
                          keyboardType: f.type == 'number'
                              ? TextInputType.number
                              : TextInputType.text,
                          minLines: f.type == 'multiline' ? 3 : 1,
                          maxLines: f.type == 'multiline' ? 8 : 1,
                          decoration: InputDecoration(
                            labelText: words(context, f.zh, f.en),
                            suffixIcon: f.key == 'webhookUrl'
                                ? IconButton(
                                    tooltip: words(
                                      context,
                                      revealUrl ? '隐藏地址' : '显示地址',
                                      revealUrl ? 'Hide URL' : 'Reveal URL',
                                    ),
                                    icon: Icon(
                                      revealUrl
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                    ),
                                    onPressed: busy ? null : toggleUrl,
                                  )
                                : null,
                          ),
                        ),
                      ),
              if (templates.isNotEmpty)
                TextButton(
                  onPressed: busy ? null : () => useTemplate(),
                  child: Text(
                    words(context, '使用所选模板', 'Use selected template'),
                  ),
                ),
              if (error != null) SelectableText(businessError(context, error)),
              if (busy) const LinearProgressIndicator(),
              FilledButton(
                onPressed: busy ? null : save,
                child: Text(words(context, '保存', 'Save')),
              ),
              if (widget.spec.test != null)
                OutlinedButton(
                  onPressed: busy ? null : () => save(test: true),
                  child: Text(
                    words(context, '发送测试通知', 'Send test notification'),
                  ),
                ),
            ],
          ),
  );
}

const webhookSpec = SettingSpec(
  'Webhook',
  GatewayResource.webhook,
  GatewayCommand.webhookEndpoints,
  [
    (key: 'webhookName', zh: '名称', en: 'Name', type: 'text'),
    (key: 'webhookEnabled', zh: '启用', en: 'Enabled', type: 'bool'),
    (
      key: 'webhookProvider',
      zh: '类型（auto、generic、feishu、dingtalk、wecom）',
      en: 'Provider (auto, generic, feishu, dingtalk, wecom)',
      type: 'text',
    ),
    (
      key: 'webhookUrl',
      zh: '地址（留空保留）',
      en: 'URL (blank keeps saved URL)',
      type: 'secret',
    ),
    (
      key: 'webhookHeaders',
      zh: '请求头 JSON（留空保留）',
      en: 'Headers JSON (blank keeps saved headers)',
      type: 'secret',
    ),
    (key: 'webhookSignEnabled', zh: '启用签名', en: 'Enable signing', type: 'bool'),
    (
      key: 'webhookSignSecret',
      zh: '签名密钥（留空保留）',
      en: 'Signing secret (blank keeps saved secret)',
      type: 'secret',
    ),
    (
      key: 'webhookBodyTemplate',
      zh: '消息模板',
      en: 'Body template',
      type: 'multiline',
    ),
    (key: 'clearWebhookUrl', zh: '清除地址', en: 'Clear URL', type: 'bool'),
    (
      key: 'clearWebhookHeaders',
      zh: '清除请求头',
      en: 'Clear headers',
      type: 'bool',
    ),
    (
      key: 'clearWebhookSignSecret',
      zh: '清除签名密钥',
      en: 'Clear signing secret',
      type: 'bool',
    ),
  ],
  test: GatewayCommand.testWebhook,
);

class WebhookEndpointsPage extends StatefulWidget {
  const WebhookEndpointsPage({super.key, required this.scope});
  final GatewayBusiness scope;
  @override
  State<WebhookEndpointsPage> createState() => _WebhookEndpointsState();
}

class _WebhookEndpointsState extends State<WebhookEndpointsPage> {
  Json? data;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.scope.read(GatewayResource.webhook);
      if (mounted) setState(() => data = value);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> edit(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => GatewayFormPage(
          scope: widget.scope,
          spec: webhookSpec,
          parameters: {'webhookId': id},
        ),
      ),
    );
    await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Webhook'),
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () async {
            final name = await promptText(
              context,
              words(context, 'Webhook 名称', 'Webhook name'),
            );
            if (name == null) return;
            try {
              await widget.scope.write(GatewayCommand.webhookEndpoints, {
                'action': 'upsert',
                'webhookName': name,
              });
              await load();
            } catch (e) {
              if (context.mounted) showFailure(context, e);
            }
          },
        ),
      ],
    ),
    body: data == null
        ? BusinessLoading(error: error, retry: load)
        : ListView(
            children: [
              for (final row in jsonRows(data!['webhookEndpoints']))
                ListTile(
                  title: Text(
                    textValue(row['webhookName'] ?? row['webhookId']),
                  ),
                  subtitle: Text(textValue(row['webhookProvider'])),
                  onTap: () => edit(textValue(row['webhookId'])),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (!await confirmAction(
                        context,
                        words(context, '删除 Webhook？', 'Delete webhook?'),
                        textValue(row['webhookName']),
                        danger: true,
                      )) {
                        return;
                      }
                      try {
                        await widget.scope.write(
                          GatewayCommand.webhookEndpoints,
                          {'action': 'delete', 'webhookId': row['webhookId']},
                        );
                        await load();
                      } catch (e) {
                        if (context.mounted) showFailure(context, e);
                      }
                    },
                  ),
                ),
              if (jsonRows(data!['webhookEndpoints']).isEmpty)
                ListTile(
                  title: Text(words(context, '默认 Webhook', 'Default webhook')),
                  onTap: () => edit('legacy'),
                ),
            ],
          ),
  );
}
