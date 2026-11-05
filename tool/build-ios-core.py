"""Build the download core's C ABI for iPhone and ARM64 iOS Simulator."""
import os
from pathlib import Path
import plistlib
import shlex
import subprocess

root = Path(__file__).resolve().parent.parent
output = root / 'native/bin/ios'
output.mkdir(parents=True, exist_ok=True)
libraries = []
for sdk, target in [('iphoneos', 'arm64-apple-ios13.0'),
                    ('iphonesimulator', 'arm64-apple-ios13.0-simulator')]:
    folder = output / sdk
    headers = folder / 'Headers'
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
                        'CGO_ENABLED': '1', 'CC': str(wrapper)}, check=True)
    (headers / 'AsterLinkCore.h').write_bytes(library.with_suffix('.h').read_bytes())
    (headers / 'module.modulemap').write_text(
        'module AsterLinkCore { header "AsterLinkCore.h" export * }\n')
    libraries.extend(['-library', str(library), '-headers', str(headers)])
framework = root / 'ios/Core/AsterLinkCore.xcframework'
if framework.exists():
    # This is solely the generated framework under the workspace.
    import shutil
    assert framework.resolve().parent == (root / 'ios/Core').resolve()
    shutil.rmtree(framework)
subprocess.run(['xcodebuild', '-create-xcframework', *libraries, '-output', str(framework)], check=True)
metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
assert len(metadata['AvailableLibraries']) == 2
print('iOS download core ready: ARM64 device and simulator')
