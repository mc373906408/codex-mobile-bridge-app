import 'dart:convert';
import 'dart:io';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/chat_attachment_preparation.dart';
import 'package:bridge_mobile/ui/attachment_preview.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;
import 'package:integration_test/integration_test.dart';

import '../test/support/fake_attachment_picker.dart';
import '../test/support/fake_repository.dart';

final _heic = base64Decode(
  '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',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS shows a local HEIC thumbnail and uploads real JPG only on Send',
    (tester) async {
      final originalPicker = FilePickerPlatform.instance;
      final picker = FakeAttachmentPicker()
        ..onPick = () async =>
            MemoryPickedFile(name: 'IMG_0111.heic', bytes: _heic);
      FilePickerPlatform.instance = picker;
      final repository = FakeRepository()
        ..onUpload = (_, name, bytes) async {
          expect(name, 'IMG_0111.jpg');
          final image = raster.decodeJpg(bytes)!;
          expect((image.width, image.height), (16, 16));
          return Attachment(
            id: 'heic-upload',
            name: name,
            image: true,
            source: 'upload',
          );
        };
      final model = BridgeViewModel(repository);
      addTearDown(() {
        model.dispose();
        FilePickerPlatform.instance = originalPicker;
      });

      await model.initialize();
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add attachment'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick-photo')));
      await tester.pumpAndSettle();

      expect(repository.uploads, 0);
      expect(repository.imageReads, 0);
      final thumbnail = tester.widget<AttachmentImage>(
        find.byType(AttachmentImage),
      );
      expect(raster.decodeJpg(thumbnail.bytes)?.width, 16);
      expect(find.byTooltip('Image unavailable'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Send ↑'));
      await tester.pumpAndSettle();
      expect(repository.uploads, 1);
      expect(repository.sends, 1);
      expect(repository.sentAttachments, ['heic-upload']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'native canvas saves rotated, annotated and pixelated JPG only on Send',
    (tester) async {
      final source = raster.Image(width: 180, height: 100);
      for (final pixel in source) {
        final value = pixel.x >= 90
            ? 205
            : pixel.x.isEven
            ? 0
            : 255;
        pixel.setRgb(value, value, value);
      }
      raster.Image? uploaded;
      final repository = FakeRepository()
        ..onUpload = (_, name, bytes) async {
          expect(name, 'markup.jpg');
          uploaded = raster.decodeJpg(bytes);
          return Attachment(
            id: 'edited-upload',
            name: name,
            image: true,
            source: 'upload',
          );
        };
      final model = BridgeViewModel(repository);
      addTearDown(model.dispose);
      await model.initialize();
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      final original = LocalChatAttachment(
        name: 'markup.png',
        bytes: raster.encodePng(source),
        image: true,
      );
      model.stageAttachment(original, target: model.snapshot!);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();

      Future<void> edit() async {
        await tester.tap(find.byTooltip('Preview image'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Edit image'));
        await tester.pumpAndSettle();
      }

      final canvas = find.byKey(const Key('photo-editor-canvas'));
      await edit();
      await tester.tap(find.byTooltip('Rotate clockwise'));
      await tester.pumpAndSettle();
      expect(tester.getSize(canvas).aspectRatio, closeTo(100 / 180, .01));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(model.stagedAttachments.single, same(original));
      expect(repository.uploads, 0);

      await edit();
      final rect = tester.getRect(canvas);
      Offset at(double left, double top) =>
          rect.topLeft +
          Offset(rect.width * left / 180, rect.height * top / 100);
      Future<void> stroke(Offset start, Offset end) async {
        final gesture = await tester.startGesture(start);
        await gesture.moveTo(Offset.lerp(start, end, .4)!);
        await tester.pump();
        await gesture.moveTo(end);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await stroke(at(105, 78), at(162, 78));
      await tester.tap(find.byTooltip('Blue'));
      await tester.tap(find.byTooltip('Add image text'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('photo-editor-text')),
        'NOTE',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mosaic'));
      await tester.pumpAndSettle();
      await stroke(at(10, 8), at(70, 41));
      await tester.tap(find.byTooltip('Rotate clockwise'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(tester.getSize(canvas).aspectRatio, closeTo(180 / 100, .01));
      await tester.tap(find.byTooltip('Redo'));
      await tester.pumpAndSettle();
      expect(tester.getSize(canvas).aspectRatio, closeTo(100 / 180, .01));

      await tester.tap(find.byTooltip('Save image edits'));
      await tester.pumpAndSettle();
      expect(model.stagedAttachments.single.name, 'markup.jpg');
      expect(repository.uploads, 0);
      expect(repository.imageReads, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Send ↑'));
      await tester.pumpAndSettle();
      expect(repository.sentAttachments, ['edited-upload']);
      final result = uploaded!;
      expect((result.width, result.height), (100, 180));
      expect(
        result.any((pixel) => pixel.r > pixel.g + 60 && pixel.r > pixel.b + 60),
        isTrue,
      );
      expect(
        result.any((pixel) => pixel.b > pixel.r + 45 && pixel.b > pixel.g + 30),
        isTrue,
      );
      expect(
        (result.getPixel(72, 25).r - result.getPixel(72, 26).r).abs(),
        lessThan(45),
      );
      expect(
        (result.getPixel(22, 25).r - result.getPixel(22, 26).r).abs(),
        greaterThan(100),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isIOS,
  );
}
