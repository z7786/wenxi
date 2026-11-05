"""Create local release settings from Actions variables and signing secrets."""
import argparse
import base64
import json
import os
from pathlib import Path
import re


CLIENT_DEFINE_FILES = {
    'baidu-api.defines.json': {
        'ASTERLINK_BAIDU_API_ACCESS_KEY', 'ASTERLINK_BAIDU_API_PUBLIC_KEY',
        'ASTERLINK_BAIDU_API_URL', 'ASTERLINK_BAIDU_RELAY_API_URL',
    },
    'cloud-command.defines.json': {'ASTERLINK_QUARK_COMMAND_KEY', 'ASTERLINK_UC_COMMAND_KEY'},
    'parser-hub.defines.json': {
        'ASTERLINK_PARSER_HUB_URL', 'ASTERLINK_PARSER_HUB_KEY',
        'ASTERLINK_PARSER_HUB_PUBLIC_KEY', 'ASTERLINK_PARSER_RULES_BACKUP_URL',
    },
}


def client_defines(local, raw):
    if not raw:
        return {}
    try:
        files = json.loads(raw)
    except (ValueError, TypeError) as error:
        raise ValueError('Invalid client build configuration JSON') from error
    if not isinstance(files, dict) or not files or set(files) - CLIENT_DEFINE_FILES.keys():
        raise ValueError('Unexpected client build configuration files')
    for name, values in files.items():
        allowed = CLIENT_DEFINE_FILES[name]
        required = allowed - {'ASTERLINK_PARSER_RULES_BACKUP_URL', 'ASTERLINK_BAIDU_RELAY_API_URL'}
        if (not isinstance(values, dict) or not required <= values.keys() or
                values.keys() - allowed or any(not isinstance(value, str) for value in values.values())):
            raise ValueError('Invalid client build configuration fields')
        if (local / name).exists():
            raise ValueError('Refusing to overwrite existing client build configuration')
    return files


def properties_escape(value):
    output = []
    for char in value:
        if char in '\\:=#! ':
            output.append('\\' + char)
        elif char == '\n':
            output.append('\\n')
        elif char == '\r':
            output.append('\\r')
        elif char == '\t':
            output.append('\\t')
        elif ord(char) > 126 or ord(char) < 32:
            output.extend('\\u' + unit.hex() for unit in
                          (char.encode('utf-16-be')[i:i+2] for i in range(0, len(char.encode('utf-16-be')), 2)))
        else:
            output.append(char)
    return ''.join(output)


def prepare(root, sign_android=False, environment=None):
    env = environment if environment is not None else os.environ
    root = Path(root).resolve()
    local = root / '.local'
    config_path = local / 'build-config.json'
    if config_path.exists():
        raise ValueError('Refusing to overwrite existing local build settings')
    config = json.loads((root / 'config/build.community.json').read_text(encoding='utf-8'))
    url = env.get('ASTERLINK_CONTROL_URL', '').strip()
    config.update({
        'controlEnabled': bool(url),
        'controlUrl': url,
        'githubRepository': env.get('ASTERLINK_GITHUB_REPO', env.get('GITHUB_REPOSITORY', '')).strip(),
        'applicationId': env.get('ASTERLINK_APPLICATION_ID', '').strip() or config['applicationId'],
        'metricsAppKey': env.get('UMENG_APPKEY', '').strip(),
        'metricsChannel': env.get('UMENG_CHANNEL', '').strip() or 'github',
    })
    if config['metricsAppKey'] and not re.fullmatch('[0-9a-fA-F]{24}', config['metricsAppKey']):
        raise ValueError('UMENG_APPKEY has an invalid format')
    defines = client_defines(local, env.get('ASTERLINK_CLIENT_DEFINES_JSON', ''))
    key_path = local / 'ci-release.jks'
    properties_path = local / 'keystore.properties'
    key_bytes, properties = None, None
    if sign_android:
        required = ('ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD')
        if any(not env.get(name) for name in required):
            raise ValueError('Set all four ANDROID signing secrets in the release environment')
        if key_path.exists() or properties_path.exists():
            raise ValueError('Refusing to overwrite existing signing files')
        try:
            key_bytes = base64.b64decode(''.join(env['ANDROID_KEYSTORE_BASE64'].split()), validate=True)
        except ValueError as error:
            raise ValueError('ANDROID_KEYSTORE_BASE64 is invalid') from error
        if not key_bytes:
            raise ValueError('The Android keystore is empty')
        values = {
            'storeFile': key_path.name,
            'storePassword': env['ANDROID_KEYSTORE_PASSWORD'],
            'keyAlias': env['ANDROID_KEY_ALIAS'],
            'keyPassword': env['ANDROID_KEY_PASSWORD'],
        }
        properties = '\n'.join(key + '=' + properties_escape(value) for key, value in values.items()) + '\n'
    local.mkdir(parents=True, exist_ok=True)
    if sign_android:
        key_path.write_bytes(key_bytes)
        properties_path.write_text(properties, encoding='ascii')
    config_path.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
    for name, values in defines.items():
        (local / name).write_text(json.dumps(values, indent=2) + '\n', encoding='utf-8')
    return config


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android', action='store_true')
    args = parser.parse_args()
    try:
        prepare(Path(__file__).resolve().parent.parent, args.android)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
    print('Local CI build settings prepared; credential values were not logged.')
