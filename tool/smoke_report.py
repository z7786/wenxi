"""Read simulator reports only after their JSON has been written completely."""
import json


def select_ios_runtime(runtimes, sdk_version):
    sdk = tuple(int(part) for part in sdk_version.strip().split('.'))
    matches = [item for item in runtimes
               if item.get('isAvailable') and item.get('name', '').startswith('iOS ')
               and tuple(int(part) for part in item['version'].split('.'))[:2] == sdk[:2]]
    if not matches:
        raise RuntimeError('No available iOS simulator runtime matches the selected Xcode SDK ' + sdk_version)
    return max(matches, key=lambda item: tuple(int(part) for part in item['version'].split('.')))


def read_report(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (FileNotFoundError, json.JSONDecodeError):
        # The app creates the report before its asynchronous write finishes.
        # The caller's existing deadline still bounds incomplete reports.
        return None
