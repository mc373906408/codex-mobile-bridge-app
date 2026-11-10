import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import 'attachment_preview.dart';
import 'business/common.dart';
import 'business/message_content.dart';
import 'business/workspace_page.dart';
import 'business/appearance_settings.dart';

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.message,
    required this.session,
    required this.repository,
    required this.strings,
    this.model,
  });
  final ChatMessage message;
  final SessionRef session;
  final BridgeRepository repository;
  final Strings strings;
  final BridgeViewModel? model;

  void _copy(BuildContext context, String text, {bool fullMessage = true}) {
    if (model != null && fullMessage) {
      messageAction(context, model!, message, 'copy');
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(strings.t('Copied')),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = Theme.of(context).colorScheme;
    final appearance = ChatAppearanceScope.of(context);
    if (!appearance.visible(message.role, jsonObject(message.metadata))) {
      return const SizedBox.shrink();
    }
    final summary = jsonObject(jsonObject(message.metadata)['fileSummary']);
    if (summary.isNotEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${words(context, '文件变更', 'File changes')} · ${summary['count'] ?? jsonRows(summary['files']).length}',
                style: theme.textTheme.titleSmall,
              ),
              Text('+${summary['added'] ?? 0}  −${summary['removed'] ?? 0}'),
              if (summary['basis'] == 'recorded')
                Text(
                  words(context, '累计修改', 'Recorded changes'),
                  style: theme.textTheme.bodySmall,
                ),
              for (final file in jsonRows(summary['files']))
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(textValue(file['path'])),
                  subtitle: Text(
                    '+${file['added'] ?? 0}  −${file['removed'] ?? 0}',
                  ),
                  onTap: model == null
                      ? null
                      : () async {
                          final snapshot = model!.snapshot;
                          if (snapshot == null || snapshot.session != session) {
                            return;
                          }
                          final scope = SessionBusiness(model!, snapshot);
                          try {
                            await Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => WorkspacePage(
                                  scope: scope,
                                  initialFile: textValue(file['path']),
                                ),
                              ),
                            );
                          } finally {
                            scope.dispose();
                          }
                        },
                ),
              TextButton.icon(
                onPressed: () => _copy(
                  context,
                  jsonRows(summary['files'])
                      .map(
                        (r) =>
                            '${r['path']} +${r['added'] ?? 0} −${r['removed'] ?? 0}',
                      )
                      .join('\n'),
                  fullMessage: false,
                ),
                icon: const Icon(Icons.copy),
                label: Text(words(context, '复制变更摘要', 'Copy change summary')),
              ),
            ],
          ),
        ),
      );
    }
    final activity = !['assistant', 'user', 'error'].contains(message.role);
    if (activity) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: colors.surfaceContainerLow,
        child: ExpansionTile(
          leading: Icon(
            CupertinoIcons.chevron_left_slash_chevron_right,
            size: 18,
            color: colors.primary,
          ),
          title: Text(
            message.title.isEmpty ? strings.t('Tool activity') : message.title,
            style: theme.textTheme.labelLarge,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              [
                message.text,
                message.output,
              ].where((value) => value.isNotEmpty).join('\n\n'),
              style: TextStyle(
                fontFamily: appearance.codeFamily,
                fontSize: appearance.codeSize,
                height: 1.5,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () =>
                    _copy(context, '${message.text}\n${message.output}'),
                icon: const Icon(Icons.copy, size: 15),
                label: Text(strings.t('Copy')),
              ),
            ),
            for (final attachment in message.attachments)
              if (attachment.image && appearance.show('showToolImages'))
                GatewayImage(
                  session: session,
                  attachment: attachment,
                  repository: repository,
                  strings: strings,
                ),
            _actions(context),
          ],
        ),
      );
    }
    final user = message.role == 'user';
    final code = RegExp(r'```[^\n]*\n([\s\S]*?)```')
        .allMatches(message.text)
        .toList();
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.only(
          bottom: appearance.messageGap,
          left: user ? 28 : 0,
          right: user ? 0 : 12,
        ),
        padding: user
            ? const EdgeInsets.symmetric(horizontal: 18, vertical: 12)
            : const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: user ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(user ? 18 : 4),
            bottomRight: Radius.circular(user ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  strings.t(user ? 'You' : 'Assistant'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => _copy(context, message.text),
                  tooltip: strings.t('Copy'),
                  icon: const Icon(Icons.content_copy_rounded, size: 16),
                ),
              ],
            ),
            if (user)
              SelectableText(
                message.text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontSize: appearance.fontSize,
                ),
              )
            else
              RichMessageText(
                text: message.text,
                onPrompt: model == null
                    ? null
                    : (prompt) {
                        if (model!.selected == session &&
                            model!.draftEditable) {
                          model!.editDraft(
                            '${model!.draftText}${model!.draftText.isEmpty ? '' : '\n\n'}$prompt',
                          );
                        }
                      },
                onFile: model == null
                    ? null
                    : (path, line) =>
                          openMessageFile(context, model!, session, path, line),
              ),
            if (user && code.isNotEmpty)
              Wrap(
                spacing: 8,
                children: [
                  for (var index = 0; index < code.length; index++)
                    TextButton.icon(
                      onPressed: () => _copy(
                        context,
                        code[index].group(1)!,
                        fullMessage: false,
                      ),
                      icon: const Icon(Icons.code, size: 16),
                      label: Text('${strings.t('Copy code')} ${index + 1}'),
                    ),
                ],
              ),
            for (final attachment in message.attachments)
              if (attachment.image)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: GatewayImage(
                    session: session,
                    attachment: attachment,
                    repository: repository,
                    strings: strings,
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Chip(
                    avatar: const Icon(Icons.attach_file, size: 16),
                    label: Text(attachment.name),
                  ),
                ),
            _actions(context),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    if (model == null) return const SizedBox.shrink();
    final row = jsonObject(message.metadata),
        state = jsonObject(model!.snapshot?.metadata);
    final current = state['session'] is Map
        ? jsonObject(state['session'])
        : state;
    final caps = state['capabilities'] is Map
        ? jsonObject(state['capabilities'])
        : jsonObject(current['capabilities']);
    final canEdit = model!.fresh && !model!.busy;
    final edit =
        row['editable'] == true && session.provider == Provider.codex ||
        row['editMessageId'] != null && caps['editMessage'] == true;
    final fork =
        row['forkable'] == true && session.provider == Provider.codex ||
        row['forkMessageId'] != null && caps['fork'] == true;
    return Wrap(
      spacing: 8,
      children: [
        if (message.truncated)
          TextButton(
            onPressed: () => messageAction(context, model!, message, 'expand'),
            child: Text(words(context, '展开完整内容', 'Read full content')),
          ),
        TextButton(
          onPressed: () => messageAction(context, model!, message, 'quote'),
          child: Text(words(context, '引用', 'Quote')),
        ),
        TextButton(
          onPressed: () =>
              messageAction(context, model!, message, 'select-quote'),
          child: Text(words(context, '选择文字引用', 'Quote selected text')),
        ),
        if (edit)
          TextButton(
            onPressed: canEdit
                ? () => messageAction(
                    context,
                    model!,
                    message,
                    session.provider == Provider.codex &&
                            current['latestUserTurnId'] != row['turnId']
                        ? 'edit-fork'
                        : 'edit',
                  )
                : null,
            child: Text(words(context, '编辑', 'Edit')),
          ),
        if (fork)
          TextButton(
            onPressed: canEdit
                ? () => messageAction(context, model!, message, 'fork')
                : null,
            child: Text(words(context, '从这里分支', 'Fork here')),
          ),
        if (row['review'] != null)
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => DetailTextPage(
                  title: message.title,
                  text: prettyContent(row['review']),
                ),
              ),
            ),
            child: Text(words(context, '变更详情', 'Change details')),
          ),
      ],
    );
  }
}

