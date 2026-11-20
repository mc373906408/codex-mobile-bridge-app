import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class ChatTranscript extends StatefulWidget {
  const ChatTranscript({
    super.key,
    required this.rowKeys,
    required this.rowBuilder,
    required this.oldest,
    this.onOlderEdge,
    this.newest,
  });

  final List<Key> rowKeys;
  final IndexedWidgetBuilder rowBuilder;
  final Widget oldest;
  final VoidCallback? onOlderEdge;
  final Widget? newest;

  @override
  State<ChatTranscript> createState() => _ChatTranscriptState();
}

class _ChatTranscriptState extends State<ChatTranscript> {
  static const _olderEdgeDistance = 96.0;
  final _historyCenter = GlobalKey();
  late final _scroll = _ChatScrollController(() {
    final sliver = _historyCenter.currentContext?.findRenderObject();
    return sliver is RenderSliver ? sliver.geometry?.scrollExtent : null;
  });
  Key? _liveBoundary;
  bool _requestedOlder = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) _requestedOlder = false;
    final delta = switch (notification) {
      ScrollUpdateNotification(:final scrollDelta) => scrollDelta ?? 0,
      OverscrollNotification(:final overscroll) => overscroll,
      _ => 0,
    };
    if (delta > 0 &&
        !_requestedOlder &&
        widget.onOlderEdge != null &&
        _scroll.hasClients &&
        _scroll.position.userScrollDirection == ScrollDirection.reverse &&
        notification.metrics.extentAfter <= _olderEdgeDistance) {
      _requestedOlder = true;
      scheduleMicrotask(() {
        if (mounted) widget.onOlderEdge?.call();
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.rowKeys;
    var boundary = _liveBoundary == null ? -1 : keys.indexOf(_liveBoundary!);
    if (boundary < 0) {
      _liveBoundary = keys.lastOrNull;
      boundary = keys.isEmpty ? 0 : keys.length - 1;
    }
    final liveCount = keys.length - boundary;
    final insets = MediaQuery.paddingOf(context);
    return SelectionArea(
      key: ValueKey(_liveBoundary),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: CustomScrollView(
          key: const Key('chat-transcript'),
          reverse: true,
          center: _historyCenter,
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, insets.bottom + 16),
              sliver: SliverList.builder(
                itemCount: liveCount + (widget.newest == null ? 0 : 1),
                itemBuilder: (context, index) => index == liveCount
                    ? widget.newest!
                    : widget.rowBuilder(context, boundary + index),
              ),
            ),
            SliverPadding(
              key: _historyCenter,
              padding: EdgeInsets.fromLTRB(20, insets.top + 12, 20, 0),
              sliver: SliverList.builder(
                itemCount: boundary + 1,
                itemBuilder: (context, index) => index == boundary
                    ? widget.oldest
                    : widget.rowBuilder(context, boundary - 1 - index),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatScrollController extends ScrollController {
  _ChatScrollController(this.historyExtent) : super(keepScrollOffset: false);

  final double? Function() historyExtent;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ChatScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    historyExtent: historyExtent,
  );
}

class _ChatScrollPosition extends ScrollPositionWithSingleContext {
  _ChatScrollPosition({
    required super.physics,
    required super.context,
    required this.historyExtent,
    super.oldPosition,
  }) : super(keepScrollOffset: false);

  final double? Function() historyExtent;
  double _previousBottom = 0;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final wasAtBottom =
        (pixels - _previousBottom).abs() < .5 && !isScrollingNotifier.value;
    final follow = wasAtBottom && _previousBottom != minScrollExtent;
    _previousBottom = minScrollExtent;
    if (follow) correctPixels(minScrollExtent);
    final history = maxScrollExtent == 0 ? historyExtent() : null;
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      history == null
          ? maxScrollExtent
          : math.max(minScrollExtent, math.min(0, history - viewportDimension)),
    );
    return accepted && !follow;
  }
}
