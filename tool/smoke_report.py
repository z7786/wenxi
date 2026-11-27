"""Read simulator reports only after their JSON has been written completely."""
import json


def read_report(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (FileNotFoundError, json.JSONDecodeError):
        # The app creates the report before its asynchronous write finishes.
        # The caller's existing deadline still bounds incomplete reports.
        return None
