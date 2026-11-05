"""Launch the simulator app and verify startup, native downloads and decoding."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path(__file__).resolve().parent.parent
local = root / '.local'
local.mkdir(exist_ok=True)
def sim(*args, **kwargs):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True, **kwargs).strip()
runtimes = json.loads(sim('list', 'runtimes', '--json'))['runtimes']
runtime = next(item for item in reversed(runtimes) if item.get('isAvailable') and 'iOS' in item['name'])
devices = json.loads(sim('list', 'devicetypes', '--json'))['devicetypes']
device_type = next(item for item in reversed(devices) if 'iPhone' in item['name'])
device = sim('create', 'AsterLink iOS CI', device_type['identifier'], runtime['identifier'])
try:
    sim('boot', device)
    sim('bootstatus', device, '-b')
    sim('install', device, str(root / 'build/ios/iphonesimulator/Runner.app'))
    container = Path(sim('get_app_container', device, 'com.asterlink.app', 'data'))
    fixture = container / 'Documents/ios-smoke.mp4'
    fixture.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / 'tool/fixtures/macos-playback.mp4', fixture)
    sim('launch', '--terminate-running-process', '--stdout=' + str(local / 'ios-stdout.log'),
        '--stderr=' + str(local / 'ios-stderr.log'), device, 'com.asterlink.app',
        env={**os.environ, 'SIMCTL_CHILD_ASTERLINK_IOS_SMOKE_MOVIE': str(fixture)})
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        reports = list(container.rglob('ios-smoke.json'))
        if reports:
            report = json.loads(reports[0].read_text())
            assert 'error' not in report, report
            assert all(report.get(name) for name in ['startup', 'quickjs', 'download', 'freeSpace', 'playback']), report
            (local / 'ios-smoke-result.json').write_text(json.dumps(report, indent=2))
            sim('io', device, 'screenshot', str(local / 'ios-smoke.png'))
            print('iOS simulator smoke passed:', report)
            break
        time.sleep(.5)
    else:
        raise AssertionError('iOS simulator did not finish smoke checks in 120 seconds')
finally:
    for file in (container.rglob('*.jsonl') if 'container' in locals() else []):
        shutil.copy2(file, local / ('ios-' + file.name))
    for name in ['ios-stdout.log', 'ios-stderr.log']:
        file = local / name
        if file.exists(): print(file.read_text(errors='replace')[-10000:])
    subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=False)
    subprocess.run(['xcrun', 'simctl', 'delete', device], check=False)
