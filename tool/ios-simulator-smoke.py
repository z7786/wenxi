"""Verify startup, downloads and Apple player behavior on iPhone and iPad."""
import json
from pathlib import Path
import shutil
import subprocess
import time

root = Path(__file__).resolve().parent.parent
local = root / '.local'
local.mkdir(exist_ok=True)


def sim(*args, **kwargs):
    kwargs.setdefault('timeout', 90)
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True, **kwargs).strip()


runtimes = json.loads(sim('list', 'runtimes', '--json'))['runtimes']
runtime = next(item for item in reversed(runtimes) if item.get('isAvailable') and 'iOS' in item['name'])
available = json.loads(sim('list', 'devices', 'available', '--json'))['devices']
checks = [
    'startup', 'quickjs', 'download', 'coordinatedFileSave', 'freeSpace', 'playback',
    'folderUploadSource',
    'playerPagePlayback', 'playerPageControls', 'playerPageTexture',
    'pipDisabled',
]
reports = {}
for family in ['iPhone', 'iPad']:
    device_type = next(item for item in available[runtime['identifier']]
                       if item.get('isAvailable') and family in item['name'])
    device = sim('create', 'AsterLink ' + family + ' CI', device_type['deviceTypeIdentifier'], runtime['identifier'])
    container = None
    prefix = 'ios-' + family.lower()
    try:
        print(family + ' simulator: booting', flush=True)
        sim('boot', device)
        sim('bootstatus', device, '-b', timeout=420)
        print(family + ' simulator: installing test app', flush=True)
        sim('install', device, str(root / 'build/ios/iphonesimulator/Runner.app'), timeout=180)
        container = Path(sim('get_app_container', device, 'com.asterlink.app', 'data'))
        fixture = container / 'Documents/ios-smoke.mp4'
        fixture.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / 'tool/fixtures/macos-playback.mp4', fixture)
        sim('launch', '--terminate-running-process', '--stdout=' + str(local / (prefix + '-stdout.log')),
            '--stderr=' + str(local / (prefix + '-stderr.log')), device, 'com.asterlink.app')
        print(family + ' simulator: checking startup, storage, folder uploads and playback', flush=True)
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            files = list(container.rglob('ios-smoke.json'))
            if files:
                report = json.loads(files[0].read_text())
                assert 'error' not in report, (family, report)
                assert all(report.get(name) for name in checks), (family, report)
                assert report.get('authorizedMediaReads', 0) > 0, (family, report)
                reports[family] = report
                (local / (prefix + '-smoke-result.json')).write_text(json.dumps(report, indent=2))
                (local / 'ios-smoke-result.json').write_text(json.dumps(reports, indent=2))
                sim('io', device, 'screenshot', str(local / ('ios-smoke-' + family.lower() + '.png')))
                print(family + ' simulator smoke passed:', report, flush=True)
                break
            time.sleep(.5)
        else:
            raise AssertionError(family + ' simulator did not finish smoke checks in 150 seconds')
    finally:
        for file in (container.rglob('*.jsonl') if container is not None else []):
            shutil.copy2(file, local / (prefix + '-' + file.name))
        for suffix in ['stdout.log', 'stderr.log']:
            file = local / (prefix + '-' + suffix)
            if file.exists():
                print(file.read_text(errors='replace')[-10000:])
        for operation in ['shutdown', 'delete']:
            try:
                subprocess.run(['xcrun', 'simctl', operation, device], check=False, timeout=90)
            except subprocess.TimeoutExpired:
                print(family + ' simulator cleanup timed out: ' + operation, flush=True)
