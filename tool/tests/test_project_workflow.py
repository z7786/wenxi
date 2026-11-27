import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tool' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


docs = load('check_project_docs')
verify = load('verify')


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, name, content=''):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
        return path

    def test_local_and_encoded_heading_links_ignore_remote_and_code(self):
        self.write('docs/target.md', '# 中文 标题\n## Same\n## Same\n')
        self.write('image name.png')
        self.write('README.md', '\n'.join([
            '[中文](docs/target.md#%E4%B8%AD%E6%96%87-%E6%A0%87%E9%A2%98)',
            '[重复标题](docs/target.md#same-1)',
            '![图片](<image name.png>)',
            '[外部](https://example.invalid/missing#anchor)',
            '```markdown', '[示例](missing.md)', '```',
        ]))
        self.assertEqual(docs.check(self.root, ['README.md']), [])

    def test_missing_target_anchor_and_escaping_link_fail_with_locations(self):
        self.write('docs/target.md', '# New heading\n')
        self.write('README.md', '[旧锚点](docs/target.md#old)\n[缺失](absent.md)\n[越界](../outside.md)\n')
        problems = docs.check(self.root, ['README.md'])
        self.assertEqual(len(problems), 3)
        self.assertIn('README.md:1: missing Markdown heading', problems[0])
        self.assertIn('README.md:2: missing local target', problems[1])
        self.assertIn('link leaves the project', problems[2])

    def test_missing_entry_is_an_error(self):
        self.assertIn('missing entry document', docs.check(self.root, ['AGENTS.md'])[0])

    def test_scoped_plan_only_runs_selected_tests_and_deduplicates(self):
        self.write('test/one_test.dart')
        args = verify.parse_args(['test', '--concurrency', '1', 'test/one_test.dart', 'test/one_test.dart'])
        steps = verify.plan(self.root, args)
        self.assertEqual(len(steps), 1)
        command = steps[0][1]
        self.assertEqual(command.count('test/one_test.dart'), 1)
        self.assertIn('--no-pub', command)
        self.assertIn('--concurrency=1', command)
        self.assertNotIn('--update-goldens', command)

    def test_invalid_targets_cannot_silently_run_the_full_suite(self):
        self.write('test/support.dart')
        self.write('lib/example_test.dart')
        (self.root / 'test/empty').mkdir()
        for targets in ([], ['../outside_test.dart'], ['test/missing_test.dart'],
                        ['test/support.dart'], ['lib/example_test.dart'], ['test/empty']):
            with self.subTest(targets=targets), self.assertRaises(ValueError):
                verify.test_targets(self.root, targets)

    def test_noncanonical_root_still_accepts_its_own_tests(self):
        self.write('test/one_test.dart')
        alias = self.root / 'test' / '..'
        self.assertEqual(verify.test_targets(alias, ['test/one_test.dart']),
                         ['test/one_test.dart'])
        with self.assertRaises(ValueError):
            verify.test_targets(alias, ['../outside_test.dart'])

    def test_private_diagnostics_require_the_separate_scope(self):
        self.write('tool/diagnostics/replay_test.dart')
        self.write('test/offline_test.dart')
        for path in ['tool', 'tool/diagnostics', 'tool/diagnostics/replay_test.dart']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                verify.test_targets(self.root, [path])
        with self.assertRaises(ValueError):
            verify.test_targets(self.root, ['test/offline_test.dart'], diagnostic=True)
        steps = verify.plan(self.root, verify.parse_args([
            'diagnostic', 'tool/diagnostics/replay_test.dart']))
        self.assertEqual(steps[0][1][-1], 'tool/diagnostics/replay_test.dart')

    def test_diagnostic_opt_in_is_limited_to_the_child_environment(self):
        import os
        from unittest.mock import patch
        command = [sys.executable, '-c',
                   'import os, sys; sys.exit(0 if os.environ.get("ASTERLINK_DIAGNOSTICS") == sys.argv[1] else 2)',
                   '1']
        with patch.dict(os.environ, {'ASTERLINK_DIAGNOSTICS': 'inherited'}):
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(verify.run_plan(self.root, [('opt-in', command)], diagnostic=True), 0)
                self.assertEqual(verify.run_plan(self.root, [('default', command)]), 2)
            self.assertEqual(os.environ['ASTERLINK_DIAGNOSTICS'], 'inherited')

    def test_failure_stops_later_steps_and_records_failure(self):
        marker = self.root / 'should-not-exist.txt'
        steps = [
            ('failing command', [sys.executable, '-c', 'raise SystemExit(7)']),
            ('must not run', [sys.executable, '-c', f'open({str(marker)!r}, "w").close()']),
        ]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = verify.run_plan(self.root, steps)
        self.assertEqual(result, 7)
        self.assertFalse(marker.exists())
        report = json.loads(next((self.root / '.local/verification').glob('*.json')).read_text())
        self.assertFalse(report['passed'])
        self.assertEqual(len(report['steps']), 1)
        self.assertEqual(report['steps'][0]['exitCode'], 7)

    def test_missing_tool_is_not_reported_as_success(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = verify.run_plan(self.root, [('missing', ['asterlink-nonexistent-test-tool-72819'])])
        self.assertEqual(result, 1)
        report = json.loads(next((self.root / '.local/verification').glob('*.json')).read_text())
        self.assertFalse(report['passed'])
        self.assertIn('error', report['steps'][0])

    def test_dry_run_from_another_directory_does_not_create_reports(self):
        script = self.write('tool/verify.py', (ROOT / 'tool/verify.py').read_text(encoding='utf-8'))
        completed = subprocess.run([sys.executable, str(script), 'full', '--dry-run'],
                                   cwd=self.root.parent, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn('flutter analyze --no-pub', completed.stdout)
        self.assertIn('flutter test --no-pub', completed.stdout)
        self.assertFalse((self.root / '.local').exists())


if __name__ == '__main__':
    unittest.main()
