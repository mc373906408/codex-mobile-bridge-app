import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as raster;

const chatAttachmentMaxBytes = 20 * 1024 * 1024;
const _photoEdge = 2560;
const _photoChannel = MethodChannel('dev.waken.bridge_mobile/chat_photos');

typedef ChatAttachmentPayload = ({String name, Uint8List bytes});
typedef ChatPhotoEncoder = Future<Uint8List> Function(Uint8List);

bool _jpeg(Uint8List bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xff &&
    bytes[1] == 0xd8 &&
    bytes[2] == 0xff;

String _extension(String name) => name.split('.').last.toLowerCase();

bool isChatImage(String name) => const {
  'avif',
  'bmp',
  'gif',
  'heic',
  'heif',
  'jpg',
  'jpeg',
  'png',
  'tif',
  'tiff',
  'webp',
}.contains(_extension(name));

bool get _usesImageIO => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

Future<Uint8List?> _imageIoJpeg(Uint8List bytes, int maxEdge) async {
  try {
    return await _photoChannel.invokeMethod<Uint8List>('jpeg', {
      'bytes': bytes,
      'maxEdge': maxEdge,
    });
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

Future<Uint8List> encodeChatPhoto(Uint8List bytes) async {
  if (_usesImageIO) {
    final encoded = await _imageIoJpeg(bytes, _photoEdge);
    if (encoded != null) return encoded;
  }
  final image = await decodeChatPhoto(bytes);
  try {
    return await encodeChatPhotoFrame(image);
  } finally {
    image.dispose();
  }
}

Future<ui.Image> decodeChatPhoto(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (width, height) => width >= height
        ? ui.TargetImageSize(width: width.clamp(1, _photoEdge))
        : ui.TargetImageSize(height: height.clamp(1, _photoEdge)),
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<Uint8List> encodeChatPhotoFrame(ui.Image image) async {
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (rgba == null) throw StateError('Image unavailable');
  return compute(_encodeRgba, (rgba, image.width, image.height));
}

Uint8List _encodeRgba((ByteData, int, int) data) {
  final (rgba, width, height) = data;
  final bytes = rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
  for (var pixel = 0; pixel < bytes.length; pixel += 4) {
    final white = 255 - bytes[pixel + 3];
    bytes[pixel] += white;
    bytes[pixel + 1] += white;
    bytes[pixel + 2] += white;
    bytes[pixel + 3] = 255;
  }
  return raster.encodeJpg(
    raster.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      bytesOffset: bytes.offsetInBytes,
      numChannels: 4,
    ),
    quality: 88,
  );
}

class LocalChatAttachment {
  LocalChatAttachment({
    required this.name,
    required this.bytes,
    required this.image,
  });

  final String name;
  final Uint8List bytes;
  final bool image;
  String get jpegName {
    final dot = name.lastIndexOf('.');
    return '${dot > 0 ? name.substring(0, dot) : name}.jpg';
  }

  bool get hasNativeThumbnail =>
      image &&
      _usesImageIO &&
      const {'heic', 'heif'}.contains(_extension(name));
  late final Future<Uint8List?> nativeThumbnail = _imageIoJpeg(bytes, 320);
  late final Future<ChatAttachmentPayload?> prepared;

  Future<ui.Image> decodeForEditing() async {
    if (!hasNativeThumbnail) {
      try {
        return await decodeChatPhoto(bytes);
      } catch (_) {}
    }
    final jpeg = (await prepared)?.bytes;
    if (jpeg == null) throw StateError('Image unavailable');
    return decodeChatPhoto(jpeg);
  }

  Future<ChatAttachmentPayload?> prepare(ChatPhotoEncoder encoder) async {
    if (!image) return (name: name, bytes: bytes);
    try {
      if (hasNativeThumbnail) await nativeThumbnail;
      final jpeg = _jpeg(bytes) ? bytes : await encoder(bytes);
      if (!_jpeg(jpeg) || jpeg.length > chatAttachmentMaxBytes) return null;
      return (name: jpegName, bytes: jpeg);
    } catch (_) {
      return null;
    }
  }
}
