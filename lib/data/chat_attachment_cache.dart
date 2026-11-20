import 'package:flutter/foundation.dart';

import 'bridge_types.dart';

typedef AttachmentReadScope = ({
  SessionRef session,
  String account,
  String historyEpoch,
  int generation,
});

typedef _ImageKey = ({
  AttachmentReadScope scope,
  String source,
  String id,
  bool thumbnail,
});

class ChatAttachmentCache {
  ChatAttachmentCache({
    this.maxBytes = 32 * 1024 * 1024,
    this.maxEntries = 64,
    this.maxAge = const Duration(minutes: 5),
    Duration Function()? now,
  }) : _now = now ?? _clock();

  final int maxBytes;
  final int maxEntries;
  final Duration maxAge;
  final Duration Function() _now;
  final _images = <_ImageKey, (AttachmentImageData, Duration)>{};
  final _pending = <_ImageKey, Future<AttachmentImageData>>{};
  int _bytes = 0;

  static Duration Function() _clock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  Future<AttachmentImageData> read(
    AttachmentReadScope scope,
    Attachment attachment, {
    required bool thumbnail,
    required Future<AttachmentImageData> Function(bool thumbnail) fetch,
  }) {
    final useThumbnail =
        thumbnail && attachment.source == 'upload' && attachment.hasThumbnail;
    if (scope.account.isEmpty) return Future.sync(() => fetch(useThumbnail));
    _ImageKey variant(bool thumbnail) => (
      scope: scope,
      source: attachment.source,
      id: attachment.id,
      thumbnail: thumbnail,
    );
    final original = variant(false);
    final key = variant(useThumbnail);
    final cached = _lookup(key) ?? (useThumbnail ? _lookup(original) : null);
    if (cached != null) return SynchronousFuture(cached);
    final running = _pending[key] ?? (useThumbnail ? _pending[original] : null);
    if (running != null) return running;

    late final Future<AttachmentImageData> request;
    request = Future.microtask(() => fetch(useThumbnail))
        .then((image) {
          if (identical(_pending[key], request)) {
            _store(image.isOriginal ? original : key, image);
          }
          return image;
        })
        .whenComplete(() {
          if (identical(_pending[key], request)) _pending.remove(key);
        });
    _pending[key] = request;
    return request;
  }

  AttachmentImageData? _lookup(_ImageKey key) {
    final entry = _images.remove(key);
    if (entry == null) return null;
    if (_now() - entry.$2 >= maxAge) {
      _bytes -= entry.$1.bytes.lengthInBytes;
      return null;
    }
    _images[key] = entry;
    return entry.$1;
  }

  void _store(_ImageKey key, AttachmentImageData image) {
    final size = image.bytes.lengthInBytes;
    if (size == 0 || size > maxBytes || maxEntries <= 0) return;
    _remove(key);
    _images[key] = (image, _now());
    _bytes += size;
    while (_bytes > maxBytes || _images.length > maxEntries) {
      _remove(_images.keys.first);
    }
  }

  void _remove(_ImageKey key) {
    _bytes -= _images.remove(key)?.$1.bytes.lengthInBytes ?? 0;
  }

  void discardOtherScopes(AttachmentReadScope scope) {
    bool mismatched(_ImageKey key) =>
        key.scope.session == scope.session && key.scope != scope;
    for (final key in _images.keys.where(mismatched).toList()) {
      _remove(key);
    }
    _pending.removeWhere((key, _) => mismatched(key));
  }

  void clear() {
    _images.clear();
    _pending.clear();
    _bytes = 0;
  }
}
