import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import 'attachment_preview.dart';
import 'activity_summary.dart';
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
    this.compactActivity = false,
  });
  final ChatMessage message;
  final SessionRef session;
  final BridgeRepository repository;
  final Strings strings;
  final BridgeViewModel? model;
  final bool compactActivity;

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
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
      return Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            '${words(context, '文件变更', 'File changes')} · ${summary['count'] ?? jsonRows(summary['files']).length} '
            '+${summary['added'] ?? 0} −${summary['removed'] ?? 0}',
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
          children: [
            for (final file in jsonRows(summary['files']))
              ListTile(
                dense: true,
                leading: const Icon(Icons.description_outlined, size: 17),
                title: Text(textValue(file['path'])),
                subtitle: Text(
                  '+${file['added'] ?? 0} −${file['removed'] ?? 0}',
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
              ),
              icon: const Icon(Icons.copy, size: 16),
              label: Text(words(context, '复制变更摘要', 'Copy change summary')),
            ),
          ],
        ),
      );
    }

    final activity = !['assistant', 'user', 'error'].contains(message.role);
    if (activity) {
      return Padding(
        padding: EdgeInsets.only(bottom: compactActivity ? 0 : 8),
        child: Theme(
          data: theme.copyWith(
            dividerColor: Colors.transparent,
            listTileTheme: compactActivity
                ? theme.listTileTheme.copyWith(
                    minLeadingWidth: 17,
                    horizontalTitleGap: 8,
                    minVerticalPadding: 4,
                  )
                : theme.listTileTheme,
          ),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            minTileHeight: compactActivity ? 32 : 28,
            visualDensity: const VisualDensity(horizontal: -2, vertical: -4),
            controlAffinity: compactActivity
                ? ListTileControlAffinity.trailing
                : ListTileControlAffinity.leading,
            showTrailingIcon: !compactActivity,
            leading: compactActivity
                ? Icon(
                    workActivityIcon(workActivityKind(message)),
                    size: 17,
                    color: colors.onSurfaceVariant,
                  )
                : null,
            collapsedIconColor: colors.onSurfaceVariant,
            iconColor: colors.onSurfaceVariant,
            title: Text(
              compactActivity
                  ? activityDetailLabel(context, message)
                  : message.title.isEmpty
                  ? strings.t('Tool activity')
                  : message.title,
              maxLines: compactActivity ? 1 : null,
              overflow: compactActivity ? TextOverflow.ellipsis : null,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
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
                  height: 1.65,
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
          right: 0,
        ),
        padding: user
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 11)
            : const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: user ? colors.surfaceContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                user ? strings.t('You') : _assistantLabel(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: user ? 0 : 1.4,
                  color: colors.onSurfaceVariant,
                ),
              ),
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
                      onPressed: () => _copy(context, code[index].group(1)!),
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

  String _assistantLabel() {
    final row = jsonObject(message.metadata);
    final label = [
      textValue(row['model']),
      textValue(row['effort']),
    ].where((v) => v.isNotEmpty).join(' ');
    return [
      session.provider.name.toUpperCase(),
      if (label.isNotEmpty) label,
    ].join(' · ');
  }

  String _messageTime() {
    final value = jsonObject(message.metadata)['timestamp'];
    DateTime? date;
    if (value is num && value.isFinite && value > 0) {
      date = DateTime.fromMillisecondsSinceEpoch(
        (value < 100000000000 ? value * 1000 : value).round(),
      ).toLocal();
    } else if (value is String) {
      date = DateTime.tryParse(value)?.toLocal();
    }
    if (date == null) return '';
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
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
        _MessageCopyButton(
          key: ValueKey((
            session,
            model!.snapshot?.accountIdentity,
            message.id,
          )),
          message: message,
          model: model!,
        ),
        TextButton(
          onPressed: () => messageAction(context, model!, message, 'quote'),
          child: Text(words(context, '引用', 'Quote')),
        ),
        if (_messageTime().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _messageTime(),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
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

class _MessageCopyButton extends StatefulWidget {
  const _MessageCopyButton({
    super.key,
    required this.message,
    required this.model,
  });
  final ChatMessage message;
  final BridgeViewModel model;
  @override
  State<_MessageCopyButton> createState() => _MessageCopyButtonState();
}

class _MessageCopyButtonState extends State<_MessageCopyButton> {
  bool copied = false, copying = false;
  Timer? reset;

  @override
  void dispose() {
    reset?.cancel();
    super.dispose();
  }

  Future<void> copy() async {
    if (copying) return;
    reset?.cancel();
    setState(() {
      copying = true;
      copied = false;
    });
    try {
      await messageAction(
        context,
        widget.model,
        widget.message,
        'copy',
        onCopied: () {
          if (!mounted) return;
          reset?.cancel();
          setState(() => copied = true);
          reset = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => copied = false);
          });
        },
      );
    } finally {
      if (mounted) setState(() => copying = false);
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: copied,
    child: TextButton(
      onPressed: copying ? null : copy,
      child: Text(
        words(context, copied ? '已复制' : '复制', copied ? 'Copied' : 'Copy'),
      ),
    ),
  );
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
