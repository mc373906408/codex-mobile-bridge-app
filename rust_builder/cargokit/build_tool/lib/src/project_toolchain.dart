import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:toml/toml.dart';

String projectToolchain(String manifestDir) {
  final file = File(path.join(manifestDir, '..', 'rust-toolchain.toml'));
  final config = TomlDocument.parse(file.readAsStringSync()).toMap();
  final toolchain = config['toolchain'];
  final channel = toolchain is Map ? toolchain['channel'] : null;
  if (channel != 'stable') {
    throw FormatException(
        'The project must use the current stable Rust channel', file.path);
  }
  return 'stable';
}
