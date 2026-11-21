import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/domain/settings.dart';
import 'support.dart';

Credential mobileCredential([int revision = 1]) => Credential('测试移动账号', {
  'authorization':
      'Basic ${base64Encode(utf8.encode('pc:13800000000:test-token'))}',
  'primary': 'skey=test-key; ud_id=test-domain',
}, updatedAt: revision);

HttpResult mobileResponse(Json data) =>
    jsonResponse({'success': true, 'code': '0', 'data': data});

class MobileFamilyFixture {
  MobileFamilyFixture() {
    http = FakeHttp(respond);
    store = StateStore.memory({
      'credentials': {'C139': mobileCredential().toJson()},
    });
    repository = CloudRepository(
      http,
      Vault(store),
      CleanupOutbox(store, http),
    );
  }
  late final FakeHttp http;
  late final StateStore store;
  late final CloudRepository repository;
  bool removed = false;
  HttpResult respond(RecordedRequest request) {
    final body = request.json;
    if (request.uri.path.endsWith('/queryFamilyCloud')) {
      return mobileResponse({
        'familyCloudList': [
          if (!removed) {'cloudID': 'family-a', 'cloudName': '周末相册'},
          {'cloudID': 'family-b', 'cloudName': '家人的云盘'},
        ],
        'totalCount': removed ? 1 : 2,
      });
    }
    final family = body.str('cloudID');
    final parent = body.str('catalogID');
    if (request.uri.path.endsWith('/queryContentList')) {
      return mobileResponse({
        'result': {'resultCode': '0'},
        'path': 'root:/root-$family${parent.isEmpty ? '' : '/$parent'}',
        'totalCount': parent.isEmpty ? 2 : 1,
        'cloudCatalogList': [
          if (parent.isEmpty) {'catalogID': 'holiday', 'catalogName': '假期'},
        ],
        'cloudContentList': [
          if (body.obj('pageInfo').integer('pageSize') != 1)
            {
              'contentID': 'clip',
              'contentName': '假期.mp4',
              'contentSize': 4000,
              'lastUpdateTime': '2026-09-01 12:00:00',
              'thumbnailURL':
                  'https://preview.example.test/$family/clip.jpg?signature=temporary',
            },
        ],
      });
    }
    if (request.uri.path.endsWith('/getFileDownLoadURL')) {
      return mobileResponse({
        'downloadURL':
            'https://media.example.test/$family/clip?signature=download',
      });
    }
    throw StateError('Unexpected route ${request.uri.path}');
  }
}

