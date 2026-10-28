import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import 'attachment_preview.dart';

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.message,
    required this.session,
    required this.repository,
    required this.strings,
  });
  final ChatMessage message;
  final SessionRef session;
  final BridgeRepository repository;
  final Strings strings;

  void _copy(BuildContext context, String text) {
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
    final activity = !['assistant', 'user', 'error'].contains(message.role);
    if (activity) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: colors.surfaceContainerLow,
        child: ExpansionTile(
          leading: Icon(
            Icons.terminal_rounded,
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
              style: const TextStyle(
                fontFamily: 'PlexMono',
                fontSize: 12,
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
            if (message.truncated)
              Text(
                strings.t(
                  'Long content was truncated. Read the full output on the computer.',
                ),
              ),
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
          bottom: 18,
          left: user ? 28 : 0,
          right: user ? 0 : 12,
        ),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: user
              ? colors.primaryContainer.withValues(alpha: .65)
              : colors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(user ? 18 : 4),
            bottomRight: Radius.circular(user ? 4 : 18),
          ),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  strings.t(user ? 'You' : 'Assistant').toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.4,
                    color: colors.primary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => _copy(context, message.text),
                  tooltip: strings.t('Copy'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.content_copy_rounded, size: 16),
                ),
              ],
            ),
            if (user)
              SelectableText(message.text, style: const TextStyle(height: 1.55))
            else
              MarkdownBody(
                data: message.text,
                selectable: true,
                imageBuilder: (uri, title, alt) => Text(
                  '[${strings.t('External image blocked')}: ${alt ?? ''}]',
                  style: theme.textTheme.bodySmall,
                ),
                onTapLink: (text, href, title) {
                  if (href != null) _copy(context, href);
                },
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: theme.textTheme.bodyMedium?.copyWith(height: 1.65),
                  code: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'PlexMono',
                    backgroundColor: colors.surfaceContainerHighest,
                  ),
                  codeblockPadding: const EdgeInsets.all(12),
                  codeblockDecoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            if (code.isNotEmpty)
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
            if (message.truncated)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  strings.t(
                    'Long content was truncated. Read the full output on the computer.',
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
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
