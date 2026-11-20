import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../design/bridge_theme.dart';
import 'common.dart';
import 'files_panel.dart';
import 'git_panel.dart';
import 'tasks_panel.dart';
import 'terminal_panel.dart';

enum WorkspaceTool {
  files,
  git,
  terminal,
  sideChat,
  subagents;

  String label(BuildContext context) => switch (this) {
    files => words(context, '文件', 'Files'),
    git => 'Git',
    terminal => words(context, '终端', 'Terminal'),
    sideChat => words(context, '侧边聊天', 'Side chat'),
    subagents => words(context, '子智能体', 'Subagents'),
  };

  String description(BuildContext context) => switch (this) {
    files => words(
      context,
      '浏览项目文件、上传与下载',
      'Browse, upload and download project files',
    ),
    git => words(
      context,
      '历史、暂存、提交与分支管理',
      'History, staging, commits and branches',
    ),
    terminal => words(
      context,
      '运行项目命令、构建与查看输出',
      'Run project commands, builds and view output',
    ),
    sideChat => words(
      context,
      '新建或继续原生侧边聊天',
      'Start or continue a native side chat',
    ),
    subagents => words(
      context,
      '查看派生任务关系与执行记录',
      'View task relationships and execution history',
    ),
  };

  bool available(SessionBusiness scope) {
    if (this == files || this == git) return true;
    final capabilities = scope.capabilities;
    if (this == terminal) return capabilities['terminal'] != false;
    if (scope.session.provider != Provider.codex) {
      return this == subagents && capabilities['tasks'] == true;
    }
    final access = jsonObject(scope.state['access']);
    final canUseSideChat =
        access.isEmpty ||
        (access['readOnly'] != true &&
            (access['canUseSideChat'] ?? (access['source'] == 'desktop')) ==
                true);
    return canUseSideChat &&
        (this != sideChat || capabilities['sideChat'] != false);
  }

  Widget panel(SessionBusiness scope, {required bool active}) => switch (this) {
    files => FilesPanel(scope: scope),
    git => GitPanel(scope: scope),
    terminal => TerminalPanel(scope: scope, active: active),
    sideChat => TasksPanel(
      scope: scope,
      kind: WorkspaceTaskKind.sideChats,
      active: active,
    ),
    subagents => TasksPanel(
      scope: scope,
      kind: scope.session.provider == Provider.codex
          ? WorkspaceTaskKind.subagents
          : WorkspaceTaskKind.background,
      active: active,
    ),
  };
}

Future<WorkspaceTool?> chooseWorkspaceTool(
  BuildContext context,
  SessionBusiness scope,
) => showDialog<WorkspaceTool>(
  context: context,
  barrierColor: Colors.transparent,
  builder: (dialog) {
    final theme = Theme.of(dialog), colors = theme.colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      constraints: const BoxConstraints(maxWidth: 480),
      child: BridgeGlass(
        style: BridgeGlassStyle.regular,
        radius: 22,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    words(dialog, '新标签页', 'New tab'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton.outlined(
                  tooltip: words(dialog, '关闭', 'Close'),
                  onPressed: () => Navigator.pop(dialog),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    for (final tool in WorkspaceTool.values)
                      OutlinedButton(
                        key: ValueKey(('new-workspace-tool', tool)),
                        onPressed: tool.available(scope)
                            ? () => Navigator.pop(dialog, tool)
                            : null,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 70),
                          padding: const EdgeInsets.all(14),
                          alignment: Alignment.centerLeft,
                          foregroundColor: colors.onSurface,
                          backgroundColor: colors.surfaceContainerLow,
                          disabledBackgroundColor: colors.surfaceContainerLow,
                          side: BorderSide(color: colors.outlineVariant),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 5,
                          children: [
                            Text(
                              tool.label(dialog),
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              tool.available(scope)
                                  ? tool.description(dialog)
                                  : words(
                                      dialog,
                                      '当前客户端尚未提供此能力',
                                      'Unavailable in this client',
                                    ),
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  },
);