class GatewayImage extends StatefulWidget {
  const GatewayImage({
    super.key,
    required this.session,
    required this.attachment,
    required this.repository,
    required this.strings,
    this.width,
    this.height = 240,
    this.decodeSize = 1200,
    this.compact = false,
  });
  final SessionRef session;
  final Attachment attachment;
  final BridgeRepository repository;
  final Strings strings;
  final double? width;
  final double height;
  final int decodeSize;
  final bool compact;
  @override
  State<GatewayImage> createState() => _GatewayImageState();
}

class _GatewayImageState extends State<GatewayImage> {
  late Future<Uint8List> _image;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _image = widget.repository.image(widget.session, widget.attachment);
  }

  @override
  void didUpdateWidget(covariant GatewayImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        oldWidget.attachment != widget.attachment ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _image,
    builder: (context, state) {
      if (state.hasError) {
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: Center(
            child: widget.compact
                ? Tooltip(
                    message: widget.strings.t('Image unavailable'),
                    child: const Icon(Icons.broken_image_outlined),
                  )
                : Text(widget.strings.t('Image unavailable')),
          ),
        );
      }
      if (!state.hasData) {
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      return AttachmentImage(
        bytes: state.data!,
        name: widget.attachment.name,
        strings: widget.strings,
        width: widget.width,
        height: widget.height,
        decodeSize: widget.decodeSize,
        compact: widget.compact,
      );
    },
  );
}
