import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';
import 'workspace_page.dart';
import 'session_controls.dart';
import 'message_content.dart';

Future<void> sessionActions(
  BuildContext context,
  BridgeViewModel model,
  SessionRef session, {
  SessionSummary? row,
}) async {
  SessionBusiness? scope;
  try {
    final generation = model.connectionGeneration;
    final snapshot = await model.repository.snapshot(session);
    if (!context.mounted ||
        generation != model.connectionGeneration ||
        !model.foreground) {
      return;
    }
    scope = SessionBusiness(model, snapshot);
    final state = scope.state, caps = scope.capabilities;
    final pinned = state['pinned'] as bool? ?? row?.pinned ?? false;
    final archived =
        state['archived'] as bool? ??
        jsonObject(row?.metadata)['archived'] as bool? ??
        model.archived;
    final action = await chooseValue(context, snapshot.title, <String, String>{
      'workspace': words(context, '文件、Git 与终端', 'Files, Git & terminal'),
      'controls': words(context, '任务与聊天设置', 'Task & chat settings'),
      if (caps['rename'] != false) 'rename': words(context, '修改名称', 'Rename'),
      if (caps['pin'] != false)
        'pin': words(context, pinned ? '取消置顶' : '置顶', pinned ? 'Unpin' : 'Pin'),
      if (caps['organization'] != false)
        'organization': words(context, '项目与分区', 'Project & section'),
      if (caps['fork'] != false) 'fork': words(context, '创建聊天分支', 'Fork chat'),
      'copy': words(context, '复制会话 ID', 'Copy session ID'),
      'read': words(
        context,
        model.isSessionRead(session) ? '标记为未读' : '标记为已读',
        model.isSessionRead(session) ? 'Mark unread' : 'Mark read',
      ),
      if (caps['archive'] != false)
        'archive': words(
          context,
          archived ? '恢复聊天' : '归档聊天',
          archived ? 'Restore chat' : 'Archive chat',
        ),
      if (session.provider == Provider.codex && caps['delete'] != false)
        'delete': words(context, '永久删除…', 'Delete permanently…'),
    });
    if (action == null || !context.mounted) return;
    scope.check();
    switch (action) {
      case 'workspace':
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => WorkspacePage(scope: scope!)),
        );
      case 'controls':
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SessionControlsPage(scope: scope!),
          ),
        );
      case 'rename':
        final title = await promptText(
          context,
          words(context, '聊天名称', 'Chat title'),
          initial: snapshot.title,
        );
        if (title?.trim().isNotEmpty == true) {
          await scope.write(SessionCommand.rename, {'title': title!.trim()});
        }
      case 'pin':
        await scope.write(SessionCommand.pin, {'pinned': !pinned});
      case 'copy':
        await Clipboard.setData(ClipboardData(text: session.id));
      case 'read':
        model.markSessionRead(session, !model.isSessionRead(session));
      case 'archive':
        final restore = archived;
        if (restore ||
            await confirmAction(
              context,
              words(context, '停止任务并归档？', 'Stop tasks and archive?'),
              words(
                context,
                '将停止此聊天及子任务，保留聊天记录。未完成任务需要手动继续。',
                'Stops this chat and its child tasks while keeping history. Unfinished tasks must be resumed manually.',
              ),
            )) {
          await scope.write(SessionCommand.archive, {
            'archived': !restore,
            if (!restore) 'disconnect': true,
          });
          if (model.selected == session) await model.backToSessions();
        }
      case 'delete':
        final preview = await scope.read(SessionResource.deletePreview);
        if (!context.mounted) return;
        final retry = preview['retry'];
        final explanation = [
          words(
            context,
            '以下聊天及其子任务将永久删除，无法撤销：',
            'Permanently deletes these chats and their child tasks:',
          ),
          ...jsonRows(preview['sessions']).map((e) => textValue(e['title'])),
          if (preview['subagentCount'] != null)
            '${words(context, '子任务', 'Child tasks')}: ${preview['subagentCount']}',
          if (retry is List && retry.isNotEmpty)
            words(
              context,
              '此前删除结果未确认。请先在原客户端核对，再确认重新删除仍存在的聊天。',
              'A previous deletion is unconfirmed. Verify in the original client before deleting the remaining chats again.',
            ),
        ].join('\n\n');
        if (await confirmAction(
          context,
          words(context, '永久删除聊天？', 'Delete chat permanently?'),
          explanation,
          danger: true,
        )) {
          await scope.write(SessionCommand.delete, {
            'scope': preview['scope'],
            'confirmed': true,
            if (retry is List && retry.isNotEmpty) 'retry': retry,
          });
          if (model.selected == session) await model.backToSessions();
        }
      case 'organization':
        final organization = await scope.read(SessionResource.organization);
        if (!context.mounted) return;
        final kind = await chooseValue(
          context,
          words(context, '原生归属', 'Organization'),
          {
            'project': words(context, '项目', 'Project'),
            'section': words(context, '分区', 'Section'),
          },
        );
        if (kind == null || !context.mounted) return;
        final choices = jsonRows(
          organization[kind == 'project' ? 'projects' : 'sections'],
        );
        final local =
            (organization['${kind}Scope'] ?? organization['scope']) == 'bridge';
        final target = await chooseValue(
          context,
          local
              ? words(context, 'Bridge 分类', 'Bridge organization')
              : words(context, '选择原生归属', 'Choose native destination'),
          <String, String>{
            '': words(context, '移出', 'Remove membership'),
            for (final item in choices)
              textValue(item['id']): textValue(item['title'] ?? item['name']),
            if (local)
              '\u0000create': words(context, '创建分类…', 'Create category…'),
          },
        );
        if (target == '\u0000create' && context.mounted) {
          final title = await promptText(
            context,
            kind == 'project'
                ? words(context, '新项目名称', 'New project name')
                : words(context, '新分区名称', 'New section name'),
          );
          if (title != null &&
              title.trim().isNotEmpty &&
              title.trim().length <= 120) {
            await scope.write(SessionCommand.organization, {
              'id': model.repository.newId(),
              'kind': 'create-$kind',
              'title': title.trim(),
            });
          }
          break;
        }
        if (target != null) {
          await scope.write(SessionCommand.organization, {
            'id': model.repository.newId(),
            'kind': kind,
            'targetId': target.isEmpty ? null : target,
            'expectedId': organization['${kind}Id'],
          });
        }
      case 'fork':
        await model.openSession(session);
        if (!context.mounted) return;
        final messages = model.messages.where((row) {
          final raw = jsonObject(row.metadata);
          return raw['forkable'] == true || raw['forkMessageId'] != null;
        }).toList();
        if (messages.isEmpty) {
          throw StateError(
            words(context, '此聊天没有可分支的消息', 'No forkable message is available'),
          );
        }
        await messageAction(context, model, messages.last, 'fork');
    }
    await model.refreshSessions();
  } catch (error) {
    if (context.mounted) showFailure(context, error);
  } finally {
    scope?.dispose();
  }
}
