import 'dart:convert';

import 'bridge_types.dart';

/// Display names are local preferences, never part of connection identity.
String computerNameKey(Computer computer) => jsonEncode([
  computer.id,
  computer.connectionType.name,
  computer.baseUrl,
  computer.relay?.origin,
  computer.relay?.accountId,
  computer.relay?.gatewayId,
  computer.relay?.bindingId,
  computer.relay?.desktopPublicKey,
]);

Map<String, String> decodeComputerNames(String? value) {
  if (value == null) return {};
  final decoded = jsonDecode(value);
  if (decoded is! Map<String, dynamic> ||
      decoded.values.any((name) => name is! String)) {
    throw const FormatException('Invalid saved computer names');
  }
  return decoded.cast<String, String>();
}
