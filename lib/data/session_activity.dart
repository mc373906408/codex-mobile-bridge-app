import 'dart:convert';

import 'package:flutter/foundation.dart';

enum SessionActivityKind {
  running,
  completed,
  failed,
  interrupted,
  awaiting,
  unknown,
}

String activityKey(String host, String id) => jsonEncode([host, id]);

/// Mirrors the Web SessionActivity rules: terminal history is a baseline until
/// a new turn is observed, and losing turn fields must not resurrect a read turn.
class SessionActivityTracker {
  SessionActivityTracker([Object? saved]) {
    if (saved is Map) {
      for (final entry in saved.entries) {
        if (entry.key is String && entry.value is Map) {
          rows[entry.key as String] = Map<String, dynamic>.from(entry.value);
        }
      }
    }
  }

  final Map<String, Map<String, dynamic>> rows = {};

  bool update(Iterable<Map<String, dynamic>> values, {String? visible}) {
    var changed = false;
    for (final value in values) {
      if (value['host'] is! String || value['id'] is! String) continue;
      final key = activityKey(value['host'], value['id']);
      final previous = rows[key];
      if (value['connected'] != true) {
        if (previous != null && previous['offline'] != true) {
          rows[key] = {...previous, 'offline': true};
          changed = true;
        }
        continue;
      }
      final turn = value['turnId'] is String ? value['turnId'] as String : '';
      final result = value['turnStatus'] is String
          ? value['turnStatus'] as String
          : '';
      final terminal = const {
        'completed',
        'failed',
        'interrupted',
      }.contains(result);
      final token = terminal && turn.isNotEmpty
          ? '$turn:$result'
          : previous?['token'];
      final pending =
          token != null &&
              previous != null &&
              (previous['turnKnown'] == true ||
                  previous['token'] != null ||
                  previous['status'] == 'active') &&
              (token != previous['token'] || previous['pending'] != null)
          ? token
          : null;
      final status = value['status'];
      final next = <String, dynamic>{
        'status': const {'active', 'running', 'inProgress'}.contains(status)
            ? 'active'
            : status is String
            ? status
            : '',
        'turnId': turn.isNotEmpty ? turn : previous?['turnId'],
        'turnStatus': result.isNotEmpty ? result : previous?['turnStatus'],
        'turnKnown': result.isNotEmpty || previous?['turnKnown'] == true,
        'token': token,
        'pending': visible == key ? null : pending,
        'offline': false,
        'awaiting': value['awaiting'] == true,
      };
      if (!mapEquals(previous, next)) {
        rows.remove(key);
        rows[key] = next;
        changed = true;
      }
    }
    while (rows.length > 1000) {
      rows.remove(rows.keys.first);
      changed = true;
    }
    return changed;
  }

  bool read(String key) {
    final row = rows[key];
    if (row == null || row['pending'] == null) return false;
    rows[key] = {...row, 'pending': null};
    return true;
  }

  SessionActivityKind? indicator(String key) {
    final row = rows[key];
    if (row == null) return null;
    if (row['offline'] == true) return SessionActivityKind.unknown;
    if (row['awaiting'] == true) return SessionActivityKind.awaiting;
    if (row['status'] == 'active') return SessionActivityKind.running;
    if (row['pending'] != null) {
      return switch (row['turnStatus']) {
        'completed' => SessionActivityKind.completed,
        'failed' => SessionActivityKind.failed,
        _ => SessionActivityKind.interrupted,
      };
    }
    return null;
  }
}
