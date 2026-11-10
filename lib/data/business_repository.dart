import 'dart:typed_data';

import 'bridge_types.dart';

/// Domain operations stay closed at the FFI boundary; no caller-selected URLs.
abstract class BusinessRepository {
  Future<OperationOutcome> createWithOptions(
    Computer computer,
    ProjectOption project,
    String title,
    String text,
    String id,
    Map<String, Object?> options,
  ) => throw UnsupportedError('Creation options unavailable');
  Future<BusinessReply> uploadWorkspace(
    SessionSnapshot snapshot,
    String id,
    String path,
    Uint8List bytes,
  ) => throw UnsupportedError('Uploads unavailable');
  Future<String> sessionResource(
    SessionRef session,
    SessionResource resource,
    Map<String, Object?> parameters,
  ) => throw UnsupportedError('Business resources unavailable');
  Future<BusinessReply> sessionCommand(
    SessionSnapshot snapshot,
    String id,
    SessionCommand command,
    Map<String, Object?> parameters,
  ) => throw UnsupportedError('Business operations unavailable');
  Future<GatewayState> gatewayResource(
    Computer computer,
    Provider provider,
    String entry,
    GatewayResource resource,
    Map<String, Object?> parameters,
  ) => throw UnsupportedError('Management unavailable');
  Future<BusinessReply> gatewayCommand(
    Computer computer,
    Provider provider,
    String entry,
    String identity,
    String id,
    GatewayCommand command,
    Map<String, Object?> parameters,
  ) => throw UnsupportedError('Management unavailable');
  Future<DownloadChunk> downloadChunk(
    SessionSnapshot snapshot,
    String path,
    bool archive,
    int offset,
    String etag,
  ) => throw UnsupportedError('Downloads unavailable');
}
