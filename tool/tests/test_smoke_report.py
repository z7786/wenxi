import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    'smoke_report', Path(__file__).resolve().parents[1] / 'smoke_report.py')
smoke_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke_report)


class SmokeReportTest(unittest.TestCase):
    def test_runtime_matches_xcode_sdk_instead_of_last_installed_version(self):
        runtimes = [
            {'name': 'iOS 18.5', 'version': '18.5', 'isAvailable': True},
            {'name': 'iOS 26.2', 'version': '26.2', 'isAvailable': True},
        ]
        self.assertEqual(smoke_report.select_ios_runtime(runtimes, '18.5'), runtimes[0])
        self.assertEqual(smoke_report.select_ios_runtime(list(reversed(runtimes)), '26.2'), runtimes[1])

    def test_missing_matching_runtime_fails_before_booting_an_incompatible_one(self):
        with self.assertRaises(RuntimeError):
            smoke_report.select_ios_runtime(
                [{'name': 'iOS 26.2', 'version': '26.2', 'isAvailable': True},
                 {'name': 'iOS 18.5', 'version': '18.5', 'isAvailable': False}], '18.5')

    def test_report_is_not_ready_until_the_write_finishes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'ios-smoke.json'
            self.assertIsNone(smoke_report.read_report(path))
            path.write_text('', encoding='utf-8')
            self.assertIsNone(smoke_report.read_report(path))
            path.write_text('{"startup":', encoding='utf-8')
            self.assertIsNone(smoke_report.read_report(path))
            path.write_text('{"startup": true}', encoding='utf-8')
            self.assertEqual(smoke_report.read_report(path), {'startup': True})

    def test_complete_failure_reports_are_not_hidden(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'ios-smoke.json'
            path.write_text('{"stage":"startup","error":"failed"}', encoding='utf-8')
            self.assertEqual(smoke_report.read_report(path),
                             {'stage': 'startup', 'error': 'failed'})


if __name__ == '__main__':
    unittest.main()