void main() {
  test(
    'Display preference survives settings edits and older settings default to list',
    () {
      expect(AppSettings.fromJson({}).browserView, 'list');
      expect(
        AppSettings.fromJson({'browserView': 'invalid'}).browserView,
        'list',
      );
      final settings = const AppSettings()
          .update({'browserView': 'grid'})
          .update({'theme': 'Dark'});
      expect(AppSettings.fromJson(settings.toJson()).browserView, 'grid');
      expect(settings.theme, 'Dark');
    },
  );

  test(
    'Tianyi families use signed endpoints, independent roots and paged previews',
    () async {
      final credential = Credential('天翼', {
        'primary': 'COOKIE_LOGIN_USER=test-cookie',
      });
      final http = FakeHttp((request) {
        final path = request.uri.path, params = request.uri.queryParameters;
        if (path.endsWith('/getUserBriefInfo.action')) {
          expect(
            request.headers['Cookie'],
            contains('COOKIE_LOGIN_USER=test-cookie'),
          );
          return jsonResponse({'sessionKey': 'family-test-session'});
        }
        if (path.endsWith('/getAccessTokenBySsKey.action')) {
          return jsonResponse({'accessToken': 'family-test-token'});
        }
        expect(request.uri.host, 'api.cloud.189.cn');
        expect(request.headers['AccessToken'], 'family-test-token');
        expect(request.headers['Cookie'], isNull);
        if (path.endsWith('/getFamilyList.action')) {
          return jsonResponse({
            'familyInfoResp': [
              {'familyId': 12001, 'remarkName': '我们的家庭'},
              {'familyId': 12002, 'remarkName': '工作资料'},
            ],
          });
        }
        expect(params['familyId'], '12001');
        if (path.endsWith('/listFiles.action')) {
          expect(path, '/open/family/file/listFiles.action');
          expect(params['folderId'], '');
          expect(params['iconOption'], '5');
          final page = int.parse(params['pageNum']!);
          return jsonResponse({
            'fileListAO': {
              'count': 61,
              'folderList': [],
              'fileList': [
                for (var i = page == 1 ? 0 : 60; i < (page == 1 ? 60 : 61); i++)
                  {
                    'id': '$i',
                    'name': '照片$i.jpg',
                    'size': 400,
                    'icon': {
                      'largeUrl': 'https://preview.example.test/$i.jpg',
                      'smallUrl': 'https://preview.example.test/small.jpg',
                    },
                  },
              ],
            },
          });
        }
        expect(path, '/open/family/file/getFileDownloadUrl.action');
        return jsonResponse({
          'fileDownloadUrl':
              'https://media.example.test/photo.jpg?signature=temporary',
        });
      });
      final connector = TianyiConnector(http);
      final spaces = await connector.familySpaces(credential);
      expect(spaces.map((s) => s.name), ['我们的家庭', '工作资料']);
      final session = await connector.openFamily(spaces.first, credential);
      expect(session.rootId, isEmpty);
      expect(session.isFamily, isTrue);
      final files = await connector.list(session, session.rootId, credential);
      expect(files, hasLength(61));
      expect(files.first.parentId, isEmpty);
      expect(files.first.thumbnailUrl, 'https://preview.example.test/0.jpg');
      final spec = await connector.playback(session, files.first, credential);
      expect(
        spec.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(files.first.toJson(), isNot(contains('thumbnailUrl')));
      expect(CloudFile.fromJson(files.first.toJson()).thumbnailUrl, isEmpty);
      expect(
        http.calls.skip(2).every((r) => r.uri.path.contains('/family/')),
        isTrue,
      );
    },
  );

  test(
    'Mobile family selection, download refresh and recent playback keep the same family',
    () async {
      final fixture = MobileFamilyFixture();
      final repository = fixture.repository;
      final session = await repository.family(CloudPlatform.c139, 'family-a');
      expect(session.rootId, 'root-family-a');
      final rootFiles = await repository.list(session, session.rootId);
      expect(rootFiles.where((f) => f.isDirectory).single.id, 'holiday');
      final files = await repository.list(session, 'holiday');
      expect(files.single.token, 'root:/root-family-a/holiday');
      final spec = await repository.prepare(session, files.single);
      final refresh = await repository.refresh(
        DownloadSpec.fromJson(spec.toJson()),
      );
      expect(refresh.url, contains('/family-a/clip'));
      final source = PlaybackSource.cloud(
        DownloadOrigin(session, files.single, 1),
      );
      final saved = source.toJson();
      expect(saved.obj('origin').obj('session').obj('metadata'), {
        'familyId': 'family-a',
        'familyName': '周末相册',
      });
      expect(encoded(saved), isNot(contains('temporary')));
      expect(encoded(saved), isNot(contains('test-token')));
      final restored = await repository.restoreOrigin(
        PlaybackSource.tryFromJson(saved)!.cloud!,
      );
      expect(restored.session.familyId, 'family-a');
      expect(restored.file.token, 'root:/root-family-a/holiday');
      expect(restored.file.thumbnailUrl, isNotEmpty);
      for (final request in fixture.http.calls) {
        expect(request.uri.host, 'yun.139.com');
        expect(request.uri.path, contains('/familyCloud-rebuild/'));
        expect(request.headers['x-SvcType'], '2');
        expect(request.headers['x-yun-svc-type'], '2');
        expect(request.headers['Cookie'], contains('skey=test-key'));
        expect(request.headers['mcloud-skey'], 'test-key');
        expect(
          request.headers['mcloud-userid-flag'],
          request.uri.path.endsWith('/getFileDownLoadURL') ? isNull : '1',
        );
        final signature = request.headers['mcloud-sign']!.split(',');
        expect(
          signature[2],
          C139Protocol.calculateSign(
            request.body as String,
            signature[0],
            signature[1],
          ),
        );
      }
      final download = fixture.http.calls.lastWhere(
        (r) => r.uri.path.endsWith('/getFileDownLoadURL'),
      );
      expect(download.json['path'], 'root:/root-family-a/holiday');
      expect(download.json['cloudID'], 'family-a');
      expect(download.json['commonAccountInfo'], {
        'account': '13800000000',
        'accountType': 1,
      });
    },
  );

  test('A removed family is not reopened as personal cloud', () async {
    final fixture = MobileFamilyFixture();
    final session = await fixture.repository.family(
      CloudPlatform.c139,
      'family-a',
    );
    final file = (await fixture.repository.list(session, 'holiday')).single;
    fixture.removed = true;
    final before = fixture.http.calls.length;
    await expectLater(
      fixture.repository.restoreOrigin(DownloadOrigin(session, file, 1)),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('无法访问'),
        ),
      ),
    );
    expect(fixture.http.calls.skip(before).map((r) => r.uri.path), [
      '/orchestration/familyCloud-rebuild/cloudManage/v1.0/queryFamilyCloud',
    ]);
  });

  test(
    'Mobile discovery pages all families and rejects repeated pages',
    () async {
      var repeat = false;
      final http = FakeHttp(
        (r) => mobileResponse({
          'totalCount': 2,
          'familyCloudList': [
            {
              'cloudID': repeat
                  ? 'same'
                  : 'family-${r.json.obj('pageInfo').integer('pageNum')}',
              'cloudName': '家庭',
            },
          ],
        }),
      );
      final connector = C139Connector(http);
      expect(
        (await connector.familySpaces(mobileCredential())).map((s) => s.id),
        ['family-1', 'family-2'],
      );
      repeat = true;
      await expectLater(
        connector.familySpaces(mobileCredential()),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(4));
    },
  );

  test(
    'Mobile family file pagination rejects missing, repeated and wrong-root results',
    () async {
      final fixture = MobileFamilyFixture();
      final session = await fixture.repository.family(
        CloudPlatform.c139,
        'family-a',
      );
      for (final malformed in ['missing', 'repeat', 'foreign']) {
        final http = FakeHttp(
          (r) => mobileResponse({
            'path': malformed == 'foreign'
                ? 'root:/another-family'
                : 'root:/root-family-a',
            'totalCount': malformed == 'foreign' ? 0 : 2,
            if (malformed == 'repeat')
              'cloudContentList': [
                {
                  'contentID': 'one',
                  'contentName': '照片.jpg',
                  'contentSize': 42,
                },
              ],
          }),
        );
        await expectLater(
          C139Connector(http).list(session, session.rootId, mobileCredential()),
          throwsA(isA<AppException>()),
          reason: malformed,
        );
        expect(http.calls.length, lessThanOrEqualTo(2));
      }
    },
  );

  test(
    'Nested family login failures and empty membership are distinguished',
    () async {
      final empty = C139Connector(
        FakeHttp(
          (_) => mobileResponse({'totalCount': 0, 'familyCloudList': []}),
        ),
      );
      expect(await empty.familySpaces(mobileCredential()), isEmpty);
      final expired = C139Connector(
        FakeHttp(
          (_) => mobileResponse({
            'result': {'resultCode': '04000005'},
            'familyCloudList': [],
            'totalCount': 0,
          }),
        ),
      );
      await expectLater(
        expired.familySpaces(mobileCredential()),
        throwsA(isA<AccountLoginRequired>()),
      );
      final forbidden = C139Connector(
        FakeHttp(
          (_) => mobileResponse({
            'result': {'resultCode': 'PermissionDenied'},
            'familyCloudList': [],
            'totalCount': 0,
          }),
        ),
      );
      await expectLater(
        forbidden.familySpaces(mobileCredential()),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'Family mutations are rejected before reaching personal endpoints',
    () async {
      final c = mobileCredential();
      for (final connector in <CloudConnector>[
        C139Connector(FakeHttp()),
        TianyiConnector(FakeHttp()),
      ]) {
        final account = connector.platform == CloudPlatform.c139
            ? c
            : Credential('天翼', {'primary': 'COOKIE_LOGIN_USER=test-cookie'});
        final session = BrowseSession(
          platform: connector.platform,
          mode: BrowseMode.personal,
          title: '家庭',
          rootId: '',
          metadata: {'familyId': '12001'},
        );
        const file = CloudFile(id: 'file', name: '文件.txt');
        for (final action in <Future<void> Function()>[
          () => connector.rename(session, file, '更名.txt', account),
          () => connector.move(session, [file], 'target', account),
          () => connector.delete(session, [file], account),
          () async {
            await connector.createFolder(session, '', '文件夹', account);
          },
          () async {
            await connector.createShare(
              session,
              [file],
              const ShareOptions('分享'),
              account,
            );
          },
        ]) {
          await expectLater(action(), throwsA(isA<AppException>()));
        }
        expect(session.canManageFiles, isFalse);
        final http = connector is C139Connector
            ? connector.http
            : (connector as TianyiConnector).http;
        expect((http as FakeHttp).calls, isEmpty);
      }
    },
  );

  test(
    'Family account changes stop opening and cancellation stops pagination',
    () async {
      final result = Completer<HttpResult>();
      final started = Completer<void>();
      final http = FakeHttp((_) {
        started.complete();
        return result.future;
      });
      final store = StateStore.memory({
        'credentials': {'C139': mobileCredential().toJson()},
      });
      final repository = CloudRepository(
        http,
        Vault(store),
        CleanupOutbox(store, http),
      );
      final opening = repository.family(CloudPlatform.c139, 'family-a');
      final failed = expectLater(opening, throwsA(isA<AppException>()));
      await started.future;
      await store.put('credentials', {'C139': mobileCredential(2).toJson()});
      result.complete(
        mobileResponse({
          'familyCloudList': [
            {'cloudID': 'family-a', 'cloudName': '家庭'},
          ],
          'totalCount': 1,
        }),
      );
      await failed;
      expect(http.calls, hasLength(1));
      final scope = RequestScope();
      final cancelledHttp = FakeHttp((_) {
        scope.cancel();
        return mobileResponse({
          'familyCloudList': [
            {'cloudID': 'family-a'},
          ],
          'totalCount': 2,
        });
      });
      await expectLater(
        scope.run(
          () => C139Connector(cancelledHttp).familySpaces(mobileCredential()),
        ),
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '请求已取消'),
        ),
      );
      expect(cancelledHttp.calls, hasLength(1));
    },
  );

  test(
    'Playback identity distinguishes families with overlapping file identifiers',
    () {
      const file = CloudFile(id: 'clip', name: '视频.mp4', size: 42);
      BrowseSession session(String id) => BrowseSession(
        platform: CloudPlatform.tianyi,
        mode: BrowseMode.personal,
        title: '云盘',
        rootId: '',
        metadata: {if (id.isNotEmpty) 'familyId': id},
      );
      final identities = [
        '',
        '12001',
        '12002',
      ].map((id) => cloudPlaybackKey(session(id), file, 1));
      expect(identities.toSet(), hasLength(3));
      expect(
        cloudPlaybackKey(session(''), file, 1),
        playbackKey(['Tianyi', 'personal', 1, '', 'clip', 42, '', null, null]),
      );
    },
  );
}
