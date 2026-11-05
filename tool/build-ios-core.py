"""Build the download core's C ABI for iPhone and ARM64 iOS Simulator."""
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
output = root / 'native/bin/ios'
output.mkdir(parents=True, exist_ok=True)
frameworks = []
for sdk, target in [('iphoneos', 'arm64-apple-ios13.0'),
                    ('iphonesimulator', 'arm64-apple-ios13.0-simulator')]:
    folder = output / sdk
    bundle = folder / 'AsterLinkCore.framework'
    headers = bundle / 'Headers'
    headers.mkdir(parents=True, exist_ok=True)
    sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    compiler = subprocess.check_output(['xcrun', '--sdk', sdk, '--find', 'clang'], text=True).strip()
    wrapper = folder / 'clang-ios'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(compiler) + ' -target ' + shlex.quote(target) +
                       ' -isysroot ' + shlex.quote(sdk_path) + ' "$@"\n')
    wrapper.chmod(0o755)
    library = folder / 'libAsterLinkCore.a'
    subprocess.run(['go', 'build', '-mod=vendor', '-tags', 'nosqlite', '-trimpath',
                    '-buildmode=c-archive', '-ldflags=-s -w -checklinkname=0',
                    '-o', str(library), './cmd/ios'], cwd=root / 'native/gopeed',
                   env={**os.environ, 'GOOS': 'ios', 'GOARCH': 'arm64',
                        'DARWIN_SDK': sdk, 'CGO_ENABLED': '1', 'CC': str(wrapper),
                        'CGO_CFLAGS': '-target ' + target + ' -isysroot ' + shlex.quote(sdk_path),
                        'CGO_LDFLAGS': '-target ' + target + ' -isysroot ' + shlex.quote(sdk_path)}, check=True)
    (headers / 'AsterLinkCore.h').write_bytes(library.with_suffix('.h').read_bytes())
    modules = bundle / 'Modules'
    modules.mkdir(exist_ok=True)
    (modules / 'module.modulemap').write_text(
        'framework module AsterLinkCore { umbrella header "AsterLinkCore.h" export * }\n')
    shutil.copy2(library, bundle / 'AsterLinkCore')
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.asterlink.core', 'CFBundleExecutable': 'AsterLinkCore',
        'CFBundlePackageType': 'FMWK', 'CFBundleShortVersionString': '1.0.0',
        'CFBundleVersion': '1', 'MinimumOSVersion': '13.0',
        'CFBundleSupportedPlatforms': ['iPhoneOS' if sdk == 'iphoneos' else 'iPhoneSimulator'],
    }))
    frameworks.extend(['-framework', str(bundle)])
framework = root / 'ios/Core/AsterLinkCore.xcframework'
if framework.exists():
    # This is solely the generated framework under the workspace.
    assert framework.resolve().parent == (root / 'ios/Core').resolve()
    shutil.rmtree(framework)
subprocess.run(['xcodebuild', '-create-xcframework', *frameworks, '-output', str(framework)], check=True)
metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
assert len(metadata['AvailableLibraries']) == 2
print('iOS download core ready: ARM64 device and simulator')
