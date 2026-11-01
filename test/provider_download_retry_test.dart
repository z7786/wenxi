import 'package:asterlink/data/providers/baidu_link_service.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'lanzou_support.dart';
import 'support.dart';

Credential _credential(CloudPlatform platform) =>
    Credential('fixture', switch (platform) {
      CloudPlatform.baidu => {'primary': 'BDUSS=fixture'},
      CloudPlatform.quark || CloudPlatform.uc => {
        'primary': '__pus=fixture; __puus=fixture',
        'quarkSessionRefreshedAt': '${DateTime.now().millisecondsSinceEpoch}',
        'ucSessionRefreshedAt': '${DateTime.now().millisecondsSinceEpoch}',
      },
      CloudPlatform.pan123 => {
        'primary': 'fixture-token',
        'accessToken': 'fixture-token',
        'authType': 'webToken',
      },
      CloudPlatform.c139 => {
        'primary': 'skey=fixture; ud_id=domain',
        'authorization':
            'Basic ${base64Encode(utf8.encode('pc:13800000000:fixture'))}',
      },
      CloudPlatform.tianyi => {'primary': 'COOKIE_LOGIN_USER=fixture'},
      _ => throw StateError('Unsupported fixture'),
    }, updatedAt: 42);

const _direct = 'https://cdn.example/ready?sign=a%2bb&key=1&key=2';

