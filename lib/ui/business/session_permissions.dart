import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../design/bridge_theme.dart';
import 'common.dart';

String sessionPermissionLabel(BuildContext context, Json state) {
  final label = textValue(state['permissionLabel']);
  if (label.isNotEmpty) return label;
  return switch (state['permissionMode']) {
    'ask' => words(context, '请求批准', 'Ask for approval'),
    'auto-review' => words(context, '帮我批准', 'Auto review'),
    'full-access' => words(context, '完全访问', 'Full access'),
    _ => words(context, '权限', 'Permissions'),
  };
}

Future<void> sessionPermissions(BuildContext context, SessionBusiness scope) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => _PermissionDialog(scope: scope),
    );

class _PermissionDialog extends StatefulWidget {
  const _PermissionDialog({required this.scope});
  final SessionBusiness scope;
  @override
  State<_PermissionDialog> createState() => _PermissionDialogState();
}

class _PermissionDialogState extends State<_PermissionDialog> {
  SessionBusiness get scope => widget.scope;
  late final String runtime, account;
  bool get codex => scope.session.provider == Provider.codex;
  bool get current {
    final snapshot = scope.model.snapshot;
    final metadata = jsonObject(snapshot?.metadata);
    final state = metadata['session'] is Map
        ? jsonObject(metadata['session'])
        : metadata;
    return scope.current &&
        scope.model.selected == scope.session &&
        snapshot?.accountIdentity == account &&
        (!codex ||
            (jsonObject(state['access'])['runtime'] ?? 'desktop') == runtime);
  }

  List<Json> options = [];
  String selected = '';
  String? pending;
  bool loading = true, saving = false;
  Object? error;
  int revision = 0;

  @override
  void initState() {
    super.initState();
    // Freeze the opening identity before the first asynchronous refresh.
    runtime = textValue(
      jsonObject(scope.state['access'])['runtime'] ?? 'desktop',
    );
    account = scope.snapshot.accountIdentity;
    load();
  }

  @override
  void dispose() {
    revision++;
    super.dispose();
  }

  Future<void> load() async {
    if (!current) return;
    final request = ++revision;
    setState(() => loading = true);
    try {
      await scope.refresh();
      if (!mounted || request != revision || !current) return;
      final state = scope.state, access = jsonObject(scope.state['access']);
      if (codex && (access['runtime'] ?? 'desktop') != runtime) {
        throw StateError('Session runtime changed; reopen permission settings');
      }
      if (codex && access['canChangePermissions'] != true ||
          !codex && scope.capabilities['permissions'] != true) {
        throw StateError('Permissions are unavailable for this chat');
      }
      // The ordinary desktop API only supports permission writes. Its GET
      // endpoint is reserved for capability checks on Linux and native CLI.
      final data =
          codex && runtime != 'cli' && state['linuxPermissionChecks'] != true
          ? <String, dynamic>{
              'current': state['permissionMode'],
              'options': [
                for (final preset in ['ask', 'auto-review', 'full-access'])
                  {'preset': preset, 'available': true},
              ],
            }
          : await scope.read(SessionResource.permissions);
      if (!mounted || request != revision || !current) return;
      setState(() {
        options = jsonRows(data['options'])
            .where(
              (option) =>
                  !codex ||
                  const {
                    'ask',
                    'auto-review',
                    'full-access',
                  }.contains(option['preset']),
            )
            .toList();
        selected = textValue(
          data['current'] ?? data['mode'] ?? state['permissionMode'],
        );
        error = null;
      });
      if (pending != null && selected == pending) complete();
    } catch (e) {
      if (mounted && request == revision) setState(() => error = e);
    } finally {
      if (mounted && request == revision) setState(() => loading = false);
    }
  }

  String optionId(Json option) =>
      textValue(option['preset'] ?? option['value'] ?? option['id']);
  bool available(Json option) =>
      codex ? option['available'] == true : option['available'] != false;

