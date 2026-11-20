import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../data/chat_attachment_preparation.dart';
import '../l10n/strings.dart';
import 'attachment_preview.dart' show ImagePreviewAccess;

enum _PhotoTool { draw, text, mosaic }

typedef _Ink = ({Path path, Offset first, bool dot, Color color});
typedef _Label = ({String text, Offset center, Color color, int turns});

class _PhotoEdits {
  const _PhotoEdits({
    this.turns = 0,
    this.ink = const [],
    this.labels = const [],
    this.mosaic = const [],
  });

  final int turns;
  final List<_Ink> ink;
  final List<_Label> labels;
  final List<Rect> mosaic;

  _PhotoEdits copy({
    int? turns,
    List<_Ink>? ink,
    List<_Label>? labels,
    List<Rect>? mosaic,
  }) => _PhotoEdits(
    turns: turns ?? this.turns,
    ink: ink ?? this.ink,
    labels: labels ?? this.labels,
    mosaic: mosaic ?? this.mosaic,
  );
}

class ChatPhotoEditor extends StatefulWidget {
  const ChatPhotoEditor({
    super.key,
    required this.file,
    required this.strings,
    required this.access,
  });

  final LocalChatAttachment file;
  final Strings strings;
  final ImagePreviewAccess access;

  @override
  State<ChatPhotoEditor> createState() => _ChatPhotoEditorState();
}

