"""Inspect and archive an unsigned ARM64 iOS device app for later signing."""
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
app = root / 'build/ios/iphoneos/Runner.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.asterlink.app'
assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
expected = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                     (root / 'pubspec.yaml').read_text(), re.MULTILINE)
assert expected and info['CFBundleShortVersionString'] == expected[1] and info['CFBundleVersion'] == expected[2]
binary = app / info['CFBundleExecutable']
arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
assert arch == 'arm64', arch
assert (app / 'Frameworks/Mpv.framework/Mpv').is_file()
assert (app / 'Frameworks/asterlink_js.framework/asterlink_js').is_file()
assert not (app / 'embedded.mobileprovision').exists()
for path in app.rglob('*'):
    assert path.name not in {'.local', '.env', 'build-config.json', 'baidu-api.defines.json', 'parser-hub.defines.json'}
version = info['CFBundleShortVersionString'] + '+' + info['CFBundleVersion']
destination = root / '.local/ios-release-assets'
destination.mkdir(parents=True, exist_ok=True)
ipa = destination / f'asterlink-{version}-ios-arm64-unsigned.ipa'
with zipfile.ZipFile(ipa, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for path in sorted(app.rglob('*')):
        if path.is_file():
            archive.write(path, Path('Payload/Runner.app') / path.relative_to(app))
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(destination / 'SHA256SUMS.txt').write_text(f'{digest}  {ipa.name}\n')
(destination / 'README.txt').write_text(
    'Unsigned iOS ARM64 test build. Requires Apple code signing before installation.\n'
    'This file cannot be installed directly or uploaded to TestFlight without signing.\n')
print(f'Verified unsigned device app: {version}, {arch}, native player and script runtime')
