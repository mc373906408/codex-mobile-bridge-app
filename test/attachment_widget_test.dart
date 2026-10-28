import 'dart:async';
import 'dart:typed_data';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
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
        expect(bytes, orderedEquals(syntheticImage));
        return Attachment(
          id: photo.id,
          name: name,
          image: true,
          source: 'upload',
        );
      }
      ..onImage = (_, _) async => syntheticImage;
    model = BridgeViewModel(repository);
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

  Future<void> pickPhoto(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-photo')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    attachmentTest('photo chooser, preview and removal fit $size', (
      tester,
    ) async {
      await mount(tester, size: size);
      await pickPhoto(tester);
      expect(picker.types, [FileType.image]);
      expect(model.attachments, [photo]);
      expect(repository.uploads, 1);
      expect(repository.sends, 0);
      expect(repository.imageReads, 1);
      expect(find.byType(GatewayImage), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      final thumbnail = tester.widget<Image>(find.byType(Image));
      final resize = thumbnail.image as ResizeImage;
      expect(resize.policy, ResizeImagePolicy.fit);
      expect(resize.width, 320);
      expect(resize.height, 320);

      await tester.tap(find.byTooltip('Preview image'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image-preview-dialog')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(repository.imageReads, 1);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // Mock watch closure needs a turn outside the widget test's fake clock.
      await tester.runAsync(model.backToSessions);
      await tester.pumpAndSettle();
      await tester.runAsync(() => model.openSession(sessionA));
      await tester.pumpAndSettle();
      expect(model.attachments, [photo]);
      expect(find.byType(GatewayImage), findsOneWidget);
      expect(repository.uploads, 1);

      await tester.tap(find.byTooltip('Remove attachment: ${photo.name}'));
      await tester.pumpAndSettle();
      expect(model.attachments, isEmpty);
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
    expect(repository.uploads, 1);
  });

  attachmentTest(
    'picker result waits for resume and fresh authority, not lost',
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
      expect(find.byKey(const Key('pending-attachment')), findsOneWidget);
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
      expect(find.byKey(const Key('pending-attachment')), findsOneWidget);
      expect(repository.uploads, 0);
      repository.onUpload = (authority, _, _) async {
        expect(authority.controlToken, 'refreshed-authority');
        return photo;
      };
      refreshed.complete(snapshotFor(sessionA, token: 'refreshed-authority'));
      await tester.pumpAndSettle();
      expect(model.attachments, [photo]);
      expect(repository.uploads, 1);
      expect(repository.sends, 0);
      expect(find.byKey(const Key('pending-attachment')), findsNothing);
      expect(find.byType(GatewayImage), findsOneWidget);
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
      expect(model.error.toString(), contains('Attachment exceeds 20 MiB'));
      expect(file.reads, knownLength ? 0 : 1);
      expect(find.byKey(const Key('pending-attachment')), findsNothing);
    });
  }

  attachmentTest('unavailable preview stays removable and is not reuploaded', (
    tester,
  ) async {
    repository.onImage = (_, _) async =>
        throw StateError('Image is unavailable');
    await mount(tester);
    await pickPhoto(tester);
    expect(find.byTooltip('Image unavailable'), findsOneWidget);
    expect(model.attachments, [photo]);
    expect(repository.uploads, 1);
    await tester.tap(find.byTooltip('Remove attachment: ${photo.name}'));
    await tester.pumpAndSettle();
    expect(model.attachments, isEmpty);
    expect(repository.uploads, 1);
    expect(tester.takeException(), isNull);
  });

  for (final theme in ['light', 'dark']) {
    attachmentTest(
      'eight attachments fit a compact Chinese keyboard in $theme',
      (tester) async {
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        addTearDown(tester.view.resetViewInsets);
        await mount(tester, size: const Size(320, 640));
        model.setAppearance(locale: 'zh', theme: theme);
        for (var index = 0; index < 8; index++) {
          repository.onUpload = (_, _, _) async => Attachment(
            id: 'synthetic-$index',
            name: 'a-long-synthetic-image-filename-$index.png',
            image: true,
            source: 'upload',
          );
          await model.attach(photo.name, syntheticImage);
        }
        expect(model.attachments, hasLength(8));
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
      },
    );
  }

  attachmentTest(
    'a timed-out picker is not silently uploaded on a later resume',
    (tester) async {
      await mount(tester);
      final target = model.snapshot!;
      await tester.runAsync(() => model.setForeground(false));
      final attaching = model.attach(
        photo.name,
        syntheticImage,
        pickedFor: target,
      );
      await tester.pump(const Duration(seconds: 31));
      await attaching;
      expect(model.error.toString(), contains('Connection is not ready'));
      expect(repository.uploads, 0);
      await tester.runAsync(() => model.setForeground(true));
      expect(repository.uploads, 0);
      expect(model.attachments, isEmpty);
    },
  );
}
