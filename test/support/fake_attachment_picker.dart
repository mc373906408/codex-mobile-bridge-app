import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

final syntheticImage = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1j'
  'AAAAEUlEQVR4nGMQz0n4j4wZ0AUA9YIPEc7wKswAAAAASUVORK5CYII=',
);

final class MemoryPickedFile extends PlatformFile {
  MemoryPickedFile({
    this.name = 'synthetic-photo.png',
    Uint8List? bytes,
    this.reportedLength,
    this.chunks,
  }) : bytes = bytes ?? syntheticImage;

  @override
  final String name;
  final Uint8List bytes;
  final int? reportedLength;
  final List<Uint8List>? chunks;
  int reads = 0;

  @override
  Uri get uri => Uri.parse('content://synthetic-picker/selection');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => reportedLength;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() {
    reads++;
    return Stream.fromIterable(chunks ?? [bytes]);
  }
}

class FakeAttachmentPicker extends FilePickerPlatform {
  final List<FileType> types = [];
  Future<PlatformFile?> Function()? onPick;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    types.add(type);
    return onPick == null ? MemoryPickedFile() : onPick!();
  }
}
