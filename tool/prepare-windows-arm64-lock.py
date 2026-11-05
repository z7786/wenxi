"""Adapt only packages pinned by the isolated Flutter 3.47.9 SDK."""
import argparse
from pathlib import Path
import re

ENGINE = '89c39edfdfae2949f6806e4a315c0c08522238b7'
PACKAGES = {
    'intl': ('0.20.3', '1ca20c894b1717686a2319b8548763d812bc0aabdac580420a44c5178c57a867'),
    'matcher': ('0.12.20', '31bd099b47c10cd1aeb55146a2d46ce0277630ecef3f7dae54ad7873f36696cd'),
    'meta': ('1.19.0', '307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9'),
    'test_api': ('0.7.12', '2a122cbe059f8b610d3a5415f42e255b6c17b1f21eee1d960f31080237fb4f11'),
    'vector_math': ('2.4.4', 'fa49e1674cb84acb900141714e6c6e1f9ae099827c24d141430ff6819db4e1bc'),
}


def prepare(root, sdk):
    root, sdk = Path(root), Path(sdk)
    if (sdk / 'bin/internal/engine.version').read_text(encoding='utf-8').strip() != ENGINE:
        raise ValueError('ARM64 lock adaptation requires the pinned Flutter 3.47.9 engine')
    path = root / 'pubspec.lock'
    text = path.read_text(encoding='utf-8')
    for name, (version, digest) in PACKAGES.items():
        pattern = r'(?m)^  ' + name + r':\n(?:(?:    .*|)\n)+'
        match = re.search(pattern, text)
        if not match or 'source: hosted' not in match[0] or 'https://pub.flutter-io.cn' not in match[0]:
            raise ValueError('Unexpected SDK package entry: ' + name)
        block = re.sub(r'(?m)^      sha256:.*$', '      sha256: "' + digest + '"', match[0])
        block = re.sub(r'(?m)^    version:.*$', '    version: "' + version + '"', block)
        text = text[:match.start()] + block + text[match.end():]
    path.write_text(text, encoding='utf-8', newline='\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--sdk', required=True)
    args = parser.parse_args()
    prepare(args.root, args.sdk)
    print('Prepared the five pinned ARM64 SDK companion packages.')
