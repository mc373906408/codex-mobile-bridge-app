import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('compiled kernel resolves its linker outside the package tree',
      () async {
    final root = Directory.systemTemp.createTempSync('bridge-kernel-test-');
    addTearDown(() {
      final resolved = root.resolveSymbolicLinksSync();
      if (path.dirname(resolved) !=
              Directory.systemTemp.resolveSymbolicLinksSync() ||
          !path.basename(resolved).startsWith('bridge-kernel-test-')) {
        throw StateError('Refusing to delete an unowned test directory');
      }
      root.deleteSync(recursive: true);
    });
    final config = path.absolute('.dart_tool/package_config.json');
    final kernel = path.join(root.path, 'probe.dill');
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'test/fixtures/android_environment_probe.dart',
      '-o',
      kernel,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=$config',
          kernel,
          root.path,
        ],
        workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('Resolved existing linker wrapper'));
  });
}
