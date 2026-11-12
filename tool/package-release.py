"""Stage release assets with predictable names; keep reports and caches private."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import zipfile


def version_of(root):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+\+[1-9]\d*)\s*$',
                      (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    if not match:
        raise ValueError('Invalid project version')
    return match.group(1)


def stage(root, platform, installer=None, architecture='x64'):
    if platform not in {'android', 'windows'} or architecture not in {'x64', 'arm64'}:
        raise ValueError('Unsupported release platform or architecture')
    root = Path(root).resolve()
    version = version_of(root)
    output = root / '.local/release-assets'
    output.mkdir(parents=True, exist_ok=True)
    if platform == 'android':
        source = root / 'build/app/outputs/flutter-apk/app-release.apk'
        destination = output / ('asterlink-' + version + '-android-arm64.apk')
        if not source.is_file() or destination.exists():
            raise ValueError('APK is missing or a staged asset already exists')
        shutil.copy2(source, destination)
    else:
        runtime = root / ('build/windows/' + architecture + '/runner/Release')
        for name in ('asterlink.exe', 'asterlink_gopeed.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so'):
            if not (runtime / name).is_file():
                raise ValueError('Windows runtime is incomplete')
        if architecture == 'x64':
            extractor = runtime / 'tools/player-7za.exe'
            if not extractor.is_file():
                raise ValueError('Windows runtime is missing the player component extractor')
            if (extractor.stat().st_size != 1335296 or
                    hashlib.sha256(extractor.read_bytes()).hexdigest() !=
                    '5bea5af5215089d97749d438351d7288310d0b8a472616edbe1b34168ad1001c'):
                raise ValueError('Windows player component extractor did not verify')
        files = sorted(p for p in runtime.rglob('*') if p.is_file())
        for path in files:
            relative = path.relative_to(runtime)
            if re.match(r'(?i)^(fvp|mdk(?:-(?:braw|r3d))?|ffmpeg-9|libass)\.dll$', path.name):
                raise ValueError('Windows runtime contains a removed player library')
            if path.is_symlink() or runtime.resolve() not in path.resolve().parents:
                raise ValueError('Windows runtime contains a link')
            if any(part in {'.local', '.git', 'logs', 'diagnostics'} for part in relative.parts) or path.suffix in {'.jks', '.keystore', '.p12', '.pfx', '.log', '.pdb'}:
                raise ValueError('Windows runtime contains private or development files')
        destination = output / ('asterlink-' + version + '-windows-' + architecture + '.zip')
        if destination.exists():
            raise ValueError('A staged Windows asset already exists')
        with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                archive.write(path, path.relative_to(runtime).as_posix())
        if installer:
            source = Path(installer).resolve()
            if not source.is_file() or source.suffix.lower() != '.exe':
                raise ValueError('Installer must be an existing EXE')
            target = output / ('asterlink-' + version + '-windows-' + architecture + '-setup.exe')
            if target.exists():
                raise ValueError('A staged installer already exists')
            shutil.copy2(source, target)
    return output


def checksums(directory):
    directory = Path(directory)
    files = sorted(p for p in directory.iterdir() if p.is_file() and p.suffix.lower() in {'.apk', '.exe', '.zip'})
    if not files:
        raise ValueError('No release assets were found')
    records = []
    for path in files:
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        records.append(digest.hexdigest() + '  ' + path.name)
    (directory / 'SHA256SUMS.txt').write_text('\n'.join(records) + '\n', encoding='utf-8')
    return len(files)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('android', 'windows'))
    parser.add_argument('--installer')
    parser.add_argument('--architecture', choices=('x64', 'arm64'), default='x64')
    parser.add_argument('--checksums', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        if args.platform:
            stage(root, args.platform, args.installer, args.architecture)
            print('Release assets staged for ' + args.platform)
        if args.checksums:
            print('SHA-256 written for {} assets'.format(checksums(root / '.local/release-assets')))
        if not args.platform and not args.checksums:
            raise ValueError('Choose --platform or --checksums')
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
