import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';
import 'content_preview.dart';

class GitPanel extends StatefulWidget {
  const GitPanel({super.key, required this.scope});
  final SessionBusiness scope;
  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel>
    with AutomaticKeepAliveClientMixin {
  Json? state, content;
  Object? error;
  bool busy = false;
  int mode = 0, limit = 40, generation = 0;
  String historyRef = 'all';
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final request = ++generation;
    try {
      final status = await widget.scope.read(SessionResource.gitStatus);
      Json? data;
      if (mode == 1) {
        data = await widget.scope.read(SessionResource.gitHistory, {
          'limit': limit,
          'ref': historyRef,
        });
      }
      if (mode == 2) {
        data = await widget.scope.read(SessionResource.gitBranches);
      }
      if (mounted && generation == request) {
        setState(() {
          state = status;
          content = data;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == request) setState(() => error = e);
    }
  }

  Future<void> execute(Json params, {String? explanation}) async {
    if (busy || state == null) return;
    final version = state!['version'];
    if (explanation != null &&
        !await confirmAction(
          context,
          words(context, '确认 Git 操作', 'Confirm Git operation'),
          explanation,
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.scope.write(SessionCommand.git, {
        ...params,
        'version': version,
      });
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await load();
      }
    }
  }

  Future<void> diff(String path, String section, {String? revision}) async {
    try {
      final data = await widget.scope.read(
        revision == null
            ? SessionResource.gitDiff
            : SessionResource.gitHistoryDiff,
        {
          'path': path,
          if (revision == null) 'section': section,
          'revision': ?revision,
        },
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SourcePreviewPage(
            title: '$path.diff',
            text: textValue(
              data['text'] ??
                  data['message'] ??
                  words(
                    context,
                    '此文件不提供文本差异',
                    'Text diff is unavailable for this file',
                  ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> commitDetail(Json commit) async {
    try {
      final data = await widget.scope.read(SessionResource.gitCommit, {
        'revision': commit['id'],
      });
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (dialog) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .75,
          builder: (_, scroll) => ListView(
            controller: scroll,
            children: [
              ListTile(
                title: SelectableText(textValue(data['message'])),
                subtitle: SelectableText(
                  '${data['author']} · ${data['date']}\n${data['id']}',
                ),
              ),
              for (final row in jsonRows(data['entries']))
                ListTile(
                  title: Text(textValue(row['path'])),
                  leading: Text(textValue(row['change'])),
                  onTap: () {
                    Navigator.pop(dialog);
                    diff(
                      textValue(row['path']),
                      '',
                      revision: textValue(data['id']),
                    );
                  },
                ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (state == null) return BusinessLoading(error: error, retry: load);
    final data = state!, entries = jsonRows(data['entries']);
    if (data['available'] == false) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(textValue(data['message'])),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ListTile(
          title: Text(textValue(data['branch'])),
          subtitle: Text('${data['project'] ?? ''}\n${data['upstream'] ?? ''}'),
          trailing: IconButton(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ),
        SegmentedButton<int>(
          segments: [
            ButtonSegment(
              value: 0,
              label: Text(words(context, '变更', 'Changes')),
            ),
            ButtonSegment(
              value: 1,
              label: Text(words(context, '历史', 'History')),
            ),
            ButtonSegment(
              value: 2,
              label: Text(words(context, '分支', 'Branches')),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (values) {
            setState(() {
              mode = values.single;
              content = null;
            });
            load();
          },
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null) SelectableText(businessError(context, error)),
        if (data['operation']?.toString().isNotEmpty == true)
          Text('${words(context, '当前操作', 'Operation')}: ${data['operation']}'),
        if (mode == 0) ...[
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : () => execute({'action': 'stage-all'}),
                child: Text(words(context, '全部暂存', 'Stage all')),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => execute({'action': 'unstage-all'}),
                child: Text(words(context, '取消全部暂存', 'Unstage all')),
              ),
              FilledButton(
                onPressed:
                    busy ||
                        data['scope'] != '.' ||
                        entries.any((e) => e['conflict'] == true)
                    ? null
                    : () async {
                        final files = entries
                            .where(
                              (e) =>
                                  e['index'] != '.' && e['untracked'] != true,
                            )
                            .map((e) => textValue(e['path']))
                            .join('\n');
                        final message = await promptText(
                          context,
                          words(context, '提交说明', 'Commit message'),
                          multiline: true,
                          description:
                              '${words(context, '仅提交以下暂存内容，使用电脑现有 Git 身份、签名及 hooks：', 'Commits these staged files using the computer’s Git identity, signing and hooks:')}\n$files',
                        );
                        if (message?.trim().isNotEmpty == true) {
                          await execute({
                            'action': 'commit',
                            'message': message!.trim(),
                          });
                        }
                      },
                child: Text(words(context, '提交', 'Commit')),
              ),
              if (data['operation'] == 'merge')
                TextButton(
                  onPressed: busy
                      ? null
                      : () => execute(
                          {'action': 'abort-merge'},
                          explanation: words(
                            context,
                            '恢复合并前的状态，本次合并中的冲突处理也会撤销。',
                            'Restore the state before this merge, discarding conflict resolutions made during it.',
                          ),
                        ),
                  child: Text(words(context, '中止合并', 'Abort merge')),
                ),
            ],
          ),
          for (final section in [
            'conflict',
            'unstaged',
            'staged',
            'untracked',
          ]) ...[
            if (entries.any((e) => _inSection(e, section)))
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  words(
                    context,
                    {
                      'conflict': '冲突',
                      'unstaged': '未暂存',
                      'staged': '已暂存',
                      'untracked': '未跟踪',
                    }[section]!,
                    section,
                  ),
                ),
              ),
            for (final row in entries.where((e) => _inSection(e, section)))
              ListTile(
                title: Text(textValue(row['path'])),
                subtitle: row['oldPath'] == null
                    ? null
                    : Text(textValue(row['oldPath'])),
                onTap: () => diff(textValue(row['path']), section),
                trailing: IconButton(
                  onPressed: busy || row['submodule'] == true
                      ? null
                      : () => execute({
                          'action': section == 'staged' ? 'unstage' : 'stage',
                          'path': row['path'],
                        }),
                  tooltip: words(
                    context,
                    section == 'staged' ? '取消暂存' : '暂存',
                    section == 'staged' ? 'Unstage' : 'Stage',
                  ),
                  icon: Icon(section == 'staged' ? Icons.remove : Icons.add),
                ),
              ),
          ],
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                words(context, '当前项目没有未提交的改动', 'Working directory is clean'),
              ),
            ),
        ],
        if (mode == 1) ...[
          DropdownButton<String>(
            value: historyRef,
            items: [
              DropdownMenuItem(
                value: 'all',
                child: Text(words(context, '所有分支与标签', 'All branches and tags')),
              ),
              DropdownMenuItem(
                value: 'current',
                child: Text(words(context, '当前分支', 'Current branch')),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                historyRef = value;
                limit = 40;
                load();
              }
            },
          ),
          for (final commit in jsonRows(content?['commits']))
            ListTile(
              title: Text(textValue(commit['subject'])),
              subtitle: Text(
                '${commit['author']} · ${commit['date']}\n${commit['id']}',
              ),
              onTap: () => commitDetail(commit),
            ),
          if (content?['hasMore'] == true && limit < 1000)
            TextButton(
              onPressed: () {
                limit += 40;
                load();
              },
              child: Text(words(context, '加载更早的提交', 'Load earlier commits')),
            ),
        ],
        if (mode == 2) ...[
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: Text(words(context, '创建并切换分支', 'Create and switch branch')),
            onPressed:
                busy ||
                    data['scope'] != '.' ||
                    textValue(data['operation']).isNotEmpty
                ? null
                : () async {
                    final branch = await promptText(
                      context,
                      words(context, '新分支名称', 'New branch name'),
                      description: words(
                        context,
                        '从当前提交创建并切换分支。',
                        'Create a branch from the current commit and switch to it.',
                      ),
                    );
                    if (branch?.trim().isNotEmpty == true) {
                      await execute({
                        'action': 'create-branch',
                        'branch': branch!.trim(),
                      });
                    }
                  },
          ),
          for (final branch in jsonRows(content?['branches']))
            ListTile(
              title: Text(textValue(branch['name'])),
              subtitle: Text(textValue(branch['upstream'])),
              leading: branch['current'] == true
                  ? const Icon(Icons.check)
                  : const Icon(Icons.call_split),
              trailing: branch['current'] == true
                  ? null
                  : PopupMenuButton<String>(
                      enabled:
                          !busy &&
                          data['scope'] == '.' &&
                          textValue(data['operation']).isEmpty,
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'switch-branch',
                          child: Text(words(context, '切换', 'Switch')),
                        ),
                        PopupMenuItem(
                          value: 'merge',
                          child: Text(
                            words(
                              context,
                              '合并到当前分支',
                              'Merge into current branch',
                            ),
                          ),
                        ),
                      ],
                      onSelected: (action) => execute(
                        {'action': action, 'branch': branch['name']},
                        explanation:
                            '${data['branch']} ← ${branch['name']}\n${words(context, '工作区文件将发生变化；合并可能产生提交或冲突。', 'Working directory files will change; merging may create a commit or conflicts.')}',
                      ),
                    ),
            ),
        ],
      ],
    );
  }

  bool _inSection(Json row, String section) => switch (section) {
    'conflict' => row['conflict'] == true,
    'untracked' => row['untracked'] == true,
    'staged' =>
      row['conflict'] != true &&
          row['untracked'] != true &&
          row['index'] != '.',
    _ =>
      row['conflict'] != true &&
          row['untracked'] != true &&
          row['worktree'] != '.',
  };
}
