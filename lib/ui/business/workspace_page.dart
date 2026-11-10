import 'package:flutter/material.dart';

import 'common.dart';
import 'files_panel.dart';
import 'git_panel.dart';
import 'terminal_panel.dart';
import 'tasks_panel.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.scope,
    this.initialFile,
    this.onClose,
    this.initialLine = 1,
  });
  final SessionBusiness scope;
  final String? initialFile;
  final int initialLine;
  final VoidCallback? onClose;
  @override
  State<WorkspacePage> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<WorkspacePage>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  late final key = widget.scope.model.viewKey(widget.scope.snapshot);
  @override
  void initState() {
    super.initState();
    final previous = jsonObject(
      widget.scope.model.presentation['workspaceTabs'],
    )[key];
    tabs = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialFile == null && previous is int
          ? previous.clamp(0, 3)
          : 0,
    );
    tabs.addListener(remember);
  }

  void remember() {
    if (!tabs.indexIsChanging) {
      widget.scope.model.rememberView('workspaceTabs', key, tabs.index);
    }
  }

  @override
  void dispose() {
    tabs.removeListener(remember);
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: widget.onClose == null
          ? null
          : IconButton(
              onPressed: widget.onClose,
              icon: const Icon(Icons.close),
              tooltip: words(context, '关闭工作台', 'Close workspace'),
            ),
      title: Text(widget.scope.snapshot.title),
      bottom: TabBar(
        controller: tabs,
        isScrollable: true,
        tabs: [
          Tab(text: words(context, '文件', 'Files')),
          const Tab(text: 'Git'),
          Tab(text: words(context, '终端', 'Terminal')),
          Tab(text: words(context, '派生任务', 'Related tasks')),
        ],
      ),
    ),
    body: TabBarView(
      controller: tabs,
      children: [
        FilesPanel(
          scope: widget.scope,
          initialFile: widget.initialFile,
          initialLine: widget.initialLine,
        ),
        GitPanel(scope: widget.scope),
        TerminalPanel(scope: widget.scope),
        TasksPanel(scope: widget.scope, onOpenSession: widget.onClose),
      ],
    ),
  );
}
