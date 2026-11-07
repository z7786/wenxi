"""Inspect a macOS app and package an ARM64 or Intel x64 test DMG."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


ARCHITECTURES = {'arm64': 'arm64', 'x64': 'x86_64'}


def inspect(app, architecture='arm64'):
    if architecture not in ARCHITECTURES:
        raise ValueError('Unsupported macOS architecture: ' + architecture)
    native_architecture = ARCHITECTURES[architecture]
    app = Path(app).resolve()
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    root = Path(__file__).resolve().parent.parent
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                        (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    assert metadata['CFBundleShortVersionString'] == version[1]
    assert metadata['CFBundleVersion'] == version[2]
    assert metadata['CFBundleIdentifier'] == 'com.asterlink.app'
    helper = app / 'Contents/MacOS/asterlink_gopeed'
    assert helper.is_file()
    executable = app / 'Contents/MacOS' / metadata['CFBundleExecutable']
    for binary in [helper, executable]:
        assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split() == [native_architecture], str(binary)
    native = []
    for file in app.rglob('*'):
        if not file.is_file():
            continue
        assert app in file.resolve().parents, 'App bundle symlink escapes the bundle'
        relative = file.relative_to(app)
        assert not {'.local', 'logs', 'diagnostics', '.git'} & set(relative.parts)
        assert file.suffix.lower() not in {'.jks', '.keystore', '.p12', '.pfx', '.pem', '.log'}
        with file.open('rb') as stream:
            magic = stream.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
            continue
        architectures = subprocess.check_output(['lipo', '-archs', str(file)], text=True).split()
        assert native_architecture in architectures, str(relative)
        native.append(relative.as_posix())
    assert native and 'Contents/MacOS/asterlink_gopeed' in native
    runtime = app / 'Contents/Frameworks/asterlink_js.framework/asterlink_js'
    assert runtime.is_file(), 'Missing parser script runtime'
    symbols = subprocess.check_output(['nm', '-gU', str(runtime)], text=True)
    for symbol in ['al_js_new', 'al_js_begin', 'al_js_poll', 'al_js_reply', 'al_js_free_text', 'al_js_close']:
        assert '_' + symbol in symbols, 'Missing parser runtime symbol: ' + symbol
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return {'passed': True, 'architecture': architecture, 'version': version[1] + '+' + version[2],
            'nativeBinaries': native, 'developerIdSigned': False, 'notarized': False}


def package(app, output, architecture='arm64'):
    report = inspect(app, architecture)
    app = Path(app).resolve()
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    name = 'asterlink-' + report['version'] + '-macos-' + architecture + '-test'
    dmg = output / (name + '.dmg')
    archive = output / (name + '.zip')
    assert not dmg.exists() and not archive.exists(), 'Staged package already exists'
    with tempfile.TemporaryDirectory(prefix='asterlink-dmg-') as temporary:
        staging = Path(temporary)
        subprocess.run(['ditto', str(app), str(staging / app.name)], check=True)
        (staging / 'Applications').symlink_to('/Applications', target_is_directory=True)
        processor = 'Intel x64' if architecture == 'x64' else '苹果芯片 ARM64'
        (staging / '安装说明.txt').write_text(
            '将文析助手拖到 Applications。\n此包用于 macOS ' + processor + ' 测试，尚未完成 Developer ID 签名和苹果公证。\n',
            encoding='utf-8')
        subprocess.run(['hdiutil', 'create', '-volname', '文析助手', '-srcfolder', str(staging),
                        '-ov', '-format', 'UDZO', str(dmg)], check=True)
    subprocess.run(['hdiutil', 'verify', str(dmg)], check=True)
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
    files = [dmg, archive]
    hashes = {file.name: {'bytes': file.stat().st_size,
                         'sha256': hashlib.sha256(file.read_bytes()).hexdigest()} for file in files}
    (output / 'SHA256SUMS.txt').write_text(''.join(hashes[name]['sha256'] + '  ' + name + '\n'
                                               for name in sorted(hashes)), encoding='utf-8')
    report['assets'] = hashes
    report_path = Path(__file__).resolve().parent.parent / ('.local/macos-' + architecture + '-inspection.json')
    report_path.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({'passed': True, 'architecture': architecture, 'assets': hashes}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True)
    parser.add_argument('--output', default='.local/macos-release-assets')
    parser.add_argument('--architecture', choices=tuple(ARCHITECTURES), default='arm64')
    args = parser.parse_args()
    package(args.app, args.output, args.architecture)
