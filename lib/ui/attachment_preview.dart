import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';

typedef ImagePreviewAccess = ({Listenable changes, bool Function() allowed});

ResizeImage _resized(Uint8List bytes, int size) => ResizeImage(
  MemoryImage(bytes),
  width: size,
  height: size,
  policy: ResizeImagePolicy.fit,
);

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
    this.loadOriginal,
    this.access,
    this.onEdit,
  });

  final Uint8List bytes;
  final String name;
  final Strings strings;
  final double? width;
  final double height;
  final int decodeSize;
  final bool compact;
  final Future<Uint8List> Function()? loadOriginal;
  final ImagePreviewAccess? access;
  final VoidCallback? onEdit;

  Widget _image(ResizeImage thumbnail) => Image(
    image: thumbnail,
    width: width,
    height: height,
    fit: BoxFit.contain,
    semanticLabel: name,
    errorBuilder: (_, _, _) => Center(
      child: compact
          ? Tooltip(
              message: strings.t('Image unavailable'),
              child: const Icon(Icons.broken_image_outlined),
            )
          : Text(strings.t('Image unavailable')),
    ),
  );

  Future<void> _open(BuildContext context, ResizeImage thumbnail) async {
    if (access?.allowed() == false) return;
    final edit = await showDialog<bool>(
      context: context,
      useSafeArea: false,
      builder: (_) => _AttachmentPreview(
        name: name,
        strings: strings,
        thumbnail: thumbnail,
        loadOriginal: loadOriginal ?? () => Future.value(bytes),
        access: access,
        editable: onEdit != null,
      ),
    );
    if (edit == true && context.mounted && access?.allowed() != false) {
      onEdit?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumbnail = _resized(bytes, decodeSize);
    return Tooltip(
      message: strings.t('Preview image'),
      child: Semantics(
        button: true,
        label: '${strings.t('Preview image')}: $name',
        child: InkWell(
          onTap: () => _open(context, thumbnail),
          borderRadius: BorderRadius.circular(10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: _image(thumbnail),
          ),
        ),
      ),
    );
  }
}

class _AttachmentPreview extends StatefulWidget {
  const _AttachmentPreview({
    required this.name,
    required this.strings,
    required this.thumbnail,
    required this.loadOriginal,
    required this.access,
    required this.editable,
  });

  final String name;
  final Strings strings;
  final ResizeImage thumbnail;
  final Future<Uint8List> Function() loadOriginal;
  final ImagePreviewAccess? access;
  final bool editable;

  @override
  State<_AttachmentPreview> createState() => _AttachmentPreviewState();
}

class _AttachmentPreviewState extends State<_AttachmentPreview> {
  Uint8List? _original;
  bool _upgrading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_upgrade());
    });
  }

  Future<void> _upgrade() async {
    if (_upgrading || widget.access?.allowed() == false) return;
    _upgrading = true;
    if (_failed) setState(() => _failed = false);
    try {
      final original = await widget.loadOriginal();
      if (!mounted || widget.access?.allowed() == false) return;
      setState(() => _original = original);
    } catch (_) {
      if (!mounted || widget.access?.allowed() == false) return;
      setState(() => _failed = true);
    } finally {
      _upgrading = false;
    }
  }

  Widget _image(Uint8List? original) {
    final thumbnail = Image(
      image: widget.thumbnail,
      fit: BoxFit.contain,
      semanticLabel: widget.name,
      errorBuilder: (_, _, _) =>
          Center(child: Text(widget.strings.t('Image unavailable'))),
    );
    if (original == null) return thumbnail;
    return Image(
      image: _resized(original, 2400),
      fit: BoxFit.contain,
      semanticLabel: widget.name,
      frameBuilder: (_, child, frame, sync) =>
          frame == null && !sync ? thumbnail : child,
      errorBuilder: (_, _, _) => thumbnail,
    );
  }

  Widget _dialog(BuildContext context, bool allowed) => Dialog.fullscreen(
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
                    allowed ? widget.name : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (allowed && _failed)
                  IconButton(
                    tooltip: widget.strings.t('Retry'),
                    onPressed: _upgrade,
                    icon: const Icon(Icons.refresh),
                  ),
                if (allowed && widget.editable)
                  IconButton(
                    tooltip: widget.strings.t('Edit image'),
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: allowed
                ? InteractiveViewer(
                    minScale: 1,
                    maxScale: 5,
                    child: SizedBox.expand(child: _image(_original)),
                  )
                : Center(child: Text(widget.strings.t('Image unavailable'))),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final access = widget.access;
    if (access == null) return _dialog(context, true);
    return ListenableBuilder(
      listenable: access.changes,
      builder: (context, _) => _dialog(context, access.allowed()),
    );
  }
}

class ComposerAttachment extends StatelessWidget {
  const ComposerAttachment({
    super.key,
    required this.name,
    required this.strings,
    required this.preview,
    this.onRemove,
    this.progressLabel,
  });

  final String name;
  final Strings strings;
  final Widget preview;
  final VoidCallback? onRemove;
  final String? progressLabel;

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
                          minimumSize: const Size(48, 48),
                        ),
                      ),
                    ),
                  if (progressLabel != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        semanticsLabel: progressLabel,
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
