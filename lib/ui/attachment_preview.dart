import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';

class AttachmentImage extends StatelessWidget {
  const AttachmentImage({
    super.key,
    required this.bytes,
    required this.name,
    required this.strings,
    this.width,
    this.height = 240,
    this.decodeSize = 1200,
    this.compact = false,
  });

  final Uint8List bytes;
  final String name;
  final Strings strings;
  final double? width;
  final double height;
  final int decodeSize;
  final bool compact;

  Widget _image({required int size, bool thumbnail = false}) => Image(
    image: ResizeImage(
      MemoryImage(bytes),
      width: size,
      height: size,
      policy: ResizeImagePolicy.fit,
    ),
    width: thumbnail ? width : null,
    height: thumbnail ? height : null,
    fit: BoxFit.contain,
    semanticLabel: name,
    errorBuilder: (_, _, _) => Center(
      child: thumbnail && compact
          ? Tooltip(
              message: strings.t('Image unavailable'),
              child: const Icon(Icons.broken_image_outlined),
            )
          : Text(strings.t('Image unavailable')),
    ),
  );

  void _open(BuildContext context) {
    showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (context) => Dialog.fullscreen(
        key: const Key('image-preview-dialog'),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: SizedBox.expand(child: _image(size: 2400)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: strings.t('Preview image'),
    child: Semantics(
      button: true,
      label: '${strings.t('Preview image')}: $name',
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: _image(size: decodeSize, thumbnail: true),
        ),
      ),
    ),
  );
}

class ComposerAttachment extends StatelessWidget {
  const ComposerAttachment({
    super.key,
    required this.name,
    required this.strings,
    required this.preview,
    this.onRemove,
    this.adding = false,
  });

  final String name;
  final Strings strings;
  final Widget preview;
  final VoidCallback? onRemove;
  final bool adding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: 104,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Material(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    child: preview,
                  ),
                  if (onRemove != null)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        tooltip: '${strings.t('Remove attachment')}: $name',
                        onPressed: onRemove,
                        icon: const Icon(Icons.close, size: 16),
                        style: IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.surface.withValues(
                            alpha: .92,
                          ),
                          minimumSize: const Size(32, 32),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  if (adding)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        semanticsLabel: strings.t('Adding attachment...'),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Tooltip(
              message: name,
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
