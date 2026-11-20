import 'dart:convert';

import 'package:crypto/crypto.dart';

export '../src/rust/api/cloud_types.dart';
export '../src/rust/api/types.dart';
export '../src/rust/api/workbench.dart';

String notificationReadKey(String computer, String scope, String event) =>
    sha256
        .convert(utf8.encode(jsonEncode([computer, scope, event])))
        .toString();
