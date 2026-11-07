import importlib.util
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('macos_package', ROOT / 'tool/package-macos.py')
macos_package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(macos_package)


class MacosPackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = (Path(self.temporary.name) / 'AsterLink.app').resolve()
        contents = self.app / 'Contents'
        contents.mkdir(parents=True)
        version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                            (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': version[1],
            'CFBundleVersion': version[2],
            'CFBundleIdentifier': 'com.asterlink.app',
            'CFBundleExecutable': 'AsterLink',
        }))
        self.binaries = [
            contents / 'MacOS/AsterLink',
            contents / 'MacOS/asterlink_gopeed',
            contents / 'Frameworks/asterlink_js.framework/asterlink_js',
            contents / 'Frameworks/FlutterMacOS.framework/FlutterMacOS',
            contents / 'Frameworks/libmpv.framework/libmpv',
        ]
        for binary in self.binaries:
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')

    def inspect(self, architecture, overrides=None):
        expected = macos_package.ARCHITECTURES[architecture]
        overrides = overrides or {}

        def output(arguments, **_):
            if arguments[0] == 'lipo':
                path = Path(arguments[-1]).relative_to(self.app).as_posix()
                return overrides.get(path, expected)
            self.assertEqual(arguments[:2], ['nm', '-gU'])
            return '\n'.join('_' + name for name in [
                'al_js_new', 'al_js_begin', 'al_js_poll',
                'al_js_reply', 'al_js_free_text', 'al_js_close',
            ])

        with patch.object(macos_package.subprocess, 'check_output', side_effect=output), \
                patch.object(macos_package.subprocess, 'run'):
            return macos_package.inspect(self.app, architecture)

    def test_both_architectures_include_download_parser_and_video_runtimes(self):
        for architecture in ('arm64', 'x64'):
            with self.subTest(architecture=architecture):
                report = self.inspect(architecture)
                self.assertEqual(report['architecture'], architecture)
                self.assertEqual(set(report['nativeBinaries']), {
                    binary.relative_to(self.app).as_posix() for binary in self.binaries
                })

    def test_intel_bundle_rejects_arm_download_helper(self):
        with self.assertRaises(AssertionError):
            self.inspect('x64', {'Contents/MacOS/asterlink_gopeed': 'arm64'})

    def test_intel_bundle_rejects_arm_video_runtime(self):
        with self.assertRaises(AssertionError):
            self.inspect('x64', {'Contents/Frameworks/libmpv.framework/libmpv': 'arm64'})

    def test_arm_bundle_rejects_intel_parser_runtime(self):
        with self.assertRaises(AssertionError):
            self.inspect('arm64', {'Contents/Frameworks/asterlink_js.framework/asterlink_js': 'x86_64'})

    def test_universal_dependencies_are_usable(self):
        report = self.inspect('x64', {
            'Contents/Frameworks/libmpv.framework/libmpv': 'x86_64 arm64',
            'Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS': 'x86_64 arm64',
        })
        self.assertTrue(report['passed'])

    def test_requested_single_architecture_executable_is_required(self):
        with self.assertRaises(AssertionError):
            self.inspect('x64', {'Contents/MacOS/AsterLink': 'x86_64 arm64'})

    def test_unsupported_architecture_is_rejected_before_reading_bundle(self):
        with self.assertRaises(ValueError):
            macos_package.inspect(Path(self.temporary.name) / 'missing.app', '../other')


if __name__ == '__main__':
    unittest.main()
