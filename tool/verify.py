"""Run scoped local verification without publishing or changing dependencies."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def test_targets(root, targets, *, diagnostic=False):
    """Validate every explicit target before starting any processes."""
    # Windows TEMP may use an 8.3 alias; compare both sides after resolving it.
    root = Path(root).resolve()
    selected = []
    for value in targets:
        path = (root / value).resolve()
        if root != path and root not in path.parents:
            raise ValueError('Test targets must stay inside the project')
        relative = path.relative_to(root)
        if not relative.parts or relative.parts[0] not in {'test', 'tool'}:
            raise ValueError('Test targets must be under test/ or tool/')
        diagnostic_root = root / 'tool/diagnostics'
        in_diagnostics = path == diagnostic_root or diagnostic_root in path.parents
        if diagnostic and not in_diagnostics:
            raise ValueError('Diagnostic targets must be under tool/diagnostics/')
        if not diagnostic and (in_diagnostics or path in diagnostic_root.parents):
            raise ValueError('Use the diagnostic scope explicitly for tool/diagnostics/')
        if path.is_dir():
            if not any(path.rglob('*_test.dart')):
                raise ValueError(f'No Flutter tests in {relative.as_posix()}')
        elif not path.is_file() or not path.name.endswith('_test.dart'):
            raise ValueError(f'Not a Flutter test: {relative.as_posix()}')
        name = relative.as_posix()
        if name not in selected:
            selected.append(name)
    if not selected:
        raise ValueError('Choose test files explicitly, or use full')
    return selected


def plan(root, args):
    steps = []
    if args.scope in {'source', 'full'}:
        steps.extend([
            ('Public files', [sys.executable, 'tool/check_public_files.py',
                              *(['--staged'] if args.staged else [])]),
            ('Version', ['dart', 'tool/sync_version.dart', '--check']),
            ('Documentation links', [sys.executable, 'tool/check_project_docs.py']),
            ('Tool regressions', [sys.executable, '-m', 'unittest', 'discover',
                                  '-s', 'tool/tests', '-p', 'test_*.py']),
            ('Flutter analysis', ['flutter', 'analyze', '--no-pub']),
        ])
    if args.scope in {'test', 'diagnostic', 'full'}:
        targets = (test_targets(root, args.targets, diagnostic=args.scope == 'diagnostic')
                   if args.scope != 'full' else ['test'])
        steps.append(('Flutter tests', [
            'flutter', 'test', '--no-pub', f'--concurrency={args.concurrency}',
            '--reporter=expanded', *targets,
        ]))
    return steps


def run_plan(root, steps, *, diagnostic=False):
    """Stop on the first error and keep a private, metadata-only run record."""
    started = datetime.now(timezone.utc)
    report = {'startedAt': started.isoformat(), 'passed': False,
              'diagnostic': diagnostic, 'steps': []}
    environment = dict(os.environ)
    # Inherited opt-in variables cannot silently activate private diagnostics.
    if diagnostic:
        environment['ASTERLINK_DIAGNOSTICS'] = '1'
    else:
        environment.pop('ASTERLINK_DIAGNOSTICS', None)
    output = root / '.local/verification'
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / (started.strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8] + '.json')
    try:
        for name, command in steps:
            print(f'\n{name}: {subprocess.list2cmdline(command)}', flush=True)
            record = {'name': name, 'command': command, 'exitCode': None}
            report['steps'].append(record)
            began = time.monotonic()
            try:
                executable = shutil.which(command[0])
                if executable is None:
                    raise FileNotFoundError(f'Required tool not found: {command[0]}')
                result = subprocess.run([executable, *command[1:]], cwd=root,
                                        env=environment, check=False)
                record['exitCode'] = result.returncode
            except OSError as error:
                record['error'] = str(error)
                print(error, file=sys.stderr)
                return 1
            finally:
                record['seconds'] = round(time.monotonic() - began, 3)
            if result.returncode:
                print(f'Failed: {name}; remaining steps were not run.', file=sys.stderr)
                return result.returncode if result.returncode > 0 else 1
        report['passed'] = True
        print('\nSelected checks passed. Native/device checks and skipped tests require separate review.')
        return 0
    except KeyboardInterrupt:
        report['interrupted'] = True
        return 130
    finally:
        report['finishedAt'] = datetime.now(timezone.utc).isoformat()
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(f'Run record: {report_path}', flush=True)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    scopes = parser.add_subparsers(dest='scope', required=True)
    for scope, description in (
        ('source', 'Public files, versions, docs, tooling tests and analysis'),
        ('test', 'Only the explicitly selected Flutter tests'),
        ('diagnostic', 'Explicit private replay/network diagnostics under tool/diagnostics/'),
        ('full', 'Source checks followed by all tests under test/'),
    ):
        command = scopes.add_parser(scope, help=description)
        command.add_argument('--dry-run', action='store_true', help='Print commands without running or writing files')
        if scope in {'source', 'full'}:
            command.add_argument('--staged', action='store_true', help='Check public file contents from the Git index')
        if scope in {'test', 'diagnostic', 'full'}:
            command.add_argument('--concurrency', type=int, default=4, choices=range(1, 33), metavar='1..32')
        if scope in {'test', 'diagnostic'}:
            command.add_argument('targets', nargs='+', help='Paths relative to project root')
    return parser.parse_args(argv)


def main(argv=None):
    if sys.version_info < (3, 10):
        print('Python 3.10+ is required by the project tooling. On Windows use: py -3 tool/verify.py <scope> ...', file=sys.stderr)
        return 1
    args = parse_args(argv)
    try:
        steps = plan(ROOT, args)
        if args.dry_run:
            for name, command in steps:
                print(f'{name}: {subprocess.list2cmdline(command)}')
            return 0
        return run_plan(ROOT, steps, diagnostic=args.scope == 'diagnostic')
    except (ValueError, OSError) as error:
        print(f'Verification failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
