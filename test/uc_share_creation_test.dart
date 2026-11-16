import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/links.dart';
import 'support.dart';

const _now = 1700000000000;
const _file = CloudFile(id: 'file-1', name: 'notes.txt', size: 29);
const _secondFile = CloudFile(id: 'file-2', name: 'second.txt', size: 17);
const _folder = CloudFile(id: 'folder-1', name: 'notes', isDirectory: true);

BrowseSession _personal(CloudPlatform platform) => BrowseSession(
  platform: platform,
  mode: BrowseMode.personal,
  title: platform.label,
  rootId: '0',
);

Credential _credential(CloudPlatform platform) => Credential(platform.label, {
  'primary': '__pus=fixture-account; __puus=fixture-session',
  '${platform.name}SessionRefreshedAt': '$_now',
}, updatedAt: 42);

HttpResult _ok(Json data) =>
    jsonResponse({'status': 200, 'code': 0, 'data': data});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UC share creation response contract', () {
    for (final selection in [
      ('file', [_file]),
      ('multiple files', [_file, _secondFile]),
      ('folder', [_folder]),
    ]) {
      for (final passcode in [null, 'a123']) {
        test('${selection.$1}, extraction code $passcode', () async {
          var polls = 0;
          final http = FakeHttp((r) {
            expect(r.uri.host, 'pc-api.uc.cn');
            expect(r.uri.queryParameters['pr'], 'UCBrowser');
            expect(r.headers['Cookie'], contains('fixture-session'));
            switch (r.uri.path) {
              case '/1/clouddrive/share':
                // The official endpoint returns HTTP 500/code 15000 for a
                // JSON boolean even though login and file access succeed.
                if (r.json['public_search'] is! int) {
                  return jsonResponse({
                    'status': 500,
                    'code': 15000,
                    'message': 'inner error',
                  }, 500);
                }
                expect(r.json['public_search'], 0);
                expect(
                  r.json['fid_list'],
                  selection.$2.map((f) => f.id).toList(),
                );
                expect(r.json['url_type'], passcode == null ? 1 : 2);
                expect(r.json['passcode'], passcode);
                return _ok({'task_id': 'task-1'});
              case '/1/clouddrive/task':
                expect(r.uri.queryParameters['task_id'], 'task-1');
                return _ok(
                  ++polls == 1
                      ? {'status': 1}
                      : {
                          'status': 2,
                          'finished_at': _now,
                          'share_id': 'internal-share-id',
                        },
                );
              case '/1/clouddrive/share/password':
                expect(r.json['share_id'], 'internal-share-id');
                return _ok({
                  'pwd_id': 'public-share-id',
                  'share_url': 'https://drive.uc.cn/s/public-share-id',
                  'passcode': ?passcode,
                });
              default:
                throw StateError('Unexpected request: ${r.uri.path}');
            }
          });
          final result =
              await UcConnector(
                http,
                now: () => _now,
                taskDelay: Duration.zero,
              ).createShare(
                _personal(CloudPlatform.uc),
                selection.$2,
                ShareOptions('notes', expiryDays: 7, passcode: passcode),
                _credential(CloudPlatform.uc),
              );
          expect(result.url, 'https://drive.uc.cn/s/public-share-id');
          expect(result.passcode, passcode ?? '');
          expect(
            LinkParser.parse(result.text).single.platform,
            CloudPlatform.uc,
          );
          expect(
            http.calls.where((r) => r.uri.path.endsWith('/share')),
            hasLength(1),
          );
          expect(polls, 2);
        });
      }
    }

    test(
      'new session cookie is used after login refresh during creation',
      () async {
        final vault = Vault(StateStore.memory());
        final credential = _credential(CloudPlatform.uc);
        await vault.putCredential(CloudPlatform.uc, credential);
        var creations = 0;
        final http = FakeHttp((r) {
          switch (r.uri.path) {
            case '/1/clouddrive/config':
              return HttpResult(200, '{"status":200,"code":0,"data":{}}', {
                'set-cookie': ['__puus=renewed; Domain=.uc.cn; Path=/'],
              });
            case '/1/clouddrive/share':
              if (++creations == 1) {
                return jsonResponse({'status': 401, 'code': 31001}, 401);
              }
              expect(r.json['public_search'], 0);
              expect(r.headers['Cookie'], contains('__puus=renewed'));
              return _ok({'task_id': 'task-1'});
            case '/1/clouddrive/task':
              expect(r.headers['Cookie'], contains('__puus=renewed'));
              return _ok({'status': 2, 'share_id': 'share-1'});
            case '/1/clouddrive/share/password':
              expect(r.headers['Cookie'], contains('__puus=renewed'));
              return _ok({'share_url': 'https://drive.uc.cn/s/public-1'});
            default:
              throw StateError('Unexpected request: ${r.uri.path}');
          }
        });
        try {
          final result =
              await UcConnector(
                http,
                store: vault,
                now: () => _now,
                taskDelay: Duration.zero,
              ).createShare(
                _personal(CloudPlatform.uc),
                [_file],
                const ShareOptions('notes'),
                credential,
              );
          expect(result.url, 'https://drive.uc.cn/s/public-1');
          expect(creations, 2);
          expect(
            vault.credential(CloudPlatform.uc)!.primary,
            contains('__puus=renewed'),
          );
          expect(
            vault.credential(CloudPlatform.uc)!.updatedAt,
            credential.updatedAt,
          );
        } finally {
          vault.store.dispose();
        }
      },
    );

    test(
      'UC business rejection is reported without repeating creation',
      () async {
        final http = FakeHttp(
          (_) => jsonResponse({
            'status': 400,
            'code': 41029,
            'message': '暂时无法创建分享',
          }, 400),
        );
        await expectLater(
          UcConnector(http, now: () => _now).createShare(
            _personal(CloudPlatform.uc),
            [_file],
            const ShareOptions('notes'),
            _credential(CloudPlatform.uc),
          ),
          throwsA(
            isA<AppException>().having((e) => e.message, 'message', '暂时无法创建分享'),
          ),
        );
        expect(http.calls, hasLength(1));
      },
    );
  });

  test('Quark sharing retains its own creation parameters', () async {
    final http = FakeHttp((r) {
      expect(r.uri.host, 'drive-pc.quark.cn');
      if (r.uri.path.endsWith('/share')) {
        expect(r.json.containsKey('public_search'), isFalse);
        expect(r.json['support_error_code'], ['41060']);
        return _ok({'task_id': 'task-1'});
      }
      if (r.uri.path.endsWith('/task')) {
        return _ok({'status': 2, 'share_id': 'share-1'});
      }
      return _ok({'share_url': 'https://pan.quark.cn/s/public-1'});
    });
    final result =
        await QuarkConnector(
          http,
          now: () => _now,
          taskDelay: Duration.zero,
        ).createShare(
          _personal(CloudPlatform.quark),
          [_file],
          const ShareOptions('notes'),
          _credential(CloudPlatform.quark),
        );
    expect(result.url, 'https://pan.quark.cn/s/public-1');
  });
}
