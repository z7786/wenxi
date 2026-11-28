import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/windows_actions.dart';

void main() {
  test(
    'Explorer selects an existing path as arguments without a shell',
    () async {
      final root = await Directory.systemTemp.createTemp('wenxi-explorer-');
      addTearDown(() => root.delete(recursive: true));
      final file = await File(
        '${root.path}/中文 video & (1).mp4',
      ).writeAsString('x');
      final calls = <(String, List<String>)>[];
      final windows = WindowsActions(
        supported: true,
        start: (command, arguments) async => calls.add((command, arguments)),
        run: (_, _) async => fail('No shutdown expected'),
      );
      await windows.revealFile(file.path);
      expect(calls.single.$1, windowsSystemExecutable('explorer.exe'));
      expect(calls.single.$2, ['/select,', p.normalize(file.path)]);
      calls.clear();
      await windows.revealFile(root.path);
      expect(calls.single.$2, [root.path]);
      await file.delete();
      await expectLater(
        windows.revealFile(file.path),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        windows.revealFile('relative.mp4'),
        throwsA(isA<AppException>()),
      );
      expect(calls.length, 1);
    },
  );

  test(
    'Shutdown request uses no force, restart, or system countdown',
    () async {
      final calls = <(String, List<String>)>[];
      final windows = WindowsActions(
        supported: true,
        start: (_, _) async => fail('No process start expected'),
        run: (command, arguments) async => calls.add((command, arguments)),
      );
      await windows.shutdown();
      expect(
        calls.single.$1,
        windowsSystemExecutable(r'System32\shutdown.exe'),
      );
      expect(calls.single.$2, ['/s', '/t', '0']);
      final unavailable = WindowsActions(
        supported: false,
        run: (_, _) async => fail('Unsupported platform must not run commands'),
      );
      await expectLater(unavailable.shutdown(), throwsA(isA<AppException>()));
    },
  );

  test('Hibernation requests only /h on supported Windows systems', () async {
    final calls = <(String, List<String>)>[];
    final windows = WindowsActions(
      supported: true,
      start: (_, _) async => fail('No detached process start expected'),
      run: (command, arguments) async => calls.add((command, arguments)),
    );
    await windows.hibernate();
    expect(calls, hasLength(1));
    expect(
      calls.single.$1,
      windowsSystemExecutable(r'System32\shutdown.exe'),
    );
    expect(calls.single.$2, ['/h']);
    final unavailable = WindowsActions(
      supported: false,
      run: (_, _) async => fail('Unsupported platform must not run commands'),
    );
    await expectLater(unavailable.hibernate(), throwsA(isA<AppException>()));
  });

  test(
    'Hibernation refusal propagates without another power command',
    () async {
      final calls = <(String, List<String>)>[];
      const error = AppException('fixture hibernation disabled');
      final windows = WindowsActions(
        supported: true,
        run: (command, arguments) async {
          calls.add((command, arguments));
          throw error;
        },
      );
      await expectLater(windows.hibernate(), throwsA(same(error)));
      expect(calls, hasLength(1));
      expect(
        calls.single.$1,
        windowsSystemExecutable(r'System32\shutdown.exe'),
      );
      expect(calls.single.$2, ['/h']);
    },
  );

  test('SystemRoot validation resolves absolute roots and rejects unsafe values', () {
    expect(windowsSystemRoot({}), r'C:\Windows');
    expect(windowsSystemRoot({'SystemRoot': r'D:\Windows\'}), r'D:\Windows');
    expect(windowsSystemRoot({'SYSTEMROOT': r'E:\WINNT'}), r'E:\WINNT');
    expect(
      windowsSystemExecutable(
        r'System32\WindowsPowerShell\v1.0\powershell.exe',
        {'SystemRoot': r'D:\Windows'},
      ),
      r'D:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
    );
    for (final invalid in [
      '',
      'Windows',
      r'\\server\share\Windows',
      r'C:\Windows\..\Evil',
      r'C:\Windows\.\Evil',
      r'C:\Windows\.',
      r'C:\Windows\\Sub',
      r'C:\Windows\.. \Evil',
      r'C:\Windows\...\Evil',
      r'C:\Windows\Sub.',
      r'C:\Windows\Sub \Evil',
      r'C:\',
      'C:/Windows',
      'C:\\Windows\nEvil',
    ]) {
      expect(
        windowsSystemRoot({'SystemRoot': invalid}),
        r'C:\Windows',
        reason: 'Expected fallback for invalid SystemRoot: $invalid',
      );
    }
  });
}
