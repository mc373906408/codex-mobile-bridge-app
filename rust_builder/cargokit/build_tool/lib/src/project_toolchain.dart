import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:toml/toml.dart';

String projectToolchain(String manifestDir) {
  final file = File(path.join(manifestDir, '..', 'rust-toolchain.toml'));
  final config = TomlDocument.parse(file.readAsStringSync()).toMap();
  final toolchain = config['toolchain'];
  final channel = toolchain is Map ? toolchain['channel'] : null;
  if (channel is! String || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(channel)) {
    throw FormatException(
        'The project must pin an exact stable Rust version', file.path);
  }
  return channel;
}
