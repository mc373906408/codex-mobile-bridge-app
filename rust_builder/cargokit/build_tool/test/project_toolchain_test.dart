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

  test('native builds read the exact project pin rather than the stable alias',
      () {
    File(path.join(root.path, 'rust-toolchain.toml'))
        .writeAsStringSync('[toolchain]\nchannel = "1.99.1"\n');
    expect(projectToolchain(manifest.path), '1.99.1');
  });

  for (final value in ['stable', 'nightly', 'beta', '1.99', '1.99.1-nightly']) {
    test('rejects a floating or non-stable toolchain: $value', () {
      File(path.join(root.path, 'rust-toolchain.toml'))
          .writeAsStringSync('[toolchain]\nchannel = "$value"\n');
      expect(() => projectToolchain(manifest.path), throwsFormatException);
    });
  }

  test('a missing project pin fails closed', () {
    expect(() => projectToolchain(manifest.path),
        throwsA(isA<FileSystemException>()));
  });
}