class _ChatPhotoEditorState extends State<ChatPhotoEditor> {
  final _history = [const _PhotoEdits()];
  int _cursor = 0;
  _PhotoEdits get _edits => _history[_cursor];
  _PhotoTool _tool = _PhotoTool.draw;
  Color _color = const Color(0xffe33135);
  ui.Image? _photo, _blocks;
  Offset? _down, _end;
  Path? _path;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _photo?.dispose();
    _blocks?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    ui.Image? photo;
    try {
      photo = await widget.file.decodeForEditing();
      if (!mounted) return;
      final scale = math.min(1.0, 36 / math.max(photo.width, photo.height));
      final width = math.max(1, (photo.width * scale).round());
      final height = math.max(1, (photo.height * scale).round());
      final recorder = ui.PictureRecorder();
      final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      Canvas(recorder)
        ..drawRect(bounds, Paint()..color = Colors.white)
        ..drawImageRect(
          photo,
          _bounds(photo),
          bounds,
          Paint()..filterQuality = FilterQuality.medium,
        );
      final picture = recorder.endRecording();
      final ui.Image blocks;
      try {
        blocks = await picture.toImage(width, height);
      } finally {
        picture.dispose();
      }
      if (!mounted) {
        blocks.dispose();
        return;
      }
      setState(() {
        _photo = photo;
        _blocks = blocks;
      });
      photo = null;
    } catch (_) {
      if (mounted) setState(() => _error = 'Image unavailable');
    } finally {
      photo?.dispose();
    }
  }

  void _push(_PhotoEdits edits) {
    _history.removeRange(_cursor + 1, _history.length);
    _history.add(edits);
    if (_history.length > 51) _history.removeAt(0);
    _cursor = _history.length - 1;
    _error = null;
  }

  Future<void> _save() async {
    if (!widget.access.allowed() ||
        _saving ||
        _photo == null ||
        _blocks == null) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final photo = _photo!, blocks = _blocks!, edits = _edits;
    final size = _orientedSize(photo, edits.turns);
    final recorder = ui.PictureRecorder();
    _paintPhoto(
      Canvas(recorder),
      size,
      photo,
      blocks,
      edits,
      Directionality.of(context),
    );
    final picture = recorder.endRecording();
    try {
      final frame = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      try {
        final encoded = await encodeChatPhotoFrame(frame);
        if (encoded.length > chatAttachmentMaxBytes) {
          throw StateError('Attachment exceeds 20 MiB');
        }
        if (!mounted) return;
        if (widget.access.allowed() &&
            ModalRoute.of(context)?.isCurrent == true) {
          Navigator.pop(context, encoded);
        }
      } finally {
        frame.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save image edits');
    } finally {
      picture.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addText(Offset point) async {
    final strings = widget.strings;
    var value = '';
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.t('Add image text')),
        content: TextField(
          key: const Key('photo-editor-text'),
          autofocus: true,
          maxLength: 120,
          maxLines: 3,
          onChanged: (text) => value = text,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value.trim()),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    if (!mounted || text == null || text.isEmpty || !widget.access.allowed()) {
      return;
    }
    setState(
      () => _push(
        _edits.copy(
          labels: [
            ..._edits.labels,
            (text: text, center: point, color: _color, turns: _edits.turns),
          ],
        ),
      ),
    );
  }

  Offset _toPhoto(Offset point, double scale) {
    final photo = _photo!;
    final size = _orientedSize(photo, _edits.turns);
    final left = (point.dx / scale).clamp(0.0, size.width);
    final top = (point.dy / scale).clamp(0.0, size.height);
    return switch (_edits.turns) {
      1 => Offset(top, photo.height - left),
      2 => Offset(photo.width - left, photo.height - top),
      3 => Offset(photo.width - top, left),
      _ => Offset(left, top),
    };
  }

  Rect _mosaicRect(Offset start, Offset end) {
    final minimum = _bounds(_photo!).longestSide / 36;
    final rect = Rect.fromPoints(start, end);
    return Rect.fromCenter(
      center: rect.center,
      width: math.max(rect.width, minimum),
      height: math.max(rect.height, minimum),
    ).intersect(_bounds(_photo!));
  }

  _PhotoEdits _gestureEdits() {
    final start = _down, end = _end;
    if (start == null || end == null) return _edits;
    if (_tool == _PhotoTool.mosaic) {
      return _edits.copy(mosaic: [..._edits.mosaic, _mosaicRect(start, end)]);
    }
    if (_tool == _PhotoTool.text) {
      if (_edits.labels.isEmpty) return _edits;
      final label = _edits.labels.last;
      final offset = label.center + end - start;
      final bounds = _bounds(_photo!);
      return _edits.copy(
        labels: [
          ..._edits.labels.take(_edits.labels.length - 1),
          (
            text: label.text,
            center: Offset(
              offset.dx.clamp(0.0, bounds.width),
              offset.dy.clamp(0.0, bounds.height),
            ),
            color: label.color,
            turns: label.turns,
          ),
        ],
      );
    }
    final path = _path;
    return _edits.copy(
      ink: [
        ..._edits.ink,
        (
          path: path == null ? Path() : Path.from(path),
          first: start,
          dot: path == null,
          color: _color,
        ),
      ],
    );
  }

  void _finishGesture({bool commit = false}) {
    setState(() {
      if (commit && _end != null) _push(_gestureEdits());
      _down = _end = null;
      _path = null;
    });
  }

  Widget _canvas(ui.Image photo, ui.Image blocks) => LayoutBuilder(
    builder: (context, constraints) {
      final size = _orientedSize(photo, _edits.turns);
      final scale = math.min(
        constraints.maxWidth / size.width,
        constraints.maxHeight / size.height,
      );
      if (scale <= 0) return const SizedBox.shrink();
      return Center(
        child: SizedBox.fromSize(
          size: size * scale,
          child: GestureDetector(
            key: const Key('photo-editor-canvas'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onTapUp: (details) {
              final point = _toPhoto(details.localPosition, scale);
              if (_tool == _PhotoTool.text) {
                _addText(point);
              } else {
                _down = _end = point;
                _finishGesture(commit: true);
              }
            },
            onPanDown: (details) {
              _down = _toPhoto(details.localPosition, scale);
            },
            onPanUpdate: (details) {
              final point = _toPhoto(details.localPosition, scale);
              setState(() {
                final start = _down ??= point;
                _end = point;
                if (_tool == _PhotoTool.draw) {
                  (_path ??= Path()..moveTo(start.dx, start.dy)).lineTo(
                    point.dx,
                    point.dy,
                  );
                }
              });
            },
            onPanEnd: (_) => _finishGesture(
              commit: _tool != _PhotoTool.text || _edits.labels.isNotEmpty,
            ),
            onPanCancel: () => _finishGesture(),
            child: CustomPaint(
              painter: _PhotoPainter(
                photo,
                blocks,
                _gestureEdits(),
                Directionality.of(context),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _tools(ColorScheme colors) {
    final strings = widget.strings;
    const palette = {
      'Red': Color(0xffe33135),
      'Yellow': Color(0xffffca29),
      'Blue': Color(0xff2869eb),
      'White': Colors.white,
      'Black': Colors.black,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SegmentedButton<_PhotoTool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: _PhotoTool.draw,
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: strings.t('Draw on image'),
                ),
                ButtonSegment(
                  value: _PhotoTool.text,
                  icon: const Icon(Icons.title),
                  tooltip: strings.t('Add image text'),
                ),
                ButtonSegment(
                  value: _PhotoTool.mosaic,
                  icon: const Icon(Icons.grid_on),
                  tooltip: strings.t('Mosaic'),
                ),
              ],
              selected: {_tool},
              onSelectionChanged: (selection) {
                setState(() => _tool = selection.single);
                if (_tool == _PhotoTool.text && _edits.labels.isEmpty) {
                  _addText(_bounds(_photo!).center);
                }
              },
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: strings.t('Rotate clockwise'),
              onPressed: () => setState(
                () => _push(_edits.copy(turns: (_edits.turns + 1) % 4)),
              ),
              icon: const Icon(Icons.rotate_right),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final swatch in palette.entries)
              IconButton(
                tooltip: strings.t(swatch.key),
                isSelected: _color == swatch.value,
                onPressed: _tool == _PhotoTool.mosaic
                    ? null
                    : () => setState(() => _color = swatch.value),
                icon: Container(
                  width: 23,
                  height: 23,
                  decoration: BoxDecoration(
                    color: swatch.value,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _color == swatch.value
                          ? colors.primary
                          : colors.outline,
                      width: _color == swatch.value ? 2 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.access.changes,
    builder: (context, _) {
      final strings = widget.strings, colors = Theme.of(context).colorScheme;
      final photo = _photo, blocks = _blocks;
      final allowed = widget.access.allowed();
      final enabled = allowed && !_saving && photo != null && blocks != null;
      final error = _error;
      return Scaffold(
        key: const Key('photo-editor'),
        appBar: AppBar(
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
          title: Text(
            allowed ? widget.file.name : '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: strings.t('Undo'),
              onPressed: enabled && _cursor > 0
                  ? () => setState(() => --_cursor)
                  : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: strings.t('Redo'),
              onPressed: enabled && _cursor + 1 < _history.length
                  ? () => setState(() => ++_cursor)
                  : null,
              icon: const Icon(Icons.redo),
            ),
            IconButton(
              tooltip: strings.t('Save image edits'),
              onPressed: enabled && !identical(_edits, const _PhotoEdits())
                  ? _save
                  : null,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (_saving) const LinearProgressIndicator(),
              if (allowed && error != null && photo != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    strings.t(error),
                    style: TextStyle(color: colors.error),
                  ),
                ),
              Expanded(
                child: !allowed || error != null && photo == null
                    ? Center(child: Text(strings.t('Image unavailable')))
                    : photo == null || blocks == null
                    ? const Center(child: CircularProgressIndicator())
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: IgnorePointer(
                          ignoring: _saving,
                          child: _canvas(photo, blocks),
                        ),
                      ),
              ),
              if (allowed && photo != null)
                IgnorePointer(ignoring: _saving, child: _tools(colors)),
            ],
          ),
        ),
      );
    },
  );
}

Rect _bounds(ui.Image photo) =>
    Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble());

Size _orientedSize(ui.Image photo, int turns) => turns.isEven
    ? _bounds(photo).size
    : Size(photo.height.toDouble(), photo.width.toDouble());

void _paintPhoto(
  Canvas canvas,
  Size size,
  ui.Image photo,
  ui.Image blocks,
  _PhotoEdits edits,
  TextDirection direction,
) {
  final bounds = _bounds(photo);
  final oriented = _orientedSize(photo, edits.turns);
  canvas.save();
  canvas.clipRect(Offset.zero & size);
  canvas.scale(size.width / oriented.width, size.height / oriented.height);
  switch (edits.turns) {
    case 1:
      canvas.translate(bounds.height, 0);
    case 2:
      canvas.translate(bounds.width, bounds.height);
    case 3:
      canvas.translate(0, bounds.width);
  }
  canvas.rotate(edits.turns * math.pi / 2);
  canvas.drawRect(bounds, Paint()..color = Colors.white);
  canvas.drawImage(
    photo,
    Offset.zero,
    Paint()..filterQuality = FilterQuality.medium,
  );
  if (edits.mosaic.isNotEmpty) {
    canvas.save();
    final mask = Path();
    for (final region in edits.mosaic) {
      mask.addRect(region);
    }
    canvas.clipPath(mask, doAntiAlias: false);
    canvas.drawImageRect(
      blocks,
      _bounds(blocks),
      bounds,
      Paint()..filterQuality = FilterQuality.none,
    );
    canvas.restore();
  }
  for (final stroke in edits.ink) {
    final width = bounds.longestSide * .012;
    final paint = Paint()..color = stroke.color;
    if (stroke.dot) {
      canvas.drawCircle(stroke.first, width / 2, paint);
    } else {
      canvas.drawPath(
        stroke.path,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }
  for (final label in edits.labels) {
    canvas.save();
    canvas.translate(label.center.dx, label.center.dy);
    canvas.rotate(-label.turns * math.pi / 2);
    final text = TextPainter(
      text: TextSpan(
        text: label.text,
        style: TextStyle(
          color: label.color,
          fontSize: bounds.longestSide * .065,
          fontWeight: FontWeight.w700,
          shadows: [
            Shadow(
              color: label.color == Colors.black ? Colors.white : Colors.black,
              blurRadius: bounds.longestSide * .012,
            ),
          ],
        ),
      ),
      textDirection: direction,
      textAlign: TextAlign.center,
      maxLines: 3,
      ellipsis: '…',
    )..layout(maxWidth: _orientedSize(photo, label.turns).width * .9);
    text.paint(canvas, Offset(-text.width / 2, -text.height / 2));
    text.dispose();
    canvas.restore();
  }
  canvas.restore();
}

class _PhotoPainter extends CustomPainter {
  const _PhotoPainter(this.photo, this.blocks, this.edits, this.direction);
  final ui.Image photo, blocks;
  final _PhotoEdits edits;
  final TextDirection direction;

  @override
  void paint(Canvas canvas, Size size) =>
      _paintPhoto(canvas, size, photo, blocks, edits, direction);

  @override
  bool shouldRepaint(_PhotoPainter old) =>
      old.photo != photo || old.edits != edits || old.direction != direction;
}
