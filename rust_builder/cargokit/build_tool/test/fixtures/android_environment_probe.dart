import 'dart:io';

import 'package:build_tool/src/android_environment.dart';
import 'package:build_tool/src/target.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> args) async {
  final host = Platform.isWindows
      ? 'windows-x86_64'
      : Platform.isMacOS
          ? 'darwin-x86_64'
          : 'linux-x86_64';
  final ar = File(path.join(args.single, 'ndk', '28.2.0', 'toolchains', 'llvm',
      'prebuilt', host, 'bin', 'llvm-ar'));
  ar.parent.createSync(recursive: true);
  ar.writeAsStringSync('synthetic NDK fixture');
  final environment = await AndroidEnvironment(
    sdkPath: args.single,
    ndkVersion: '28.2.0',
    minSdkVersion: 26,
    targetTempDir: args.single,
    target: Target.forRustTriple('aarch64-linux-android')!,
  ).buildEnvironment();
  final linker = environment['CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER']!;
  if (!File(linker).existsSync()) {
    throw StateError('Resolved linker wrapper does not exist: $linker');
  }
  print('Resolved existing linker wrapper');
}
