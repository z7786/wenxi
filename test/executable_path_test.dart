import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/desktop_platform.dart';
import 'package:asterlink/platform/executable_path.dart';

void main() {
  test('a valid resolved path does not call fallbacks', () {
    var nativeReads = 0, invocationReads = 0;
    expect(
      resolveExecutablePath(
        platform: 'windows',
        resolved: () => r'C:\Apps\文析助手\bin\..\app.exe',
        nativeWindows: () {
          nativeReads++;
          return r'D:\wrong.exe';
        },
        invocation: () {
          invocationReads++;
          return r'D:\also-wrong.exe';
        },
      ),
      r'C:\Apps\文析助手\app.exe',
    );
    expect(nativeReads, 0);
    expect(invocationReads, 0);
  });

  for (final invalid in [null, '', 'app.exe', r'C:app.exe', r'\app.exe']) {
    test('invalid Dart path $invalid uses the actual Windows module', () {
      final path = resolveExecutablePath(
        platform: 'windows',
        resolved: () => invalid,
        nativeWindows: () => r'D:\便携软件\文析助手.exe',
        invocation: () => 'app.exe',
      );
      expect(path, r'D:\便携软件\文析助手.exe');
      expect(
        desktopDownloadExecutable(path, 'windows'),
        r'D:\便携软件\asterlink_gopeed.exe',
      );
    });
  }

  test('the exact resolvedExecutable TypeError is caught', () {
    expect(
      resolveExecutablePath(
        platform: 'windows',
        resolved: () => throw TypeError(),
        nativeWindows: () => r'C:\Program Files\文析助手\app.exe',
        invocation: () => null,
      ),
      r'C:\Program Files\文析助手\app.exe',
    );
  });

  test('Unicode, UNC and extended Windows paths remain absolute', () {
    for (final path in [
      r'C:\Apps\文析助手\app.exe',
      r'\\server\share\文析助手\app.exe',
      r'\\?\C:\Apps\文析助手\app.exe',
    ]) {
      expect(
        resolveExecutablePath(
          platform: 'windows',
          resolved: () => null,
          nativeWindows: () => path,
          invocation: () => null,
        ),
        path,
      );
    }
  });

  test('an absolute original invocation is the final fallback', () {
    expect(
      resolveExecutablePath(
        platform: 'windows',
        resolved: () => throw TypeError(),
        nativeWindows: () => throw StateError('kernel lookup failed'),
        invocation: () => r'D:\Apps\app.exe',
      ),
      r'D:\Apps\app.exe',
    );
  });

  test('macOS keeps its bundle path and never invokes Windows APIs', () {
    expect(
      resolveExecutablePath(
        platform: 'macos',
        resolved: () => null,
        nativeWindows: () => throw StateError('must not call Windows'),
        invocation: () => '/Applications/文析助手.app/Contents/MacOS/文析助手',
      ),
      '/Applications/文析助手.app/Contents/MacOS/文析助手',
    );
  });

  for (final invalid in [
    'app.exe',
    r'C:app.exe',
    r'C:\',
    '${r'C:\app'}\u0000.exe',
  ]) {
    test(
      'never resolves invalid fallback $invalid against the working directory',
      () {
        expect(
          () => resolveExecutablePath(
            platform: 'windows',
            resolved: () => null,
            nativeWindows: () => null,
            invocation: () => invalid,
          ),
          throwsA(isA<AppException>()),
        );
      },
    );
  }

  test(
    'real Windows API returns the running host executable',
    () {
      final path = windowsProcessExecutablePath();
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(p.windows.equals(path, Platform.resolvedExecutable), isTrue);
      expect(
        resolveExecutablePath(
          resolved: () => throw TypeError(),
          invocation: () => null,
        ),
        p.normalize(path),
      );
    },
    skip: !Platform.isWindows,
  );
}
