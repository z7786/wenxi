import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/auth.dart';
import 'support.dart';

void main() {
  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    final domain = platform == CloudPlatform.quark ? 'quark.cn' : 'uc.cn';
    final share = BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: 'share',
      rootId: '0',
      metadata: {
        'shareId': 'share-id',
        'stoken': 'share-token',
        'cookie': '__pus=must-not-leak; __puus=old',
      },
    );
    const file = CloudFile(
      id: 'file-id',
      name: 'original.bin',
      size: 400,
      token: 'file-token',
    );
    final owner = Credential('cookie', {
      'primary': '__pus=owner; __puus=old',
      'quarkSessionRefreshedAt': '${DateTime.now().millisecondsSinceEpoch}',
      'ucSessionRefreshedAt': '${DateTime.now().millisecondsSinceEpoch}',
    }, updatedAt: 42);
    final blocked = jsonResponse({'status': 400, 'code': 23018}, 400);
    HttpResult link({
      String id = 'file-id',
      String cookie = '__pugs=guest',
      String? url,
    }) => HttpResult(
      200,
      jsonEncode({
        'status': 200,
        'code': 0,
        'data': [
          {
            'fid': id,
            'size': 400,
            'download_url': url ?? 'https://dl.$domain/original',
          },
        ],
      }),
      {
        'set-cookie': ['$cookie; Path=/; Secure'],
      },
    );
    const content = HttpResult(206, 'x', {
      'content-range': ['bytes 0-0/400'],
      'content-length': ['1'],
    });

    final recoverableShare = share.withLink(
      ParsedLink(
        source: 'https://pan.$domain/s/share-id',
        url: 'https://pan.$domain/s/share-id',
        kind: LinkKind.cloudShare,
        platform: platform,
        shareId: 'share-id',
      ),
    );
    HttpResult refreshedFiles({String id = 'file-id', int size = 400}) =>
        jsonResponse({
          'status': 200,
          'data': {
            'list': [
              {
                'fid': id,
                'file_name': 'original.bin',
                'size': size,
                'share_fid_token': 'fresh-file-token',
              },
            ],
          },
        });

    test('${platform.key} expired tokens refresh the same file once', () async {
      var downloads = 0;
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/token')) {
          expect(r.headers['Cookie'], isEmpty);
          return jsonResponse({
            'status': 200,
            'data': {'stoken': 'fresh-token'},
          });
        }
        if (r.uri.path.endsWith('/detail')) {
          expect(r.uri.queryParameters['stoken'], 'fresh-token');
          return refreshedFiles();
        }
        if (r.uri.path.endsWith('/download')) {
          downloads++;
          if (downloads == 1) {
            return jsonResponse({'status': 400, 'code': 41020}, 400);
          }
          expect(r.json['stoken'], 'fresh-token');
          expect(r.json['fids_token'], ['fresh-file-token']);
          return link();
        }
        return content;
      });
      final connector = platform == CloudPlatform.quark
          ? QuarkConnector(http)
          : UcConnector(http);
      final spec = await connector.download(recoverableShare, file, null);
      expect(spec.expectedSize, 400);
      expect(spec.cleanup, isNull);
      expect(downloads, 2);
      expect(http.calls, hasLength(5));
    });

    test(
      '${platform.key} restricted fallback receives refreshed context',
      () async {
        var downloads = 0;
        final vault = Vault(
          StateStore.memory({
            'credentials': {platform.key: owner.toJson()},
          }),
        );
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/token')) {
            return jsonResponse({
              'status': 200,
              'data': {'stoken': 'fresh-token'},
            });
          }
          if (r.uri.path.endsWith('/detail')) return refreshedFiles();
          expect(r.uri.path.endsWith('/download'), isTrue);
          return ++downloads == 1 ? const HttpResult(404, '', {}) : blocked;
        });
        final connector = platform == CloudPlatform.quark
            ? QuarkConnector(http, store: vault)
            : UcConnector(http, store: vault);
        BrowseSession? refreshedSession;
        CloudFile? refreshedFile;
        final result = await connector.tryShareDownload(
          recoverableShare,
          file,
          owner,
          onRefreshed: (session, item) {
            refreshedSession = session;
            refreshedFile = item;
          },
        );
        expect(result, isNull);
        expect(downloads, 3);
        expect(refreshedSession!.meta('stoken'), 'fresh-token');
        expect(refreshedFile!.id, file.id);
        expect(refreshedFile!.token, 'fresh-file-token');
      },
    );

    for (final failure in [
      const HttpResult(404, 'missing', {}),
      const HttpResult(200, '<html>maintenance</html>', {}),
      jsonResponse({'status': 200, 'data': []}),
    ]) {
      for (final accountMode in ['none', 'working', 'broken']) {
        test(
          '${platform.key} unavailable ${failure.status}/${failure.body.length} '
          'uses bounded recovery with $accountMode account',
          () async {
            var downloads = 0;
            final vault = Vault(
              StateStore.memory({
                'credentials': {platform.key: owner.toJson()},
              }),
            );
            final http = FakeHttp((r) {
              if (r.uri.path.endsWith('/token')) {
                expect(r.headers['Cookie'], isEmpty);
                return jsonResponse({
                  'status': 200,
                  'data': {'stoken': 'fresh-token'},
                });
              }
              if (r.uri.path.endsWith('/detail')) return refreshedFiles();
              if (r.uri.path.endsWith('/download')) {
                downloads++;
                if (downloads <= 2) {
                  expect(r.headers['Cookie'], isEmpty);
                  return failure;
                }
                expect(r.headers['Cookie'], contains('__pus=owner'));
                expect(r.json['stoken'], 'fresh-token');
                return accountMode == 'working' ? link() : failure;
              }
              expect(r.uri.host, 'dl.$domain');
              return content;
            });
            final connector = platform == CloudPlatform.quark
                ? QuarkConnector(http, store: vault)
                : UcConnector(http, store: vault);
            final future = connector.tryShareDownload(
              recoverableShare,
              file,
              accountMode == 'none' ? null : owner,
            );
            if (accountMode == 'working') {
              expect((await future)!.cleanup, isNull);
            } else {
              await expectLater(
                future,
                throwsA(
                  accountMode == 'none'
                      ? isA<AccountLoginRequired>()
                      : isA<AppException>(),
                ),
              );
            }
            expect(downloads, accountMode == 'none' ? 2 : 3);
            expect(
              http.calls.where((r) => r.uri.path.endsWith('/token')),
              hasLength(1),
            );
            expect(
              http.calls,
              hasLength(
                accountMode == 'working'
                    ? 6
                    : accountMode == 'none'
                    ? 4
                    : 5,
              ),
            );
          },
        );
      }
    }

    for (final changed in [
      refreshedFiles(id: 'replacement'),
      refreshedFiles(size: 401),
    ]) {
      test(
        '${platform.key} changed share file stops recovery ${changed.body}',
        () async {
          final http = FakeHttp((r) {
            if (r.uri.path.endsWith('/token')) {
              return jsonResponse({
                'status': 200,
                'data': {'stoken': 'fresh-token'},
              });
            }
            if (r.uri.path.endsWith('/detail')) return changed;
            expect(r.uri.path.endsWith('/download'), isTrue);
            return const HttpResult(404, '', {});
          });
          final connector = platform == CloudPlatform.quark
              ? QuarkConnector(http)
              : UcConnector(http);
          await expectLater(
            connector.tryShareDownload(recoverableShare, file, owner),
            throwsA(isA<AppException>()),
          );
          expect(http.calls, hasLength(3));
        },
      );
    }

    test(
      '${platform.key} guest success never uses or changes saved credentials',
      () async {
        final vault = Vault(
          StateStore.memory({
            'credentials': {platform.key: owner.toJson()},
          }),
        );
        final http = FakeHttp((r) {
          if (r.method == 'POST') {
            expect(r.uri.path, '/1/clouddrive/file/download');
            expect(r.headers['Cookie'], isEmpty);
            expect(r.json, {
              'fids': ['file-id'],
              'fids_token': ['file-token'],
              'pwd_id': 'share-id',
              'stoken': 'share-token',
              if (platform == CloudPlatform.quark) ...{
                'speedup_session': '',
                'token': '',
              },
            });
            if (platform == CloudPlatform.uc) {
              expect(r.headers['User-Agent'], contains('uc-cloud-drive/1.8.8'));
              expect(r.headers['Sec-Ch-Ua'], contains('"Chromium";v="100"'));
            }
            return link();
          }
          expect(r.headers['Cookie'], '__pugs=guest');
          return content;
        });
        final connector = platform == CloudPlatform.quark
            ? QuarkConnector(http, store: vault)
            : UcConnector(http, store: vault);
        final spec = (await connector.tryShareDownload(share, file, owner))!;
        expect(spec.cleanup, isNull);
        expect(spec.expectedSize, 400);
        expect(spec.headers['Cookie'], '__pugs=guest');
        expect(
          spec.headers['User-Agent'],
          http.calls.first.headers['User-Agent'],
        );
        expect(
          spec.headers['Sec-Ch-Ua'],
          http.calls.first.headers['Sec-Ch-Ua'],
        );
        expect(vault.credential(platform)!.primary, owner.primary);
        expect(http.calls, hasLength(2));
      },
    );

    test(
      '${platform.key} parallel guest links keep their own response cookies',
      () async {
        final secondReturned = Completer<void>();
        final http = FakeHttp((r) async {
          if (r.method == 'POST') {
            expect(r.headers['Cookie'], isEmpty);
            final id = (r.json['fids'] as List).single as String;
            if (id == 'first') {
              await secondReturned.future;
            } else {
              secondReturned.complete();
            }
            return link(
              id: id,
              cookie: '__pugs=$id',
              url: 'https://dl.$domain/$id',
            );
          }
          expect(r.headers['Cookie'], '__pugs=${r.uri.pathSegments.last}');
          if (platform == CloudPlatform.uc) {
            expect(r.headers['Sec-Ch-Ua'], contains('"Chromium";v="100"'));
          }
          return content;
        });
        final connector = platform == CloudPlatform.quark
            ? QuarkConnector(http)
            : UcConnector(http);
        final specs = await Future.wait([
          for (final id in ['first', 'second'])
            connector.download(
              share,
              CloudFile(id: id, name: '$id.bin', size: 400, token: 'token-$id'),
              null,
            ),
        ]);
        expect(specs.map((s) => s.headers['Cookie']), [
          '__pugs=first',
          '__pugs=second',
        ]);
      },
    );

    test(
      '${platform.key} guest restriction retries with account and renewed cookie',
      () async {
        final vault = Vault(
          StateStore.memory({
            'credentials': {platform.key: owner.toJson()},
          }),
        );
        final http = FakeHttp((r) {
          if (r.method == 'POST') {
            if (r.headers['Cookie']!.isEmpty) return blocked;
            expect(r.headers['Cookie'], contains('__pus=owner'));
            return link(cookie: '__puus=renewed');
          }
          expect(r.headers['Cookie'], contains('__puus=renewed'));
          return content;
        });
        final connector = platform == CloudPlatform.quark
            ? QuarkConnector(http, store: vault)
            : UcConnector(http, store: vault);
        final spec = (await connector.tryShareDownload(share, file, owner))!;
        expect(spec.cleanup, isNull);
        expect(spec.headers['Cookie'], contains('__puus=renewed'));
        expect(vault.credential(platform)!.updatedAt, owner.updatedAt);
        expect(http.calls, hasLength(3));
      },
    );

    test(
      '${platform.key} guest restriction requests login without transfer',
      () async {
        final http = FakeHttp((_) => blocked);
        final connector = platform == CloudPlatform.quark
            ? QuarkConnector(http)
            : UcConnector(http);
        await expectLater(
          connector.download(share, file, null),
          throwsA(
            isA<AccountLoginRequired>().having(
              (error) => error.message,
              'message',
              platform == CloudPlatform.quark
                  ? '夸克游客不支持超过50MB文件下载，请登录夸克网盘再试'
                  : '${platform.shortName}此文件不支持游客下载，请登录后重试',
            ),
          ),
        );
        expect(http.calls, hasLength(1));
      },
    );

    test(
      '${platform.key} mismatched file and untrusted CDN never receive cookies',
      () async {
        for (final bad in [
          link(id: 'other'),
          link(url: 'https://example.com/file'),
        ]) {
          final http = FakeHttp((_) => bad);
          final connector = platform == CloudPlatform.quark
              ? QuarkConnector(http)
              : UcConnector(http);
          await expectLater(
            connector.download(share, file, null),
            throwsA(isA<AppException>()),
          );
          expect(http.calls, hasLength(1));
        }
      },
    );

    test(
      '${platform.key} network errors do not create temporary files',
      () async {
        final http = FakeHttp(
          (_) => throw const AppException('network unavailable'),
        );
        final connector = platform == CloudPlatform.quark
            ? QuarkConnector(http)
            : UcConnector(http);
        await expectLater(
          connector.tryShareDownload(share, file, owner),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(1));
      },
    );

    test(
      '${platform.key} replacement content and malformed ranges are rejected',
      () async {
        for (final probe in [
          const HttpResult(206, 'x', {
            'content-range': ['bytes 0-0/123'],
          }),
          const HttpResult(206, 'x', {
            'content-range': ['bytes 1-1/400'],
          }),
          const HttpResult(206, 'x', {
            'content-range': ['bytes 0-0/400'],
            'content-encoding': ['gzip'],
          }),
        ]) {
          final http = FakeHttp((r) => r.method == 'POST' ? link() : probe);
          final connector = platform == CloudPlatform.quark
              ? QuarkConnector(http)
              : UcConnector(http);
          await expectLater(
            connector.download(share, file, null),
            throwsA(isA<AppException>()),
          );
          expect(http.calls, hasLength(2));
        }
      },
    );
  }
}
