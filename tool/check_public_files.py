"""Check Git's public file selection without displaying credential values.

No repository is required for a worktree check. --staged reads Git blobs rather
than the working copy, so a staged secret cannot be hidden by a later edit.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile

MAX_FILE_BYTES = 100 * 1024 * 1024
PRIVATE_ROOTS = {
    '.local', '.dart_tool', '.idea', 'logs', 'outputs', 'logo', 'releases',
    'caiiliao', 'build', 'coverage', 'dist', '\u6f14\u793a\u622a\u56fe',
    'backend', 'wwwroot', '5.com', '.claude',
}
PRIVATE_DIRECTORIES = {'tool/password_updater', 'tool/demo'}
PRIVATE_FILES = {
    'control.json', 'config.fixed.json', 'LanzouAPI-master.zip',
    'announcements.json', '\u516c\u544a\u7f16\u8f91\u5668.html',
    'tool/announcement-editor.test.cjs', '\u4ea4\u4e92.txt',
    'tool/DISK_CLEANUP_PANEL.md', 'tool/disk_cleanup_panel.py',
    'tool/run_disk_cleanup_panel.cmd',
    'docs/CLOUD-PROVIDERS-2026-09-24.md',
    'docs/OPENLIST-CLOUDS-SMS-2026-09-24.md',
    'docs/QUARK-AUTHENTICATED-DIRECT-DOWNLOAD.md',
    'native/gopeed/internal/protocol/http/build.data',
    'native/gopeed/internal/protocol/http/download.data',
    '\u542f\u52a8\u5bc6\u7801\u66f4\u65b0\u5668.cmd',
    'tool/source_runner.dart', 'tool/build-source-runtime.ps1',
    'tool/tests/source_live_smoke.dart',
    'docs/SOURCE-RUNTIME-DEPLOYMENT.md',
    'docs/REMOTE-SOURCE-VERIFICATION.md',
}
PATTERNS = {
    'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----'),
    'github-token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'aws-access-key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'jwt': re.compile(rb'\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{24,}\b'),
    'credential-in-url': re.compile(rb'https?://[^\s/@:\'"]{2,}:[^\s/@\'"]{8,}@'),
}


def git(command, args, **kwargs):
    return subprocess.run(command + args, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs).stdout


@contextlib.contextmanager
def git_context(root, staged=False):
    command = ['git', '-c', 'core.excludesFile=' + os.devnull]
    if (root / '.git').exists():
        yield command + ['-C', str(root)]
    elif staged:
        raise ValueError('--staged requires a Git repository at the project root')
    else:
        with tempfile.TemporaryDirectory(prefix='asterlink-public-index-') as temp:
            git(command, ['init', '--bare', '--quiet', temp])
            yield command + ['--git-dir=' + temp, '--work-tree=' + str(root)]


def selected_files(command, staged):
    if staged:
        result = []
        for record in git(command, ['ls-files', '--stage', '-z']).split(b'\0'):
            if not record:
                continue
            metadata, name = record.split(b'\t', 1)
            mode, oid, stage = metadata.decode('ascii').split()
            if stage != '0':
                raise ValueError('Resolve the index conflicts before checking public files')
            result.append((os.fsdecode(name), mode, oid))
        return sorted(result)
    data = git(command, ['ls-files', '--cached', '--others', '--exclude-standard', '-z'])
    return [(name, None, None) for name in sorted({os.fsdecode(n) for n in data.split(b'\0') if n})]


def path_issue(name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name:
        return 'unsafe-path'
    if path.parts[0].lower() in PRIVATE_ROOTS or name in PRIVATE_FILES:
        return 'private-or-generated-path'
    if any(name.casefold() == directory or name.casefold().startswith(directory + '/')
           for directory in PRIVATE_DIRECTORIES):
        return 'private-or-generated-path'
    if len(path.parts) == 1 and re.fullmatch(r'config-\d[^/]*\.json', name, re.I):
        return 'local-release-configuration'
    if len(path.parts) == 1 and path.suffix.lower() == '.zip':
        return 'local-archive'
    if path.name in {'keystore.properties', 'key.properties', 'local.properties'}:
        return 'local-configuration'
    if path.suffix.lower() in {
        '.jks', '.keystore', '.p12', '.pfx', '.apk', '.aab',
        '.exe', '.msi', '.msix', '.msixbundle',
    }:
        return 'credentials-or-release-binary'
    if path.suffix.lower() in {'.har', '.pcap', '.pcapng'}:
        return 'network-capture'
    if (path.name == '.env' or path.name.startswith('.env.')) and not path.name.endswith('.example'):
        return 'environment-file'
    if name.startswith('android/app/libs/') and path.suffix in {'.aar', '.jar'}:
        return 'generated-native-library'
    if name.startswith('native/bin/') or name.startswith('native/.tools/'):
        return 'generated-native-library'
    if name.startswith('docs/') and path.suffix == '.json' and name != 'docs/kotlin-baseline-sha256.json':
        return 'local-inspection-report'
    if re.search(r'(?:^|/)[^/]*-backup-[^/]*\.json$', name, re.I):
        return 'account-backup'
    return None


def scan_content(data):
    if b'\0' in data[:8192]:
        return []
    findings = []
    json_data = data[3:] if data.startswith(b'\xef\xbb\xbf') else data
    if json_data.lstrip().startswith(b'{'):
        try:
            document = json.loads(data)
            format_name = document.get('format') if isinstance(document, dict) else None
            if isinstance(format_name, str) and format_name in {'asterlink-backup-v1', 'wenxi-backup-v1'}:
                findings.append(('account-backup-content', 1))
        except (ValueError, UnicodeError):
            pass
    for name, pattern in PATTERNS.items():
        for match in pattern.finditer(data):
            findings.append((name, data[:match.start()].count(b'\n') + 1))
    return findings


def check(root, staged=False, export=None, manifest=None):
    root = Path(root).resolve()
    findings, entries = [], []
    with git_context(root, staged) as command:
        files = selected_files(command, staged)
        allowlist_path = root / 'tool/public-fixtures.json'
        if staged:
            allowed_blob = next((oid for name, mode, oid in files if name == 'tool/public-fixtures.json'), None)
            allowlist = json.loads(git(command, ['cat-file', 'blob', allowed_blob])) if allowed_blob else {}
        else:
            allowlist = json.loads(allowlist_path.read_text(encoding='utf-8')) if allowlist_path.exists() else {}
        process = subprocess.Popen(command + ['cat-file', '--batch'], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE) if staged else None
        try:
            for name, mode, oid in files:
                problem = path_issue(name)
                if problem:
                    findings.append({'path': name, 'rule': problem})
                    continue
                path = root / name
                if mode not in (None, '100644', '100755') or path.is_symlink():
                    findings.append({'path': name, 'rule': 'link-or-submodule-needs-review'})
                    continue
                if not staged and not path.is_file():
                    continue
                if not staged and (root not in path.resolve().parents):
                    findings.append({'path': name, 'rule': 'path-outside-project'})
                    continue
                if staged:
                    process.stdin.write(oid.encode('ascii') + b'\n')
                    process.stdin.flush()
                    header = process.stdout.readline().split()
                    if len(header) != 3 or header[1] != b'blob':
                        raise ValueError('Unable to read a staged blob')
                    size = int(header[2])
                    if size > MAX_FILE_BYTES:
                        findings.append({'path': name, 'rule': 'over-100-MiB'})
                        # Drain the blob without loading an oversized file in memory.
                        remaining = size + 1
                        while remaining:
                            block = process.stdout.read(min(remaining, 1024 * 1024))
                            if not block:
                                raise ValueError('Truncated oversized staged blob')
                            remaining -= len(block)
                        continue
                    data = process.stdout.read(size)
                    if len(data) != size or process.stdout.read(1) != b'\n':
                        raise ValueError('Truncated staged blob')
                else:
                    size = path.stat().st_size
                    if size > MAX_FILE_BYTES:
                        findings.append({'path': name, 'rule': 'over-100-MiB'})
                        continue
                    data = path.read_bytes()
                digest = hashlib.sha256(data).hexdigest()
                reviewed = allowlist.get(name, {})
                matches = scan_content(data)
                fixture_digest = hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()
                for rule, line in matches:
                    approved = reviewed.get('sha256') == fixture_digest
                    if rule == 'account-backup-content':
                        approved = (approved and name.startswith('test/fixtures/')
                                    and rule in reviewed.get('rules', []))
                    if not approved:
                        findings.append({'path': name, 'rule': rule, 'line': line})
                entries.append({'path': name, 'bytes': size, 'sha256': digest})
        finally:
            if process:
                process.stdin.close()
                process.stdout.close()
                process.stderr.close()
                process.wait(timeout=10)
    report = {
        'passed': not findings,
        'mode': 'staged' if staged else 'worktree',
        'files': len(entries),
        'bytes': sum(entry['bytes'] for entry in entries),
        'findings': findings,
    }
    if manifest:
        target = Path(manifest).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps({**report, 'entries': entries}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if export:
        if staged:
            raise ValueError('Use git archive to export committed/staged sources')
        if findings:
            raise ValueError('Public file check failed; no export was created')
        target = Path(export).resolve()
        if target == root or target in root.parents or target.exists():
            raise ValueError('Export destination must be a new directory')
        # All input bytes are checked before any files are copied.
        target.mkdir(parents=True)
        for entry in entries:
            source = root / entry['path']
            destination = target / entry['path']
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            if hashlib.sha256(destination.read_bytes()).hexdigest() != entry['sha256']:
                raise ValueError('A source changed during export; discard this export and retry')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--staged', action='store_true')
    parser.add_argument('--export', help='Copy only checked public files to a new directory')
    parser.add_argument('--manifest', help='Save file names and hashes, never file contents')
    args = parser.parse_args()
    try:
        report = check(args.root, args.staged, args.export, args.manifest)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, 'Public file check failed: ' + str(error) + '\n')
    print(json.dumps(report, ensure_ascii=True, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
