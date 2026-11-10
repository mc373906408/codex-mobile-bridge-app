import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge_repository.dart';

final _activeDownloads = <String>{};

/// The on-disk cursor advances only after a flushed chunk. A crash can leave
/// extra bytes, which are truncated before resuming with the stored ETag.
Future<File> downloadWorkspace(
  BridgeRepository repository,
  SessionSnapshot snapshot,
  String path,
  bool archive, {
  required bool Function() active,
  required void Function(int received, int total) progress,
  bool restart = false,
}) async {
  final scope = jsonEncode([
    snapshot.session.computerId,
    snapshot.session.provider.name,
    snapshot.session.entry,
    snapshot.session.environment,
    snapshot.session.id,
    snapshot.accountIdentity,
    path,
    archive,
  ]);
  final key = sha256.convert(utf8.encode(scope)).toString();
  if (!_activeDownloads.add(key)) {
    throw StateError('This download is already in progress');
  }
  try {
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/downloads/$key',
    );
    await directory.create(recursive: true);
    final metadata = File('${directory.path}/progress.json');
    final partial = File('${directory.path}/content.part');
    var offset = 0, total = -1;
    var etag = '';
    if (!restart && await metadata.exists() && await partial.exists()) {
      final saved = jsonDecode(await metadata.readAsString()) as Map;
      offset = saved['offset'] as int;
      total = saved['total'] as int;
      etag = saved['etag'] as String;
      if (offset < 0 ||
          offset > total ||
          offset > await partial.length() ||
          offset > 0 && etag.isEmpty) {
        throw StateError(
          'Download checkpoint is invalid; restart this download',
        );
      }
    }
    final file = await partial.open(mode: FileMode.append);
    try {
      await file.truncate(offset);
      await file.setPosition(offset);
      while (total < 0 || offset < total) {
        if (!active()) throw StateError('Download paused');
        final chunk = await repository.downloadChunk(
          snapshot,
          path,
          archive,
          offset,
          etag,
        );
        if (!active()) throw StateError('Download paused');
        if (chunk.offset != offset || total >= 0 && total != chunk.total) {
          throw StateError('File changed; restart this download');
        }
        total = chunk.total;
        etag = chunk.etag;
        await file.writeFrom(chunk.data);
        await file.flush();
        offset += chunk.data.length;
        final next = File('${metadata.path}.next');
        await next.writeAsString(
          jsonEncode({'offset': offset, 'total': total, 'etag': etag}),
          flush: true,
        );
        await next.rename(metadata.path);
        progress(offset, total);
        if (chunk.data.isEmpty && offset < total) {
          throw StateError('Incomplete download');
        }
      }
    } finally {
      await file.close();
    }
    if (!active()) throw StateError('Download paused');
    final name = '${path.split('/').last}${archive ? '.zip' : ''}'.replaceAll(
      RegExp(r'[\\/:*?"<>|\x00-\x1f]'),
      '_',
    );
    final ready = await Directory('${directory.path}/ready')
        .create(recursive: true);
    final output = File(
      '${ready.path}/${DateTime.now().microsecondsSinceEpoch}-${name.isEmpty ? 'download' : name}',
    );
    // Keep the complete checkpoint for safe share-sheet retries without fetching again.
    return await partial.copy(output.path);
  } finally {
    _activeDownloads.remove(key);
  }
}