void main() {
  test(
    'Mobile cloud shares one preparation budget across POST listing and download requests',
    () async {
      final store = StateStore.memory();
      final vault = Vault(store);
      await vault.putCredential(
        CloudPlatform.c139,
        _credential(CloudPlatform.c139),
      );
      final reads = <String, int>{};
      final http = FakeHttp((request) {
        final path = request.uri.path;
        final count = reads.update(path, (n) => n + 1, ifAbsent: () => 1);
        expect(request.method, 'POST');
        if (count == 1) return const HttpResult(503, '{}');
        return jsonResponse({
          'code': '0000',
          'data': path.endsWith('/file/list')
              ? {
                  'items': [
                    {
                      'fileId': 'file',
                      'name': 'fixture.bin',
                      'size': 4,
                      'type': 'file',
                    },
                  ],
                }
              : {'url': _direct},
        });
      });
      final delays = <Duration>[];
      final repository = CloudRepository(
        http,
        vault,
        CleanupOutbox(store, http),
        preparationRetries: () => 2,
        retryWait: (delay) async => delays.add(delay),
      );
      final planned = repository.planDownload(
        const BrowseSession(
          platform: CloudPlatform.c139,
          mode: BrowseMode.personal,
          title: 'fixture',
          rootId: 'root',
        ),
        const CloudFile(
          id: 'file',
          name: 'fixture.bin',
          parentId: 'root',
          size: 4,
        ),
      );
      final spec = await repository.refresh(planned);
      expect(spec.url, _direct);
      expect(reads, {'/hcy/file/list': 2, '/hcy/file/getDownloadUrl': 2});
      expect(delays, [const Duration(seconds: 2), const Duration(seconds: 5)]);
    },
  );

  for (final recover in [true, false]) {
    test(
      'Default preparation budget retries 64 times: recover=$recover',
      () async {
        final store = StateStore.memory();
        final vault = Vault(store);
        await vault.putCredential(
          CloudPlatform.c139,
          _credential(CloudPlatform.c139),
        );
        final reads = <String, int>{};
        final http = FakeHttp((request) {
          final path = request.uri.path;
          final count = reads.update(path, (n) => n + 1, ifAbsent: () => 1);
          final listing = path.endsWith('/file/list');
          if ((listing && count == 1) ||
              (!listing && (count < 64 || !recover))) {
            return const HttpResult(503, '{}');
          }
          return jsonResponse({
            'code': '0000',
            'data': listing
                ? {
                    'items': [
                      {
                        'fileId': 'file',
                        'name': 'fixture.bin',
                        'size': 4,
                        'type': 'file',
                      },
                    ],
                  }
                : {'url': _direct},
          });
        });
        final delays = <Duration>[];
        final repository = CloudRepository(
          http,
          vault,
          CleanupOutbox(store, http),
          retryWait: (delay) async => delays.add(delay),
        );
        final planned = repository.planDownload(
          const BrowseSession(
            platform: CloudPlatform.c139,
            mode: BrowseMode.personal,
            title: 'fixture',
            rootId: 'root',
          ),
          const CloudFile(
            id: 'file',
            name: 'fixture.bin',
            parentId: 'root',
            size: 4,
          ),
        );
        if (recover) {
          expect((await repository.refresh(planned)).url, _direct);
        } else {
          await expectLater(
            repository.refresh(planned),
            throwsA(isA<HttpRequestFailure>()),
          );
        }
        expect(reads, {'/hcy/file/list': 2, '/hcy/file/getDownloadUrl': 64});
        expect(delays, [
          const Duration(seconds: 2),
          const Duration(seconds: 5),
          ...List.filled(62, const Duration(seconds: 10)),
        ]);
      },
    );
  }

  test(
    'Pausing a share preparation waiting for the common root does not wait for another task',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final http = FakeHttp((request) async {
        expect(request.uri.path, '/1/clouddrive/file/sort');
        entered.complete();
        await release.future;
        return jsonResponse({
          'code': 0,
          'status': 200,
          'data': {'list': []},
        });
      });
      final store = StateStore.memory();
      final vault = Vault(store);
      await vault.putCredential(
        CloudPlatform.quark,
        _credential(CloudPlatform.quark),
      );
      final repository = CloudRepository(
        http,
        vault,
        CleanupOutbox(store, http),
        retryWait: (_) async {},
        directShareDownloadEnabled: (_, _) => false,
      );
      const session = BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.share,
        title: 'fixture',
        rootId: '0',
        metadata: {'shareId': 'share', 'stoken': 'fixture'},
      );
      const file = CloudFile(
        id: 'file',
        name: 'fixture.bin',
        size: 4,
        token: 'fixture-token',
      );
      final first = RequestScope(), second = RequestScope();
      final firstCheck = expectLater(
        first.run(() => repository.prepare(session, file)),
        throwsA(isA<AppException>()),
      );
      await entered.future;
      final secondCheck = expectLater(
        second.run(() => repository.prepare(session, file)),
        throwsA(isA<AppException>()),
      );
      try {
        await Future<void>.delayed(Duration.zero);
        second.cancel();
        await secondCheck.timeout(const Duration(seconds: 1));
        expect(release.isCompleted, isFalse);
      } finally {
        first.cancel();
        release.complete();
        await firstCheck;
      }
      expect(http.calls, hasLength(1));
    },
  );

  for (final platform in [
    CloudPlatform.baidu,
    CloudPlatform.quark,
    CloudPlatform.uc,
    CloudPlatform.pan123,
    CloudPlatform.c139,
    CloudPlatform.tianyi,
  ]) {
    test(
      '${platform.name} download lookup recovers through its real protocol wrappers',
      () async {
        final store = StateStore.memory();
        final vault = Vault(store);
        await vault.putCredential(platform, _credential(platform));
        var lookups = 0;
        final file = CloudFile(
          id: '42',
          name: 'fixture.bin',
          size: 4,
          token: platform == CloudPlatform.baidu
              ? '/fixture.bin'
              : encoded({'s3': 'fixture', 'etag': ''}),
        );
        final http = FakeHttp((request) {
          if (request.uri.host == 'cdn.example') {
            return const HttpResult(206, 'file');
          }
          expect(
            request.method,
            platform == CloudPlatform.tianyi ? 'GET' : 'POST',
          );
          if (++lookups == 1) {
            return const HttpResult(503, '<html>unavailable</html>');
          }
          return jsonResponse(switch (platform) {
            CloudPlatform.baidu => {
              'errno': 0,
              'urls': [
                {'encrypt': 0, 'url': _direct},
              ],
            },
            CloudPlatform.quark || CloudPlatform.uc => {
              'code': 0,
              'status': 200,
              'data': [
                {
                  'fid': file.id,
                  'file_name': file.name,
                  'size': file.size,
                  'download_url': _direct,
                },
              ],
            },
            CloudPlatform.pan123 => {
              'code': 0,
              'data': {'DownloadUrl': _direct},
            },
            CloudPlatform.c139 => {
              'code': '0000',
              'data': {'url': _direct, 'size': 4},
            },
            CloudPlatform.tianyi => {'res_code': 0, 'fileDownloadUrl': _direct},
            _ => throw StateError('Unsupported fixture'),
          });
        });
        final delays = <Duration>[];
        final repository = CloudRepository(
          http,
          vault,
          CleanupOutbox(store, http),
          retryWait: (delay) async => delays.add(delay),
        );
        if (platform == CloudPlatform.baidu) {
          repository.connectors[platform] = BaiduConnector(
            repository.http,
            store: vault,
            linkLookup:
                ({
                  required cookie,
                  required path,
                  required fileId,
                  required appId,
                  required device,
                }) async {
                  // The private service is injected here; its encrypted client
                  // protocol is covered separately by baidu_link_service_test.
                  final response = await repository.http.postJsonRead(
                    'https://link.example.test/v1/baidu/link',
                    {'fileId': fileId},
                  );
                  return BaiduResolvedLink(
                    url: response.json.list('urls').single.str('url'),
                    preview: false,
                  );
                },
          );
        }
        final spec = await repository.prepare(
          BrowseSession(
            platform: platform,
            mode: BrowseMode.personal,
            title: 'fixture',
            rootId: 'root',
          ),
          file,
        );
        expect(spec.url, _direct);
        expect(lookups, 2);
        expect(delays, [const Duration(seconds: 2)]);
      },
    );
  }

  for (final password in [false, true]) {
    test(
      'Lanzou ${password ? 'password' : 'iframe'} download POST can recover without replaying page setup',
      () async {
        final fixture = LanzouFixture();
        if (password) fixture.page = lanzouTestPasswordPage;
        final session = await fixture.open(password ? 'a123' : null);
        final file = (await fixture.connector.list(
          session,
          session.rootId,
          null,
        )).single;
        fixture.http.calls.clear();
        var posts = 0;
        fixture.override = (request) => request.method == 'POST' && ++posts == 1
            ? const HttpResult(503, '<html>unavailable</html>')
            : null;
        final store = StateStore.memory();
        final repository = CloudRepository(
          fixture.http,
          Vault(store),
          CleanupOutbox(store, fixture.http),
          retryWait: (_) async {},
        );
        final spec = await repository.prepare(session, file);
        expect(spec.url, lanzouTestFinal);
        expect(posts, 2);
        expect(
          fixture.http.calls.where((r) => r.url == lanzouTestUrl),
          hasLength(1),
        );
      },
    );
  }

  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    test(
      '${platform.name} concurrent share preparation creates one common root and isolated transfer folders',
      () async {
        var rootExists = false, rootCreates = 0, folders = 0, transfers = 0;
        final prepared = <String>{};
        final children = <String>{};
        final lookups = <String, int>{};
        final http = FakeHttp((request) async {
          Json result(Object data) => {'code': 0, 'status': 200, 'data': data};
          switch (request.uri.path) {
            case '/1/clouddrive/file/sort':
              final visible = rootExists;
              await Future<void>.delayed(const Duration(milliseconds: 10));
              return jsonResponse(
                result({
                  'list': [
                    if (visible)
                      {'fid': 'base', 'file_name': '文析助手临时转存', 'dir': true},
                  ],
                }),
              );
            case '/1/clouddrive/file':
              if (request.json.str('pdir_fid') == '0') {
                rootCreates++;
                await Future<void>.delayed(const Duration(milliseconds: 10));
                rootExists = true;
                return jsonResponse(result({'fid': 'base'}));
              }
              expect(request.json.str('pdir_fid'), 'base');
              final id = 'temporary-${++folders}';
              children.add(id);
              return jsonResponse(result({'fid': id}));
            case '/1/clouddrive/share/sharepage/save':
              transfers++;
              final id = request.json.str('to_pdir_fid');
              expect(children, contains(id));
              return jsonResponse(result({'task_id': id}));
            case '/1/clouddrive/task':
              final id = request.uri.queryParameters['task_id']!;
              return jsonResponse(
                result({
                  'status': 2,
                  'save_as': {
                    'save_as_top_fids': ['saved-$id'],
                  },
                }),
              );
            case '/1/clouddrive/file/download':
              final id = (request.json['fids'] as List).single as String;
              final count = lookups.update(id, (n) => n + 1, ifAbsent: () => 1);
              if (count == 1) return const HttpResult(503, '{}');
              prepared.add(id);
              return jsonResponse(
                result([
                  {
                    'fid': id,
                    'file_name': 'fixture.bin',
                    'size': 4,
                    'download_url': _direct,
                  },
                ]),
              );
            default:
              throw StateError('Unexpected path ${request.uri.path}');
          }
        });
        final store = StateStore.memory();
        final vault = Vault(store);
        final credential = _credential(platform);
        await vault.putCredential(platform, credential);
        final cleanups = CleanupOutbox(store, http);
        final repository = CloudRepository(
          http,
          vault,
          cleanups,
          retryWait: (_) async {},
        );
        final staged = <DownloadCleanup>[];
        Future<void> stage(DownloadCleanup cleanup) async {
          staged.add(cleanup);
          await cleanups.stage(cleanup);
        }

        repository.connectors[platform] = platform == CloudPlatform.quark
            ? QuarkConnector(
                repository.http,
                store: vault,
                stageCleanup: stage,
                taskDelay: Duration.zero,
                directShareDownloadEnabled: (_) => false,
              )
            : UcConnector(
                repository.http,
                store: vault,
                stageCleanup: stage,
                taskDelay: Duration.zero,
                directShareDownloadEnabled: (_) => false,
              );
        final session = BrowseSession(
          platform: platform,
          mode: BrowseMode.share,
          title: 'fixture',
          rootId: '0',
          metadata: const {'shareId': 'share', 'stoken': 'fixture'},
        );
        const file = CloudFile(
          id: 'file',
          name: 'fixture.bin',
          size: 4,
          token: 'fixture-token',
        );
        final specs = await Future.wait(
          List.generate(3, (_) => repository.prepare(session, file)),
        );
        expect(specs, hasLength(3));
        expect(rootCreates, 1);
        expect(folders, 3);
        expect(transfers, 3);
        expect(prepared, hasLength(3));
        expect(lookups.values, everyElement(2));
        expect(staged.map(cleanupKey).toSet(), hasLength(3));
      },
    );
  }
}
