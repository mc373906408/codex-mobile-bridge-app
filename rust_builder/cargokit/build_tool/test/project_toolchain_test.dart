import 'dart:io';

import 'package:build_tool/src/project_toolchain.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory manifest;
  setUp(() {
    root = Directory.systemTemp.createTempSync('bridge-toolchain-test-');
    manifest = Directory(path.join(root.path, 'rust'))..createSync();
  });
  tearDown(() {
    final resolved = root.resolveSymbolicLinksSync();
    if (path.dirname(resolved) !=
            Directory.systemTemp.resolveSymbolicLinksSync() ||
        !path.basename(resolved).startsWith('bridge-toolchain-test-')) {
      throw StateError('Refusing to delete an unowned test directory');
    }
    root.deleteSync(recursive: true);
  });

  test('native builds select the current stable channel', () {
    File(path.join(root.path, 'rust-toolchain.toml'))
        .writeAsStringSync('[toolchain]\nchannel = "stable"\n');
    expect(projectToolchain(manifest.path), 'stable');
  });

  for (final value in ['nightly', 'beta', '1.99', '1.99.1', '1.99.1-nightly']) {
    test('rejects an obsolete pin or non-stable channel: $value', () {
      File(path.join(root.path, 'rust-toolchain.toml'))
          .writeAsStringSync('[toolchain]\nchannel = "$value"\n');
      expect(() => projectToolchain(manifest.path), throwsFormatException);
    });
  }

  test('a missing project channel is an error', () {
    expect(() => projectToolchain(manifest.path),
        throwsA(isA<FileSystemException>()));
  });
}
