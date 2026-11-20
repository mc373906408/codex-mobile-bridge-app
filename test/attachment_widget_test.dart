import 'dart:async';
import 'dart:typed_data';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/chat_attachment_preparation.dart';
import 'package:bridge_mobile/ui/attachment_preview.dart';
import 'package:bridge_mobile/ui/message_card.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attachment_picker.dart';
import 'support/fake_repository.dart';

const photo = Attachment(
  id: 'synthetic-upload',
  name: 'synthetic-photo.png',
  image: true,
  source: 'upload',
);

const historyPhoto = Attachment(
  id: 'preview-upload',
  name: 'history.png',
  image: true,
  source: 'upload',
  hasThumbnail: true,
);

const historyMessage = ChatMessage(
  id: 'history-with-image',
  role: 'user',
  title: '',
  text: 'Historical image',
  output: '',
  truncated: false,
  attachments: [historyPhoto],
);

void main() {
  late FakeRepository repository;
  late FakeAttachmentPicker picker;
  late FilePickerPlatform originalPicker;
  late BridgeViewModel model;

  setUp(() {
    originalPicker = FilePickerPlatform.instance;
    picker = FakeAttachmentPicker();
    FilePickerPlatform.instance = picker;
    repository = FakeRepository()
      ..onUpload = (_, name, bytes) async {
        expect(bytes, orderedEquals(syntheticJpeg));
        return Attachment(
          id: photo.id,
          name: name,
          image: true,
          source: 'upload',
        );
      }
      ..onImage = (_, _) async => syntheticImage;
    model = BridgeViewModel(
      repository,
      photoEncoder: (_) async => syntheticJpeg,
    );
  });

  tearDown(() {
    FilePickerPlatform.instance = originalPicker;
  });

  void resumeFrames(WidgetTester tester) {
    if (tester.binding.lifecycleState == AppLifecycleState.paused) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
    if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
    if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  }

  void attachmentTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        resumeFrames(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      }
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  Future<void> mount(WidgetTester tester, {Size? size}) async {
    resumeFrames(tester);
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pickPhoto(WidgetTester tester, {bool settle = true}) async {
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-photo')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    if (settle) await tester.pumpAndSettle();
  }

  final previewDialog = find.byKey(const Key('image-preview-dialog'));
  final previewImages = find.descendant(
    of: previewDialog,
    matching: find.byType(Image),
  );

  void openHistoryPhoto(WidgetTester tester) {
    final button = find.descendant(
      of: find.byType(GatewayImage),
      matching: find.byType(InkWell),
    );
    tester.widget<InkWell>(button).onTap!();
  }

  attachmentTest('desktop original survives leaving and reopening the chat', (
    tester,
  ) async {
    const desktopPhoto = Attachment(
      id: 'desktop-image',
      name: 'desktop.png',
      image: true,
      source: 'desktop',
    );
    final requested = <bool>[];
    repository.onSnapshot = (session) async => snapshotFor(
      session,
      messages: [
        const ChatMessage(
          id: 'desktop-message',
          role: 'user',
          title: '',
          text: 'Desktop screenshot',
          output: '',
          truncated: false,
          attachments: [desktopPhoto],
        ),
      ],
    );
    repository.onImageVariant = (_, _, thumbnail) async {
      requested.add(thumbnail);
      return AttachmentImageData(bytes: syntheticImage, isOriginal: true);
    };
    await mount(tester);
    openHistoryPhoto(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.runAsync(model.backToSessions);
    await tester.pumpAndSettle();
    await tester.runAsync(() => model.openSession(sessionA));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentImage), findsOneWidget);
    expect(requested, [false]);
  });

  attachmentTest(
    'history uses a thumbnail and reuses the fullscreen original',
    (tester) async {
      final thumbnail = Uint8List.fromList(syntheticImage);
      final original = Uint8List.fromList(syntheticImage);
      final blockedOriginal = Completer<AttachmentImageData>();
      final requested = <bool>[];
      repository.onSnapshot = (session) async =>
          snapshotFor(session, messages: [historyMessage]);
      repository.onImageVariant = (_, _, thumbnailRequested) async {
        requested.add(thumbnailRequested);
        if (thumbnailRequested) {
          return AttachmentImageData(bytes: thumbnail, isOriginal: false);
        }
        return blockedOriginal.future;
      };
      await mount(tester, size: const Size(390, 844));
      expect(requested, [true]);
      openHistoryPhoto(tester);
      await tester.pumpAndSettle();
      expect(requested, [true, false]);
      final small = tester.widget<Image>(previewImages).image as ResizeImage;
      expect((small.imageProvider as MemoryImage).bytes, same(thumbnail));
      blockedOriginal.complete(
        AttachmentImageData(bytes: original, isOriginal: true),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Image>(previewImages)
            .map((value) => (value.image as ResizeImage).imageProvider)
            .whereType<MemoryImage>()
            .any((provider) => identical(provider.bytes, original)),
        isTrue,
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.runAsync(model.backToSessions);
      await tester.pumpAndSettle();
      await tester.runAsync(() => model.openSession(sessionA));
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentImage), findsOneWidget);
      openHistoryPhoto(tester);
      await tester.pumpAndSettle();
      expect(requested, [true, false]);
    },
  );

  attachmentTest('failed fullscreen load retains the thumbnail and can retry', (
    tester,
  ) async {
    final requested = <bool>[];
    repository.onSnapshot = (session) async =>
        snapshotFor(session, messages: [historyMessage]);
    repository.onImageVariant = (_, _, thumbnail) async {
      requested.add(thumbnail);
      if (requested.length == 2) throw StateError('Image unavailable');
      return AttachmentImageData(bytes: syntheticImage, isOriginal: !thumbnail);
    };
    await mount(tester);
    openHistoryPhoto(tester);
    await tester.pumpAndSettle();
    expect(previewImages, findsOneWidget);
    expect(find.byTooltip('Retry'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(requested, [true, false, false]);
    expect(find.byTooltip('Retry'), findsNothing);
  });

  attachmentTest(
    'account changes hide a fullscreen image and ignore its late original',
    (tester) async {
      final oldOriginal = Completer<AttachmentImageData>();
      final requested = <bool>[];
      repository.onSnapshot = (session) async =>
          snapshotFor(session, messages: [historyMessage]);
      repository.onImageVariant = (_, _, thumbnail) async {
        requested.add(thumbnail);
        if (!thumbnail) return oldOriginal.future;
        return AttachmentImageData(
          bytes: Uint8List.fromList(syntheticImage),
          isOriginal: false,
        );
      };
      await mount(tester);
      openHistoryPhoto(tester);
      await tester.pumpAndSettle();
      expect(previewImages, findsOneWidget);
      repository.emit(
        snapshotFor(sessionA, account: 'account-b', messages: [historyMessage]),
      );
      await tester.pumpAndSettle();
      oldOriginal.complete(
        AttachmentImageData(bytes: syntheticImage, isOriginal: true),
      );
      await tester.pumpAndSettle();
      expect(previewImages, findsNothing);
      expect(
        find.descendant(
          of: previewDialog,
          matching: find.text('Image unavailable'),
        ),
        findsOneWidget,
      );
      expect(requested, [true, false, true]);
    },
  );

  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    attachmentTest('photo chooser, preview and removal fit $size', (
      tester,
    ) async {
      await mount(tester, size: size);
      await pickPhoto(tester);
      expect(picker.types, [FileType.image]);
      expect(model.stagedAttachments.single.name, photo.name);
      expect(repository.uploads, 0);
      expect(repository.sends, 0);
      expect(repository.imageReads, 0);
      expect(find.byType(GatewayImage), findsNothing);
      final preview = find.descendant(
        of: find.byType(AttachmentImage),
        matching: find.byType(Image),
      );
      expect(preview, findsOneWidget);
      final thumbnail = tester.widget<Image>(preview);
      final resize = thumbnail.image as ResizeImage;
      expect(resize.policy, ResizeImagePolicy.fit);
      expect(resize.width, 320);
      expect(resize.height, 320);

      await tester.tap(find.byTooltip('Preview image'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image-preview-dialog')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(repository.imageReads, 0);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // Mock watch closure needs a turn outside the widget test's fake clock.
      await tester.runAsync(model.backToSessions);
      await tester.pumpAndSettle();
      await tester.runAsync(() => model.openSession(sessionA));
      await tester.pumpAndSettle();
      expect(model.stagedAttachments.single.name, photo.name);
      expect(find.byType(AttachmentImage), findsOneWidget);
      expect(repository.uploads, 0);

      await tester.tap(find.byTooltip('Remove attachment: ${photo.name}'));
      await tester.pumpAndSettle();
      expect(model.stagedAttachments, isEmpty);
      expect(find.byKey(const Key('attachment-strip')), findsNothing);
      expect(
        (await repository.draft(sessionA, 'account-a')).attachments,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  attachmentTest('restored attachment drafts load their scoped image preview', (
    tester,
  ) async {
    repository.drafts[repository.scope(sessionA, 'account-a')] = const Draft(
      text: '',
      attachments: [photo],
      revision: 1,
    );
    await mount(tester);
    expect(model.attachments, [photo]);
    expect(find.byType(GatewayImage), findsOneWidget);
    expect(repository.uploads, 0);
    expect(repository.imageReads, 1);
  });

  attachmentTest(
    'file entry remains separate and picker cancellation does nothing',
    (tester) async {
      picker.onPick = () async => null;
      await mount(tester);
      await tester.tap(find.byTooltip('Add attachment'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pick-photo')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pick-file')));
      await tester.pumpAndSettle();
      expect(picker.types, [FileType.any]);
      expect(repository.uploads, 0);
      expect(model.attachments, isEmpty);
      expect(model.error, isNull);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Add attachment',
              ),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  attachmentTest('image-only clients never offer arbitrary files', (
    tester,
  ) async {
    repository.onSnapshot = (session) async => snapshotFor(
      session,
      capabilities: const CapabilitySet(
        send: true,
        steer: false,
        stop: false,
        approve: false,
        resume: false,
        models: false,
        attachments: true,
        arbitraryFiles: false,
      ),
    );
    await mount(tester);
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pick-photo')), findsOneWidget);
    expect(find.byKey(const Key('pick-file')), findsNothing);
    await tester.tap(find.byKey(const Key('pick-photo')));
    await tester.pumpAndSettle();
    expect(picker.types, [FileType.image]);
    expect(repository.uploads, 0);
    expect(model.stagedAttachments.single.image, isTrue);
  });

  attachmentTest(
    'picker stages locally before resume and send uses refreshed authority',
    (tester) async {
      final picked = Completer<PlatformFile?>();
      final reconnect = Completer<AuthStatus>();
      final refreshed = Completer<SessionSnapshot>();
      picker.onPick = () => picked.future;
      await mount(tester);
      await pickPhoto(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      picked.complete(MemoryPickedFile());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(model.stagedAttachments, hasLength(1));
      expect(find.byType(AttachmentImage), findsOneWidget);
      expect(repository.uploads, 0);
      expect(model.busy, isFalse);
      expect(model.canSend, isFalse);

      repository.onConnect = (_) => reconnect.future;
      repository.onSnapshot = (_) => refreshed.future;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(repository.uploads, 0);
      reconnect.complete(authenticatedStatus);
      await tester.pump();
      expect(model.snapshot, isNull);
      expect(repository.uploads, 0);
      repository.onUpload = (authority, name, bytes) async {
        expect(authority.controlToken, 'refreshed-authority');
        expect(name, 'synthetic-photo.jpg');
        expect(bytes, syntheticJpeg);
        return photo;
      };
      refreshed.complete(snapshotFor(sessionA, token: 'refreshed-authority'));
      await tester.pumpAndSettle();
      expect(model.stagedAttachments, hasLength(1));
      expect(repository.uploads, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Send ↑'));
      await tester.pumpAndSettle();
      expect(repository.uploads, 1);
      expect(repository.sends, 1);
      expect(find.byKey(const Key('pending-attachment')), findsNothing);
      expect(model.stagedAttachments, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final changeAccount in [false, true]) {
    attachmentTest(
      'late selection cannot cross scope, account=$changeAccount',
      (tester) async {
        final picked = Completer<PlatformFile?>();
        picker.onPick = () => picked.future;
        await mount(tester);
        await pickPhoto(tester);
        if (changeAccount) {
          repository.onSnapshot = (session) async =>
              snapshotFor(session, account: 'another-account');
          await tester.runAsync(() => model.openSession(sessionA));
        } else {
          await tester.runAsync(() => model.openSession(sessionB));
        }
        picked.complete(MemoryPickedFile());
        await tester.pumpAndSettle();
        expect(repository.uploads, 0);
        expect(model.attachments, isEmpty);
        expect(model.stagedAttachments, isEmpty);
        expect(find.byKey(const Key('pending-attachment')), findsNothing);
        expect(model.error, isNull);
      },
    );
  }

  for (final knownLength in [false, true]) {
    attachmentTest('20 MiB limit is enforced for known length=$knownLength', (
      tester,
    ) async {
      final file = MemoryPickedFile(
        reportedLength: knownLength ? 20 * 1024 * 1024 + 1 : null,
        chunks: knownLength
            ? null
            : [Uint8List(20 * 1024 * 1024), Uint8List(1)],
      );
      picker.onPick = () async => file;
      await mount(tester);
      await pickPhoto(tester);
      expect(repository.uploads, 0);
      expect(model.attachments, isEmpty);
      expect(model.stagedAttachments, isEmpty);
      expect(model.error.toString(), contains('Attachment exceeds 20 MiB'));
      expect(file.reads, knownLength ? 0 : 1);
      expect(find.byKey(const Key('pending-attachment')), findsNothing);
    });
  }

  attachmentTest('unavailable preview stays removable and is not reuploaded', (
    tester,
  ) async {
    picker.onPick = () async =>
        MemoryPickedFile(bytes: Uint8List.fromList([1]));
    await mount(tester);
    await pickPhoto(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Image unavailable'), findsOneWidget);
    expect(model.stagedAttachments.single.name, photo.name);
    expect(repository.uploads, 0);
    await tester.tap(find.byTooltip('Remove attachment: ${photo.name}'));
    await tester.pumpAndSettle();
    expect(model.stagedAttachments, isEmpty);
    expect(repository.uploads, 0);
    expect(tester.takeException(), isNull);
  });

  for (final theme in ['light', 'dark']) {
    attachmentTest('ten attachments fit a compact Chinese keyboard in $theme', (
      tester,
    ) async {
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await mount(tester, size: const Size(320, 640));
      model.setAppearance(locale: 'zh', theme: theme);
      for (var index = 0; index < 10; index++) {
        model.stageAttachment(
          LocalChatAttachment(
            name: 'a-long-synthetic-image-filename-$index.png',
            bytes: syntheticImage,
            image: true,
          ),
          target: model.snapshot!,
        );
      }
      expect(model.stagedAttachments, hasLength(10));
      expect(model.canAttach, isFalse);
      await tester.enterText(find.byKey(const Key('composer')), 'synthetic');
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byKey(const Key('attachment-strip')),
        const Offset(-720, 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('a-long-synthetic-image-filename-7.png'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  attachmentTest(
    'slow conversion and upload keep the send action available without duplication',
    (tester) async {
      model.dispose();
      final encoded = Completer<Uint8List>();
      final uploaded = Completer<Attachment>();
      var preparations = 0;
      repository.onUpload = (_, name, bytes) {
        expect(name, 'synthetic-photo.jpg');
        expect(bytes, orderedEquals(syntheticJpeg));
        return uploaded.future;
      };
      model = BridgeViewModel(
        repository,
        photoEncoder: (_) {
          preparations++;
          return encoded.future;
        },
      );
      await mount(tester);
      await pickPhoto(tester, settle: false);
      await tester.pump(const Duration(milliseconds: 400));
      final send = find.widgetWithText(FilledButton, 'Send ↑');
      expect(preparations, 1);
      expect(find.byType(AttachmentImage), findsOneWidget);
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
      expect(repository.imageReads, 0);
      expect(repository.uploads, 0);
      await tester.tap(send);
      await tester.pump();
      expect(repository.uploads, 0);
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
      encoded.complete(syntheticJpeg);
      await tester.pump();
      expect(repository.uploads, 1);
      expect(repository.sends, 0);
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is LinearProgressIndicator &&
              widget.semanticsLabel == 'Uploading attachment…',
        ),
        findsOneWidget,
      );
      await tester.tap(send);
      await tester.pump();
      expect(repository.uploads, 1);
      uploaded.complete(photo);
      await tester.pumpAndSettle();
      expect(repository.sends, 1);
      expect(repository.sentAttachments, [photo.id]);
      expect(model.stagedAttachments, isEmpty);
    },
  );
}
