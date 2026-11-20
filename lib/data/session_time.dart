import 'dart:convert';

import 'bridge_types.dart';

Map<String, dynamic> decodeSessionMetadata(String encoded) {
  try {
    final value = jsonDecode(encoded);
    if (value is Map<String, dynamic>) return value;
  } on FormatException {
    return const {};
  }
  return const {};
}

DateTime? parseSessionTime(Object? value, {bool milliseconds = false}) {
  String? text = value is String ? value.trim() : null;
  if (text != null && text.startsWith('"')) {
    try {
      final decoded = jsonDecode(text);
      text = decoded is String ? decoded.trim() : null;
    } on FormatException {
      return null;
    }
  }
  final stamp = value is num ? value : num.tryParse(text ?? '');
  if (stamp == null) {
    return text == null ? null : DateTime.tryParse(text)?.toLocal();
  }
  if (!stamp.isFinite || stamp <= 0) return null;
  final epoch = milliseconds || stamp >= 100000000000 ? stamp : stamp * 1000;
  if (epoch > 8640000000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(epoch.round());
}

DateTime? lastSnapshotMessageTime(SessionSnapshot snapshot) {
  for (final message in snapshot.history.messages.reversed) {
    if (message.role == 'user' || message.role == 'assistant') {
      return parseSessionTime(
        decodeSessionMetadata(message.metadata)['timestamp'],
      );
    }
  }
  return null;
}

DateTime? sessionUpdateTime(
  SessionSummary session,
  Map<String, dynamic> data,
) =>
    parseSessionTime(data['updated_at_ms'], milliseconds: true) ??
    parseSessionTime(data['updatedAt']) ??
    parseSessionTime(data['updated_at']) ??
    parseSessionTime(session.updatedAt);

String sessionListRevision(SessionSummary session) {
  if (session.updatedAt.isNotEmpty && session.updatedAt != 'null') {
    return session.updatedAt;
  }
  final data = decodeSessionMetadata(session.metadata);
  return (data['updated_at_ms'] ?? data['updated_at'] ?? data['recency'])
          ?.toString() ??
      '';
}
