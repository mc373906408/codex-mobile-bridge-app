import 'dart:typed_data';

import 'package:bridge_mobile/data/chat_attachment_preparation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

import 'support/fake_attachment_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a non-JPEG photo is resized, flattened on white and encoded as JPG',
    () async {
      final transparent = raster.Image(width: 2601, height: 4, numChannels: 4);
      final file = LocalChatAttachment(
        name: 'Screenshot.PNG',
        bytes: raster.encodePng(transparent),
        image: true,
      );
      final payload = await file.prepare(encodeChatPhoto);
      expect(payload?.name, 'Screenshot.jpg');
      final image = raster.decodeJpg(payload!.bytes)!;
      expect(image.width, 2560);
      expect(image.getPixel(0, 0).r, 255);
      expect(image.getPixel(0, 0).g, 255);
      expect(image.getPixel(0, 0).b, 255);
    },
  );

  test(
    'an existing JPEG keeps its exact bytes and gets the .jpg suffix',
    () async {
      final file = LocalChatAttachment(
        name: 'album.photo.JPEG',
        bytes: syntheticJpeg,
        image: true,
      );
      final payload = await file.prepare(
        (_) => throw StateError('Already JPEG'),
      );
      expect(payload?.name, 'album.photo.jpg');
      expect(payload?.bytes, same(syntheticJpeg));
    },
  );

  test('invalid photo data produces no upload payload', () async {
    final file = LocalChatAttachment(
      name: 'broken.png',
      bytes: Uint8List(12),
      image: true,
    );
    expect(await file.prepare(encodeChatPhoto), isNull);
  });
}
