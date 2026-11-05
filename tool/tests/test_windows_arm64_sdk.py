import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = '''class BuildWindowsCommand {
  BuildWindowsCommand({
    required OperatingSystemUtils operatingSystemUtils,
    bool verboseHelp = false,
  }) : _operatingSystemUtils = operatingSystemUtils,
       super(verboseHelp: verboseHelp) {
    usesFlavorOption();
  }
  final OperatingSystemUtils _operatingSystemUtils;
  void build() {
    final defaultTargetPlatform = (_operatingSystemUtils.hostPlatform == HostPlatform.windows_arm64)
        ? 'windows-arm64'
        : 'windows-x64';
    final targetPlatform = TargetPlatform.fromName(defaultTargetPlatform);
  }
}
'''


@unittest.skipUnless(shutil.which('pwsh'), 'PowerShell is required for the Windows SDK adapter')
class Arm64SdkAdapterTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.sdk = Path(self.directory.name)
        self.engine = self.sdk / 'bin/internal/engine.version'
        self.engine.parent.mkdir(parents=True)
        self.engine.write_text('89c39edfdfae2949f6806e4a315c0c08522238b7', encoding='utf-8')
        self.command = self.sdk / 'packages/flutter_tools/lib/src/commands/build_windows.dart'
        self.command.parent.mkdir(parents=True)
        self.command.write_text(SOURCE, encoding='utf-8', newline='\n')

    def run_adapter(self):
        return subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'tool/enable-windows-arm64-sdk.ps1'),
                               '-FlutterRoot', str(self.sdk)], capture_output=True, text=True,
                              timeout=30, env=dict(os.environ, NO_COLOR='1'))

    def test_fresh_sdk_accepts_lf_and_crlf_and_reapplication_keeps_snapshot(self):
        for ending in ('\n', '\r\n'):
            with self.subTest(newline=repr(ending)):
                self.command.write_bytes(SOURCE.replace('\n', ending).encode())
                result = self.run_adapter()
                self.assertEqual(result.returncode, 0, result.stderr)
                adapted = self.command.read_bytes()
                self.assertIn(b"stringArg('target-platform')", adapted)
                self.assertNotIn(b'_operatingSystemUtils', adapted)
                self.assertNotIn(b'\r', adapted)
                snapshot = self.sdk / 'bin/cache/flutter_tools.snapshot'
                snapshot.parent.mkdir(exist_ok=True)
                snapshot.write_bytes(b'compiled-after-adaptation')
                result = self.run_adapter()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.command.read_bytes(), adapted)
                self.assertEqual(snapshot.read_bytes(), b'compiled-after-adaptation')

    def test_unknown_engine_keeps_source_untouched(self):
        self.engine.write_text('unknown', encoding='utf-8')
        before = self.command.read_bytes()
        self.assertNotEqual(self.run_adapter().returncode, 0)
        self.assertEqual(self.command.read_bytes(), before)

    def test_unknown_source_keeps_source_untouched(self):
        self.command.write_text('unexpected SDK implementation', encoding='utf-8')
        before = self.command.read_bytes()
        self.assertNotEqual(self.run_adapter().returncode, 0)
        self.assertEqual(self.command.read_bytes(), before)
