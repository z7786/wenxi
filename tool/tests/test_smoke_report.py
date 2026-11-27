import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    'smoke_report', Path(__file__).resolve().parents[1] / 'smoke_report.py')
smoke_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke_report)


class SmokeReportTest(unittest.TestCase):
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
