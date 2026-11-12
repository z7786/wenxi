import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HASH = '5bea5af5215089d97749d438351d7288310d0b8a472616edbe1b34168ad1001c'


@unittest.skipUnless(shutil.which('cmake'), 'CMake is required for installation regression')
class PlayerExtractorInstallTest(unittest.TestCase):
    def test_runtime_install_contains_verified_extractor_only_on_x64(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            for arch in ('x64', 'arm64'):
                source = temporary / arch
                source.mkdir()
                installed = source / 'runtime'
                (source / 'CMakeLists.txt').write_text(
                    'cmake_minimum_required(VERSION 3.14)\n'
                    'project(extractor_install NONE)\n'
                    f'set(FLUTTER_TARGET_PLATFORM "windows-{arch}")\n'
                    f'set(INSTALL_BUNDLE_LIB_DIR "{installed.as_posix()}")\n'
                    f'include("{(ROOT / "windows/player_extractor.cmake").as_posix()}")\n',
                    encoding='utf-8',
                )
                subprocess.run(['cmake', '-S', str(source), '-B', str(source / 'build')],
                               check=True, capture_output=True)
                subprocess.run(['cmake', '--install', str(source / 'build'), '--component', 'Runtime'],
                               check=True, capture_output=True)
                executable = installed / 'tools/player-7za.exe'
                if arch == 'x64':
                    self.assertEqual(hashlib.sha256(executable.read_bytes()).hexdigest(), HASH)
                else:
                    self.assertFalse(executable.exists())


@unittest.skipUnless(__import__('os').name == 'nt', 'Windows executable requires Windows')
class PlayerExtractorRunTest(unittest.TestCase):
    def test_shipped_extractor_unpacks_the_real_full_component(self):
        with tempfile.TemporaryDirectory(prefix='player extractor ') as directory:
            temporary = Path(directory)
            tool = temporary / 'tools/player-7za.exe'
            tool.parent.mkdir()
            shutil.copyfile(ROOT / 'native/third_party/player-7za-x64-26.01.bin', tool)
            archive = ROOT / 'native/third_party/mpv-dev-x86_64-20261108-git-8bc468896e.7z'
            extracted = temporary / 'runtime'
            result = subprocess.run([str(tool), 'e', str(archive), '-o' + str(extracted),
                                     'libmpv-2.dll', '-r', '-y', '-bd'],
                                    capture_output=True, timeout=120)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(hashlib.sha256((extracted / 'libmpv-2.dll').read_bytes()).hexdigest(),
                             '7eb6d202bb3aa5d311aef32d6f56543fc160d1d3e976667ab99e2503e3ca5b57')


if __name__ == '__main__':
    unittest.main()