  void complete() {
    final messenger = ScaffoldMessenger.of(context);
    final text = words(context, '权限已更新', 'Permissions updated');
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> save(Json option) async {
    if (!current ||
        saving ||
        loading ||
        pending != null ||
        !available(option)) {
      return;
    }
    final chosen = optionId(option);
    if (chosen.isEmpty) return;
    if (chosen == selected) {
      Navigator.pop(context);
      return;
    }
    setState(() => saving = true);
    final elevated =
        chosen == 'full-access' ||
        chosen == 'bypassPermissions' ||
        option['requiresConfirmation'] == true;
    try {
      if (elevated &&
          !await confirmAction(
            context,
            words(context, '启用完全访问？', 'Enable full access?'),
            words(
              context,
              '允许此会话访问电脑文件和网络，无需逐次批准。请确认你信任当前任务。',
              'Allow this chat to access files and the network without individual approvals. Confirm that you trust this task.',
            ),
            danger: true,
          )) {
        return;
      }
      if (!mounted || !current) return;
      setState(() {
        pending = chosen;
        error = null;
      });
      final result = await scope.write(
        SessionCommand.permissions,
        codex
            ? {
                'preset': chosen,
                'confirmed': elevated,
                'expectedRuntime': runtime,
              }
            : {'mode': chosen, if (elevated) 'confirmed': true},
      );
      if (!mounted || !current) return;
      if (codex
          ? result['confirmed'] == true
          : result['mode'] == chosen ||
                scope.state['permissionMode'] == chosen) {
        complete();
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  (String, String, IconData) copyFor(BuildContext context, Json option) =>
      switch (optionId(option)) {
        'ask' => (
          words(context, '请求批准', 'Ask for approval'),
          words(
            context,
            '需要额外权限时询问你。',
            'Ask you when additional permissions are needed.',
          ),
          Icons.shield_outlined,
        ),
        'auto-review' => (
          words(context, '帮我批准', 'Auto review'),
          words(
            context,
            '由 Codex 审核需要额外权限的操作。',
            'Codex reviews actions that need additional permissions.',
          ),
          Icons.verified_user_outlined,
        ),
        'full-access' => (
          words(context, '完全访问权限', 'Full access'),
          words(
            context,
            '允许访问工作区外的文件和网络，无需逐次批准。',
            'Allow access to files outside the workspace and the network without individual approvals.',
          ),
          Icons.bolt_outlined,
        ),
        _ => (
          textValue(option['label'] ?? option['name'] ?? optionId(option)),
          textValue(option['description']),
          Icons.shield_outlined,
        ),
      };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scope.model,
    builder: (context, _) {
      final theme = Theme.of(context), colors = theme.colorScheme;
      return PopScope(
        canPop: !saving,
        child: Dialog(
          key: const Key('session-permissions-dialog'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 20,
          ),
          constraints: const BoxConstraints(maxWidth: 480),
          child: BridgeGlass(
            style: BridgeGlassStyle.regular,
            radius: 20,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        words(context, '会话权限', 'Chat permissions'),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('close-permissions'),
                      tooltip: words(context, '关闭', 'Close'),
                      onPressed: saving ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          words(
                            context,
                            '保存后从下一轮生效',
                            'Applies from the next turn',
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (loading || saving && pending != null)
                          const LinearProgressIndicator(minHeight: 2),
                        for (final option in options) ...[
                          Builder(
                            builder: (context) {
                              final (title, description, icon) = copyFor(
                                context,
                                option,
                              );
                              final chosen = optionId(option) == selected;
                              final allowed = available(option);
                              return Semantics(
                                selected: chosen,
                                child: Material(
                                  color: chosen
                                      ? colors.primaryContainer
                                      : colors.surfaceContainer,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(
                                      color: chosen
                                          ? colors.primary
                                          : colors.outlineVariant,
                                    ),
                                  ),
                                  child: InkWell(
                                    key: ValueKey(
                                      'permission-${optionId(option)}',
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    onTap:
                                        current &&
                                            !loading &&
                                            !saving &&
                                            pending == null &&
                                            allowed
                                        ? () => save(option)
                                        : null,
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Row(
                                        children: [
                                          Icon(
                                            icon,
                                            color: allowed
                                                ? colors.onSurface
                                                : colors.onSurfaceVariant,
                                            size: 24,
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  title,
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w600,
                                                    color: allowed
                                                        ? colors.onSurface
                                                        : colors
                                                              .onSurfaceVariant,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  allowed
                                                      ? description
                                                      : textValue(
                                                          option['reason'],
                                                        ).isNotEmpty
                                                      ? textValue(
                                                          option['reason'],
                                                        )
                                                      : words(
                                                          context,
                                                          '当前运行环境不支持此权限。',
                                                          'Unavailable in this runtime.',
                                                        ),
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    height: 1.5,
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (chosen) ...[
                                            const SizedBox(width: 10),
                                            Icon(
                                              Icons.check,
                                              color: colors.primary,
                                              size: 22,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (!current ||
                            error != null ||
                            pending != null ||
                            !loading && options.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              !current
                                  ? words(
                                      context,
                                      '聊天或运行环境已切换，请重新打开权限设置。',
                                      'Chat or runtime changed. Reopen permission settings.',
                                    )
                                  : error != null
                                  ? businessError(context, error)
                                  : pending != null
                                  ? words(
                                      context,
                                      '已提交权限设置，等待客户端确认。',
                                      'Permission change submitted. Waiting for confirmation.',
                                    )
                                  : words(
                                      context,
                                      '当前客户端未提供可用的权限选项。',
                                      'No permission options are available.',
                                    ),
                              style: TextStyle(
                                fontSize: 12,
                                color: error != null
                                    ? colors.error
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (error != null ||
                    pending != null ||
                    !loading && options.isEmpty)
                  TextButton.icon(
                    key: const Key('refresh-permissions'),
                    onPressed: loading || saving || !current ? null : load,
                    icon: const Icon(Icons.refresh),
                    label: Text(words(context, '刷新', 'Refresh')),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
