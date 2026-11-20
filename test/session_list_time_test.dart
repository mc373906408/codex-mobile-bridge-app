import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/session_time.dart';
import 'package:bridge_mobile/ui/pages/session_list_tile.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

ChatMessage _message(String role, Object? timestamp) => ChatMessage(
  id: '$role-$timestamp',
  role: role,
  title: '',
  text: 'Content',
  output: '',
  truncated: false,
  attachments: [],
  metadata: jsonEncode({'timestamp': timestamp}),
);

void main() {
  test(
    'reads time formats supplied by the gateway without inventing a date',
    () {
      final instant = DateTime.utc(2026, 11, 20, 8, 23);
      final millis = instant.millisecondsSinceEpoch;
      for (final value in [
        millis,
        millis ~/ 1000,
        '$millis',
        '"${instant.toIso8601String()}"',
      ]) {
        expect(parseSessionTime(value)?.toUtc(), instant);
      }
      for (final value in [null, 'null', '', 'bad', double.nan, 0, -1, 1e30]) {
        expect(parseSessionTime(value), isNull);
      }
      final row = SessionSummary(
        session: sessionA,
        title: '',
        cwd: '',
        updatedAt: '',
        status: '',
        backend: '',
        metadata: jsonEncode({'updated_at_ms': millis, 'recency': millis + 9}),
      );
      expect(
        sessionUpdateTime(row, decodeSessionMetadata(row.metadata))?.toUtc(),
        instant,
      );
      expect(sessionListRevision(row), '$millis');
    },
  );

  test(
    'tool activity and older timestamps do not impersonate the last message',
    () {
      final value = snapshotFor(
        sessionA,
        messages: [
          _message('user', '2026-11-20T01:00:00Z'),
          _message('assistant', '2026-11-20T02:00:00Z'),
          _message('activity', '2026-11-20T03:00:00Z'),
        ],
      );
      expect(
        lastSnapshotMessageTime(value)?.toUtc(),
        DateTime.utc(2026, 11, 20, 2),
      );
      expect(
        lastSnapshotMessageTime(
          snapshotFor(
            sessionA,
            messages: [...value.history.messages, _message('assistant', null)],
          ),
        ),
        isNull,
      );
    },
  );

  test(
    'new list revisions invalidate the old read marker and message time',
    () async {
      const oldTime = '2026-11-20T08:23:00Z';
      const newTime = '2026-11-20T08:24:00Z';
      SessionSummary row(String time) => SessionSummary(
        session: sessionA,
        title: 'Conversation',
        cwd: '/work/bridge',
        updatedAt: '',
        status: 'idle',
        backend: 'desktop',
        metadata: jsonEncode({
          'updated_at_ms': DateTime.parse(time).millisecondsSinceEpoch,
        }),
      );
      var latest = row(oldTime);
      final repository = FakeRepository()
        ..onSessions = (_, _, _, _) async {
          return SessionPage(sessions: [latest], notice: '', nextOffset: null);
        }
        ..onSnapshot = (_) async {
          return snapshotFor(
            sessionA,
            messages: [_message('assistant', oldTime)],
          );
        };
      final model = BridgeViewModel(repository);
      addTearDown(model.dispose);
      await model.initialize();
      await model.selectComputer(computerA);
      await model.openListedSession(latest);
      await model.backToSessions();
      expect(model.isSessionRead(sessionA), isTrue);
      expect(model.lastMessageTime(latest)?.toUtc(), DateTime.parse(oldTime));

      latest = row(newTime);
      await model.refreshSessions();
      expect(model.isSessionRead(sessionA), isFalse);
      expect(model.lastMessageTime(latest), isNull);
      repository.onSnapshot = (_) async =>
          snapshotFor(sessionA, messages: [_message('assistant', newTime)]);
      await model.prefetchListedSessions([latest]);
      expect(model.lastMessageTime(latest)?.toUtc(), DateTime.parse(newTime));
      expect(model.isSessionRead(sessionA), isFalse);
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets(
      'chat list shows timestamps without prefixes on narrow $language layouts',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final repository = FakeRepository();
        final model = BridgeViewModel(repository);
        await model.initialize();
        model.setAppearance(locale: language);
        await model.selectComputer(computerA);
        await model.renameComputer(
          computerA,
          'A desktop with a deliberately long display name',
        );
        final response = Completer<SessionSnapshot>();
        var reads = 0;
        repository.onSnapshot = (_) {
          reads++;
          return response.future;
        };
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model),
        );
        final tile = find.byType(SessionListTile);
        final context = tester.element(tile);
        final localizations = MaterialLocalizations.of(context);
        final prefixedTime = find.descendant(
          of: tile,
          matching: find.textContaining(RegExp(r'^(更新|Updated)\s')),
        );
        expect(tester.widget<SessionListTile>(tile).messageTime, isNull);
        expect(
          find.descendant(
            of: tile,
            matching: find.text(
              localizations.formatCompactDate(DateTime(2026, 10, 28)),
            ),
          ),
          findsOneWidget,
        );
        expect(prefixedTime, findsNothing);

        final today = DateTime.now();
        final instant = DateTime(today.year, today.month, today.day, 8, 23);
        response.complete(
          snapshotFor(
            sessionA,
            messages: [_message('assistant', instant.toIso8601String())],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<SessionListTile>(tile).messageTime?.toUtc(),
          instant.toUtc(),
        );
        expect(
          find.descendant(
            of: tile,
            matching: find.text(
              localizations.formatTimeOfDay(
                TimeOfDay.fromDateTime(instant),
                alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(
                  context,
                ),
              ),
            ),
          ),
          findsOneWidget,
        );
        final timeLabel = language == 'zh' ? '最后一条消息:' : 'Last message:';
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Tooltip && widget.message!.startsWith(timeLabel),
          ),
          findsOneWidget,
        );
        expect(prefixedTime, findsNothing);
        expect(tester.takeException(), isNull);
        expect(reads, 1);
        expect(model.isSessionRead(sessionA), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      },
    );
  }
}
