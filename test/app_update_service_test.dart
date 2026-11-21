import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/quark_share_transfer.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/quark_transfer_device.dart';
import 'app_update_support.dart';
import 'support.dart';

// Synthetic mobile credentials shared with the independent signing vector.
const _mobileKps =
    'AASVvziY9xCitAbP9nqPFJEUGWMrUves7gInDbUtknHZ1+gXpTTh/OOcDdoVjpCVQrdHXX0SJCM25vH4QVXOXQHnManr8A76OxZcB/2QLeS8sw==';

void main() {
  late UpdateFixture f;
  setUp(() => f = UpdateFixture());
  tearDown(() => f.close());

  test(
    'Single share file uses the configured passcode and a recoverable download origin',
    () async {
      expect(await f.service.start(f.current!), isTrue);
      expect(f.connector.opened!.passcode, '1234');
      final task = f.downloads.tasks.single;
      expect(task.spec.fileName, 'app.apk');
      expect(task.spec.needsPreparation, isTrue);
      expect(task.spec.platform, CloudPlatform.lanzou);
      expect(task.spec.appUpdateKey, f.service.keyFor(f.current!));
      expect(task.spec.source!['file']['id'], 'file');
      expect(f.installer.opens, 0);
      final restored = DownloadTask.fromJson(
        jsonDecode(jsonEncode(task.toJson())),
      );
      expect(restored.spec.appUpdateKey, task.spec.appUpdateKey);
      expect(
        QuarkShareTransfer.prefersMobile(
          DownloadOrigin.fromJson(restored.spec.source!).session,
        ),
        isFalse,
      );
    },
  );

  for (final platform in ['android', 'windows']) {
    for (final rejectMobile in [false, true]) {
      test(
        '$platform Quark update ${platform != 'android'
            ? 'always uses web transfer'
            : rejectMobile
            ? 'falls back to web'
            : 'uses phone transfer'}',
        () async {
          final packageName = platform == 'android' ? 'app.apk' : 'setup.exe';
          final http = FakeHttp((r) {
            final mobile = r.uri.host == 'drive-m.quark.cn';
            switch (r.uri.path) {
              case '/account/info':
                return jsonResponse({
                  'success': true,
                  'data': {'mobilekps': _mobileKps},
                });
              case '/1/clouddrive/config':
                return jsonResponse({'status': 200, 'code': 0, 'data': {}});
              case '/1/clouddrive/share/sharepage/token':
                expect(r.json['passcode'], 'new1');
                return jsonResponse({
                  'status': 200,
                  'code': 0,
                  'data': {
                    'stoken': mobile ? 'mobile-stoken' : 'web-stoken',
                    'first_fid': '0',
                  },
                });
              case '/1/clouddrive/share/sharepage/detail':
                return jsonResponse({
                  'status': 200,
                  'code': 0,
                  'data': {
                    'list': [
                      {
                        'fid': 'package',
                        'file_name': packageName,
                        'size': 1024,
                        'dir': false,
                        'share_fid_token': mobile
                            ? 'mobile-token'
                            : 'web-token',
                      },
                    ],
                  },
                });
              case '/1/clouddrive/file/sort':
                return jsonResponse({
                  'status': 200,
                  'code': 0,
                  'data': {
                    'list': [
                      {
                        'fid': 'temp-base',
                        'file_name': '文析助手临时转存',
                        'dir': true,
                      },
                    ],
                  },
                });
              case '/1/clouddrive/file':
                return jsonResponse({
                  'status': 200,
                  'code': 0,
                  'data': {'fid': 'temp-update'},
                });
              case '/1/clouddrive/share/sharepage/save':
                if (mobile && rejectMobile) {
                  return jsonResponse({'status': 400, 'code': 14007}, 400);
                }
                return jsonResponse({
                  'status': 200,
                  'code': 0,
                  'data': {'task_id': mobile ? 'mobile-task' : 'web-task'},
                });
              case '/1/clouddrive/task':
                return jsonResponse({
                  'status': 200,
                  'code': 0,
                  'data': {
                    'status': 2,
                    'save_as': {
                      'save_as_top_fids': ['saved-package'],
                    },
                  },
                });
              case '/1/clouddrive/file/download':
                // Preserve the normal adaptive direct attempt before transfer.
                if (r.json.containsKey('pwd_id')) {
                  return jsonResponse({'status': 403, 'code': 23018}, 403);
                }
                expect(r.json['fids'], ['saved-package']);
                return jsonResponse({
                  'status': 200,
                  'code': 0,
                  'data': [
                    {
                      'fid': 'saved-package',
                      'file_name': packageName,
                      'size': 1024,
                      'download_url': 'https://cdn.quark.cn/$packageName',
                    },
                  ],
                });
            }
            throw StateError('Unexpected update request ${r.uri.path}');
          });
          f.close();
          f = UpdateFixture(
            platform: platform,
            transport: http,
            quarkTransferDevice: QuarkTransferDevice(
              platform: platform,
              readEnvironment: () async => {
                'deviceType': 'phone',
                'model': 'fixture-update-phone',
                'osVersion': '15',
                'screenWidth': 393,
                'screenHeight': 852,
                'locale': 'zh-Hans-CN',
                'networkTransport': 'cellular',
                'cellularSubtype': 13,
              },
            ),
          );
          await f.cloud.vault.putCredential(
            CloudPlatform.quark,
            Credential('fixture', {
              'primary': '__pus=fixture-account; __puus=fixture-session',
              'quarkSessionRefreshedAt':
                  '${DateTime.now().millisecondsSinceEpoch}',
            }, updatedAt: 42),
          );
          f.current = RemoteUpdate(
            '1.2.0',
            120,
            Uri.parse('https://pan.quark.cn/s/updatefixture?pwd=old1'),
            '',
            // Exercise both the dedicated URL and downloadUrl fallback.
            inAppDownloadUrl: platform == 'android'
                ? Uri.parse('https://pan.quark.cn/s/updatefixture?pwd=old1')
                : null,
            inAppPasscode: 'new1',
          );
          expect(await f.service.start(f.current!), isTrue);
          expect(
            http.calls.where((r) => r.uri.path.endsWith('/save')),
            isEmpty,
          );
          final restored = DownloadTask.fromJson(
            jsonDecode(jsonEncode(f.downloads.tasks.single.toJson())),
          );
          final origin = DownloadOrigin.fromJson(restored.spec.source!);
          expect(QuarkShareTransfer.prefersMobile(origin.session), isTrue);
          expect(origin.session.sourceLink?.passcode, 'new1');
          expect(restored.spec.appUpdateKey, f.service.keyFor(f.current!));
          final prepared = await f.cloud.refresh(restored.spec);
          expect(prepared.url, 'https://cdn.quark.cn/$packageName');
          expect(prepared.cleanup?.url, contains('drive-pc.quark.cn'));
          expect(
            QuarkShareTransfer.prefersMobile(
              DownloadOrigin.fromJson(prepared.source!).session,
            ),
            isTrue,
          );
          final mobileSaves = http.calls.where(
            (r) =>
                r.uri.host == 'drive-m.quark.cn' &&
                r.uri.path.endsWith('/save'),
          );
          expect(mobileSaves, hasLength(platform == 'android' ? 1 : 0));
          if (platform == 'android') {
            final mobileSave = mobileSaves.single;
            expect(mobileSave.json['fid_list'], ['package']);
            expect(mobileSave.json['fid_token_list'], ['mobile-token']);
            expect(mobileSave.json['to_pdir_fid'], 'temp-update');
            expect(
              mobileSave.uri.queryParameters['device_model'],
              'fixture-update-phone',
            );
            expect(mobileSave.uri.queryParameters['ss'], '393x852');
            expect(mobileSave.uri.queryParameters['la'], 'zh');
            expect(mobileSave.uri.queryParameters['nt'], '6');
            expect(mobileSave.uri.queryParameters['nw'], '4G');
            expect(
              mobileSave.uri.queryParameters['ve'],
              QuarkTransferDeviceInfo.clientVersion,
            );
            expect(
              mobileSave.headers.keys.map((k) => k.toLowerCase()),
              isNot(contains('cookie')),
            );
          } else {
            expect(
              http.calls.where((r) => r.uri.host == 'drive-m.quark.cn'),
              isEmpty,
            );
            expect(
              http.calls.where((r) => r.uri.path == '/account/info'),
              isEmpty,
            );
          }
          final webSaves = http.calls.where(
            (r) =>
                r.uri.host == 'drive-pc.quark.cn' &&
                r.uri.path.endsWith('/save'),
          );
          expect(
            webSaves,
            hasLength(platform != 'android' || rejectMobile ? 1 : 0),
          );
          if (platform != 'android' || rejectMobile) {
            expect(webSaves.single.json['fid_token_list'], ['web-token']);
          }
          expect(f.installer.opens, 0);
        },
      );
    }
  }

  test(
    'Repeated clicks coalesce and reuse paused, failed and finished tasks',
    () async {
      f.connector.pending = Completer<void>();
      final a = f.service.start(f.current!), b = f.service.start(f.current!);
      expect(identical(a, b), isTrue);
      f.connector.pending!.complete();
      await a;
      await f.service.start(f.current!);
      expect(f.downloads.created, 1);
      await f.service.pause(f.current!);
      await f.service.start(f.current!);
      expect(f.downloads.resumed, 1);
      f.downloads.change(f.downloads.tasks.single.id, {
        'status': 'failed',
        'error': '网络故障',
      });
      await f.service.start(f.current!);
      expect(f.downloads.resumed, 2);
      f.complete();
      await f.service.start(f.current!);
      expect(f.downloads.created, 1);
      expect(f.installer.opens, 0);
    },
  );

  test(
    'Redownloading a failed update discards the old task and resolves the share again',
    () async {
      await f.service.start(f.current!);
      final oldId = f.downloads.tasks.single.id;
      f.downloads.change(oldId, {'status': 'failed', 'error': '文件校验失败'});
      f.connector.opened = null;
      f.connector.entries = [
        const CloudFile(id: 'fresh', name: 'fresh.apk', size: 2048),
      ];
      expect(await f.service.start(f.current!, redownload: true), isTrue);
      expect(f.downloads.created, 2);
      expect(f.downloads.resumed, 0);
      expect(f.downloads.task(oldId), isNull);
      expect(f.connector.opened, isNotNull);
      expect(f.downloads.tasks.single.spec.source!['file']['id'], 'fresh');
    },
  );

  test(
    'Existing persisted update downloads are recovered without another share request',
    () async {
      await f.service.start(f.current!);
      final restored = DownloadTask.fromJson(
        jsonDecode(jsonEncode(f.downloads.tasks.single.toJson())),
      );
      f.close();
      f = UpdateFixture();
      f.downloads.records.add(restored.update({'status': 'paused'}));
      expect(await f.service.start(f.current!), isTrue);
      expect(f.connector.opened, isNull);
      expect(f.downloads.created, 0);
      expect(f.downloads.resumed, 1);
    },
  );

  for (final entries in <List<CloudFile>>[
    [],
    [const CloudFile(id: 'dir', name: '安装包', isDirectory: true)],
    [
      const CloudFile(id: 'a', name: 'app.apk'),
      const CloudFile(id: 'b', name: 'readme.txt'),
    ],
    [const CloudFile(id: 'a', name: 'installer.exe')],
  ]) {
    test(
      'Rejects invalid share selection ${entries.map((f) => f.name).join(',')}',
      () async {
        f.connector.entries = entries;
        expect(await f.service.start(f.current!), isFalse);
        expect(f.service.error(f.current!), isNotEmpty);
        expect(f.downloads.tasks, isEmpty);
      },
    );
  }

  test(
    'Login failures remain visible and never queue a webpage as an APK',
    () async {
      f.connector.failure = const AppException('请先登录网盘账号');
      expect(await f.service.start(f.current!), isFalse);
      expect(f.service.error(f.current!), contains('登录'));
      f.current = RemoteUpdate(
        '1.2.0',
        120,
        Uri.parse('https://downloads.example.test/browser'),
        '',
      );
      expect(await f.service.start(f.current!), isFalse);
      expect(f.service.error(f.current!), contains('浏览器更新'));
      expect(f.downloads.tasks, isEmpty);
    },
  );

  for (final platform in ['android', 'windows']) {
    test(
      '$platform supports direct installation assets including GitHub fallback',
      () async {
        f.close();
        f = UpdateFixture(platform: platform);
        final extension = platform == 'android' ? 'apk' : 'exe';
        f.current = RemoteUpdate(
          '1.2.0',
          0,
          Uri.parse(
            'https://github.com/z7786/wenxi/releases/download/v1.2.0/app.$extension',
          ),
          '',
          releaseKey: 'github:v1.2.0',
        );
        expect(await f.service.start(f.current!), isTrue);
        expect(
          f.downloads.tasks.single.spec.url,
          f.current!.downloadUrl.toString(),
        );
        expect(f.connector.opened, isNull);
      },
    );
  }

  test(
    'Changed update URL invalidates pending parsing, including unchanged build',
    () async {
      final old = f.current!;
      f.connector.pending = Completer<void>();
      final operation = f.service.start(old);
      await Future<void>.delayed(Duration.zero);
      f.current = RemoteUpdate(
        old.version,
        old.build,
        Uri.parse('https://example.test/new.apk'),
        '',
      );
      f.connector.pending!.complete();
      expect(await operation, isFalse);
      expect(f.downloads.tasks, isEmpty);
      expect(f.service.error(old), contains('已变化'));
    },
  );

  test(
    'Missing completed files download again; inaccessible files report permissions',
    () async {
      await f.service.start(f.current!);
      f.complete();
      f.files.availability['/saved/app.apk'] = FileAvailability.inaccessible;
      expect(await f.service.start(f.current!), isFalse);
      expect(f.downloads.created, 1);
      f.files.availability['/saved/app.apk'] = FileAvailability.missing;
      expect(await f.service.start(f.current!), isTrue);
      expect(f.downloads.created, 2);
    },
  );

  test(
    'Installation requires completion, foreground and a successful validation',
    () async {
      final update = f.current!;
      await f.service.start(update);
      expect(await f.service.install(update), isFalse);
      f.complete();
      f.foreground = false;
      expect(await f.service.install(update), isFalse);
      f.foreground = true;
      f.installer.failure = const AppException('签名不一致');
      expect(await f.service.install(update), isFalse);
      expect(f.installer.opens, 0);
      f.installer.failure = null;
      expect(await f.service.install(update), isTrue);
      expect(f.installer.opens, 1);
      expect(await f.service.start(update, redownload: true), isTrue);
      expect(f.downloads.created, 2);
    },
  );

  test(
    'Withdrawing update while validation runs never launches installer',
    () async {
      final update = f.current!;
      await f.service.start(update);
      f.complete();
      f.installer.pending = Completer<void>();
      final operation = f.service.install(update);
      await Future<void>.delayed(Duration.zero);
      f.current = null;
      f.installer.pending!.complete();
      expect(await operation, isFalse);
      expect(f.installer.opens, 0);
    },
  );
}
