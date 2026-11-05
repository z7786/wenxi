"""Static Android release checks; does not replace a device smoke test."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import zipfile


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def execute(command, environment):
    result = subprocess.run([str(v) for v in command], env=environment,
        capture_output=True, text=True, encoding='utf-8', errors='replace')
    check(result.returncode == 0, result.stdout + result.stderr)
    return result.stdout


def certificate(text):
    found = re.search(r'certificate SHA-256 digest: (\w+)', text)
    check(found, 'Missing signer SHA-256')
    return found.group(1).lower()


def component_attributes(tree, kind, class_name):
    lines = tree.splitlines()
    for index, line in enumerate(lines):
        if not re.match(r'\s*E: ' + re.escape(kind) + r'\b', line):
            continue
        indent = len(line) - len(line.lstrip())
        attributes = []
        for child in lines[index + 1:]:
            if child.lstrip().startswith('E:'):
                break
            if len(child) - len(child.lstrip()) > indent:
                attributes.append(child)
        block = '\n'.join(attributes)
        if re.search(r'android:name\([^)]*\)="' + re.escape(class_name) + r'"', block):
            return block
    raise RuntimeError('Missing Android component: ' + class_name)


def boolean_attribute(block, attribute, expected):
    match = re.search(r'android:' + re.escape(attribute)
        + r'\([^)]*\)=(?:(true|false)\b|\(type 0x12\)(0x[0-9a-f]+))', block)
    if match is None:
        return False
    value = match.group(1) == 'true' if match.group(1) else bool(int(match.group(2), 16))
    return value == expected


def inspect(args):
    project = Path(__file__).resolve().parent.parent
    sdk = Path(args.sdk)
    builds = sorted((p for p in (sdk/'build-tools').iterdir() if p.is_dir()),
        key=lambda p: tuple(int(n) for n in re.findall(r'\d+', p.name)))
    build = builds[-1]
    env = os.environ.copy()
    if args.java_home:
        env['JAVA_HOME'] = args.java_home
    env['TEMP'] = str(project/'.local/build-tmp')
    env['TMP'] = env['TEMP']
    Path(env['TEMP']).mkdir(parents=True, exist_ok=True)
    signing, signer = '', None
    if not args.unsigned:
        signing = execute([build/'apksigner.bat', 'verify', '--verbose', '--print-certs', args.apk], env)
        signer = certificate(signing)
        for version in (2, 3):
            check(re.search(rf'Verified using v{version} scheme.*: true', signing), f'Missing v{version} signing')
    reference_signer = None
    if args.reference:
        check(not args.unsigned, 'Cannot compare signing certificates in an unsigned build check')
        reference_signer = certificate(execute([build/'apksigner.bat', 'verify', '--print-certs', args.reference], env))
        check(signer == reference_signer, 'Signing certificate differs from the previous release')
    badging = execute([build/'aapt2.exe', 'dump', 'badging', args.apk], env)
    package = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    version = re.search(r'^version:\s*([^\s+]+)\+(\d+)\s*$',
        (project/'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
    check(version, 'pubspec.yaml must declare a version and build number')
    check(package and package.groups() == (args.application_id, version.group(2), version.group(1)),
        'APK package/version differs from pubspec.yaml')
    label = re.search(r"^application-label:'([^']+)'", badging, re.MULTILINE)
    check(label and label.group(1) == '文析助手', 'Unexpected application display name')
    minimum = int(re.search(r"(?:minSdkVersion|sdkVersion):'(\d+)'", badging).group(1))
    target = int(re.search(r"targetSdkVersion:'(\d+)'", badging).group(1))
    check(minimum == 24 and target == 36, 'Unexpected Android SDK levels')
    check('application-debuggable' not in badging, 'Release must not be debuggable')
    manifest = execute([build/'aapt2.exe', 'dump', 'xmltree', '--file', 'AndroidManifest.xml', args.apk], env)
    activity = component_attributes(manifest, 'activity', 'com.asterlink.app.MainActivity')
    receiver = component_attributes(manifest, 'receiver', 'com.asterlink.app.PlaybackActionReceiver')
    downloads = component_attributes(manifest, 'service', 'com.asterlink.app.FlutterDownloadService')
    keepalive = component_attributes(manifest, 'service', 'com.asterlink.app.AppKeepAliveService')
    check(boolean_attribute(keepalive, 'exported', False), 'Startup keepalive service must not be exported')
    check(boolean_attribute(keepalive, 'stopWithTask', False), 'Startup keepalive must survive activity task removal')
    check(re.search(r'android:foregroundServiceType\([^)]*\)=.*0x40000000\b', keepalive),
          'Startup keepalive must use specialUse rather than consume the download dataSync budget')
    subtype = component_attributes(manifest, 'property', 'android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE')
    check(re.search(r'android:value\([^)]*\)="[^"]*user-opened Flutter app session[^\"]*"', subtype),
          'Startup keepalive must declare its actual specialUse purpose')
    check(boolean_attribute(downloads, 'exported', False), 'Download service must not be exported')
    check(boolean_attribute(downloads, 'stopWithTask', False), 'Download service must survive activity task removal')
    check(re.search(r'android:foregroundServiceType\([^)]*\)=.*0x0*1\b', downloads),
          'Download service must use the dataSync foreground type')
    for permission in ('FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_DATA_SYNC', 'FOREGROUND_SERVICE_SPECIAL_USE', 'WAKE_LOCK',
                       'POST_NOTIFICATIONS', 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'):
        check('android.permission.'+permission in manifest, 'Missing download permission: '+permission)
    check(boolean_attribute(activity, 'supportsPictureInPicture', True), 'PiP support is missing')
    check(boolean_attribute(activity, 'resizeableActivity', True), 'Player activity must support resizing')
    check(boolean_attribute(receiver, 'exported', False), 'PiP action receiver must not be exported')
    metadata = component_attributes(manifest, 'meta-data', 'UMENG_APPKEY')
    appkey_match = re.search(r'android:value\([^)]*\)="([0-9a-fA-F]{24})"', metadata)
    check(appkey_match, 'Missing built-in statistics AppKey')
    if args.umeng_appkey:
        check(appkey_match.group(1) == args.umeng_appkey, 'Unexpected statistics AppKey')
    for key, expected in (('UMENG_CHANNEL', args.umeng_channel),):
        metadata = component_attributes(manifest, 'meta-data', key)
        check(re.search(r'android:value\([^)]*\)="' + re.escape(expected) + r'"', metadata),
              f'Unexpected {key} in packaged manifest')
    for permission in ('INTERNET', 'ACCESS_NETWORK_STATE', 'ACCESS_WIFI_STATE'):
        check('android.permission.' + permission in manifest, 'Missing analytics permission: ' + permission)
    for permission in ('READ_PHONE_STATE', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION'):
        check('android.permission.' + permission not in manifest, 'Unexpected sensitive permission: ' + permission)
    readelf = sdk/'ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
    system = {'libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so', 'libz.so',
        'libEGL.so', 'libGLESv2.so', 'libGLESv3.so', 'libOpenSLES.so', 'libmediandk.so',
        'libjnigraphics.so', 'libvulkan.so'}
    libraries = []
    extraction = project/'.local/apk-inspection'
    with zipfile.ZipFile(args.apk) as apk:
        check(apk.testzip() is None, 'Corrupt ZIP entry')
        entries = [info for info in apk.infolist() if info.filename.startswith('lib/') and info.filename.endswith('.so')]
        abis = {PurePosixPath(info.filename).parts[1] for info in entries}
        check(abis == {'arm64-v8a'}, f'Unexpected ABIs: {abis}')
        names = {PurePosixPath(info.filename).name for info in entries}
        check(not {'libmdk.so', 'libfvp.so'} & names, 'Removed MDK runtime is still packaged')
        check({'libgojni.so', 'libc++_shared.so', 'libflutter.so', 'libapp.so', 'libmpv.so', 'libumeng-spy.so',
               'libasterlink_js.so'} <= names,
            'A required native library is missing')
        for info in entries:
            parts = PurePosixPath(info.filename).parts
            check(len(parts) == 3 and '..' not in parts, 'Invalid native entry path')
            data = apk.read(info)
            if parts[2] == 'libgojni.so':
                check(b'sourceNetworkPolicy' in data, 'Gopeed source network policy capability is missing')
            check(data[:6] == b'\x7fELF\x02\x01', 'Native library is not little-endian ELF64')
            phoff = struct.unpack_from('<Q', data, 32)[0]
            phentsize, phnum = struct.unpack_from('<HH', data, 54)
            alignments = []
            for index in range(phnum):
                offset = phoff + index * phentsize
                if struct.unpack_from('<I', data, offset)[0] != 1:
                    continue
                file_offset, virtual = struct.unpack_from('<QQ', data, offset + 8)
                alignment = struct.unpack_from('<Q', data, offset + 48)[0]
                check(alignment >= 16384 and file_offset % 16384 == virtual % 16384,
                    f'{info.filename} is not aligned for 16 KB pages')
                alignments.append(alignment)
            check(alignments, 'No ELF LOAD segments')
            check(info.compress_type == zipfile.ZIP_DEFLATED, 'Expected compressed JNI packaging')
            path = extraction/parts[1]/parts[2]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            dynamic = execute([readelf, '-d', path], env)
            needed = re.findall(r'\(NEEDED\).*?\[([^\]]+)\]', dynamic)
            missing = set(needed) - names - system
            check(not missing, f'{info.filename} missing dependencies: {missing}')
            libraries.append({'name': parts[2], 'bytes': info.file_size,
                'compressedBytes': info.compress_size, 'loadAlignments': alignments, 'needed': needed})
        dex = b''.join(apk.read(n) for n in apk.namelist() if re.fullmatch(r'classes\d*\.dex', n))
        check(b'Landroidx/media3/' not in dex, 'Removed Media3 runtime is still packaged')
        check(b'Lcom/asterlink/app/MdkNativeControl;' not in dex, 'Removed MDK lifecycle bridge is still packaged')
        for name in (b'Lgo/Seq;', b'Lcom/asterlink/nativecore/gopeed/Gopeed;', b'Lcom/asterlink/app/NativeBridge;',
                     b'Lcom/asterlink/app/PlaybackBridge;', b'Lcom/asterlink/app/PlaybackActionReceiver;',
                     b'Lcom/asterlink/app/DownloadKeepAlive;', b'Lcom/asterlink/app/DownloadProtection;',
                     b'Lcom/asterlink/app/AppKeepAlive;', b'Lcom/asterlink/app/AppKeepAliveService;',
                     b'Lcom/asterlink/app/NotificationPermission;'):
            check(name in dex, f'Missing bridge class: {name.decode()}')
        bt_methods = ('resolveTorrent', 'torrentMetadata', 'cancelTorrent',
                      'startTorrentStream', 'torrentStreamStatus',
                      'stopTorrentStream', 'interruptTorrentStream')
        for method in bt_methods:
            check(method.encode() in dex, f'Missing BT bridge method: {method}')
        for name in (b'Lcom/asterlink/app/metrics/UsageMetrics;',
                     b'Lcom/asterlink/app/metrics/AndroidMetricsBackend;', b'Lcom/umeng/commonsdk/UMConfigure;',
                     b'Lcom/umeng/analytics/MobclickAgent;', b'Lcom/umeng/umzid/ZIDManager;'):
            check(name in dex, f'Missing analytics class: {name.decode()}')
        check(b'Ldev/flutter/plugins/integration_test/' not in dex, 'Test plugin included in release')
        for asset in ('icons/app.png', 'icons/quark.png', 'licenses/Gopeed-LICENSE.txt',
                      'licenses/OpenList-LICENSE.txt', 'licenses/AsterLink-LICENSE.txt', 'licenses/android-ndk-NOTICE.txt',
                      'licenses/QuickJS-NG-LICENSE.txt'):
            check('assets/flutter_assets/assets/' + asset in apk.namelist(), f'Missing asset: {asset}')
    apk_file = Path(args.apk)
    report = {'kind': 'static-apk-inspection', 'passed': True, 'file': apk_file.name,
        'sha256': hashlib.sha256(apk_file.read_bytes()).hexdigest(), 'bytes': apk_file.stat().st_size,
        'package': package.group(1), 'version': package.group(3), 'versionCode': int(package.group(2)),
        'applicationLabel': label.group(1),
        'minSdk': minimum, 'targetSdk': target, 'abis': sorted(abis), 'debuggable': False,
        'signatureVerified': not args.unsigned,
        'signerSha256': signer, 'sameSignerAsPreviousRelease': reference_signer == signer if reference_signer else None,
        'signatureSchemes': [f'v{v}' for v in (1, 2, 3) if re.search(rf'Verified using v{v} scheme.*: true', signing)],
        'nativeLibraries': libraries,
        'downloader': {'version': '1.8.1', 'btBridgeMethods': list(bt_methods),
            'foregroundType': 'dataSync', 'serviceExported': False, 'stopWithTask': False,
            'batteryOptimizationRequestDeclared': True, 'keepAliveBridgeIncluded': True},
        'startupKeepAlive': {'foregroundType': 'specialUse', 'serviceExported': False,
            'stopWithTask': False, 'specialUsePermissionDeclared': True,
            'specialUsePurposeDeclared': True, 'serviceAndPermissionBridgeIncluded': True,
            'separateFromDownloadDataSyncService': True},
        'playback': {'pictureInPictureDeclared': True, 'resizeableActivity': True,
            'actionReceiverExported': False, 'nativeBridgeIncluded': True},
        'analytics': {'provider': 'Umeng U-App', 'appKeyPresent': True,
            'channel': args.umeng_channel, 'sdkClassesIncluded': True,
            'nativeLibraryIncluded': True, 'phoneAndLocationPermissionsDeclared': False,
            'backendReceiptVerified': False},
        'deviceExecutionVerified': False}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=True, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', required=True)
    parser.add_argument('--reference')
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--java-home')
    parser.add_argument('--output', required=True)
    parser.add_argument('--application-id', default='com.asterlink.app')
    parser.add_argument('--unsigned', action='store_true', help='Inspect a build-only APK without claiming a verified signature')
    parser.add_argument('--umeng-appkey', default=os.environ.get('UMENG_APPKEY', ''))
    parser.add_argument('--umeng-channel', default='official')
    inspect(parser.parse_args())
