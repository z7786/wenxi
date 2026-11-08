import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'package:asterlink/playback/recent_playback.dart';
import 'player_support.dart';
import 'support.dart';

// Protocol fixtures transcribed from MoePal's 0x8d677c / 0x8d6520 / 0x8c59f8.
// All identities and tokens below are local fixtures. No live accounts are read.
const _pc = '3000008641494773';
const _conversation = '3000001111111111';
const _file = CloudFile(
  id: 'video-1',
  name: '第一集-private-name.mp4',
  size: 4096,
  parentId: '0',
  token: 'private-share-file-token',
);
const _second = CloudFile(
  id: 'video-2',
  name: '第二集.mp4',
  size: 4096,
  parentId: '0',
  token: 'private-second-token',
);
const _personal = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: '0',
);
final _link = ParsedLink(
  source: 'https://pan.quark.cn/s/fixture',
  url: 'https://pan.quark.cn/s/fixture',
  kind: LinkKind.cloudShare,
  platform: CloudPlatform.quark,
  shareId: 'fixture',
  passcode: 'abcd',
);
final _share = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.share,
  title: 'fixture',
  rootId: '0',
  sourceLink: _link,
  metadata: const {'shareId': 'fixture', 'stoken': 'private-share-token'},
);

HttpResult _ok(Object? data, {String? cookie}) => HttpResult(
  200,
  encoded({'status': 200, 'code': 0, 'data': data}),
  cookie == null
      ? {}
      : {
          'set-cookie': ['__puus=$cookie; Path=/; HttpOnly'],
        },
);

Json _msg({Object id = '2000000000000001', String? fid = 'video-1'}) => {
  'store_msg_id': id,
  'conversation_id': _conversation,
  'extra': {
    'custom_extra': {
      'file': {'fid': ?fid},
    },
  },
};

class _Fixture {
  _Fixture() {
    account = Credential('fixture', {
      'primary': '__pus=private-account; __puus=private-old-cookie',
      'quarkSessionRefreshedAt': '${DateTime.now().millisecondsSinceEpoch}',
      'ucSessionRefreshedAt': '${DateTime.now().millisecondsSinceEpoch}',
    }, updatedAt: 42);
    store = StateStore.memory({
      'settings': const AppSettings().toJson(),
      'credentials': {
        CloudPlatform.quark.key: account.toJson(),
        CloudPlatform.uc.key: account.toJson(),
      },
    });
    vault = Vault(store);
    http = FakeHttp(
      (request) async => await intercept?.call(request) ?? reply(request),
    );
    cleanups = CleanupOutbox(store, http);
    repository = CloudRepository(
      http,
      vault,
      cleanups,
      directShareDownloadEnabled: (platform, authenticated) =>
          platform == CloudPlatform.quark &&
          authenticated &&
          AppSettings.fromJson(
            store.data.obj('settings'),
          ).quarkAuthenticatedDirectDownload,
    );
  }
  late final Credential account;
  late final StateStore store;
  late final Vault vault;
  late final FakeHttp http;
  late final CleanupOutbox cleanups;
  late final CloudRepository repository;
  FutureOr<HttpResult?> Function(RecordedRequest)? intercept;
  int directories = 0, messages = 0;
  int fileSize = _file.size;
  bool capacityExceeded = false;
  bool directAvailable = true;
  final tasks = <String, String>{};
  final messageFiles = <String, String>{};

  List<RecordedRequest> calls(String suffix) =>
      http.calls.where((r) => r.uri.path.endsWith(suffix)).toList();
  CloudFile get selectedFile =>
      CloudFile.fromJson({..._file.toJson(), 'size': fileSize});
  Future<DownloadSpec> play([BrowseSession session = _personal]) =>
      repository.preparePlayback(session, selectedFile);

  HttpResult reply(RecordedRequest r) {
    if (r.uri.host == 'dl.quark.cn') {
      return HttpResult(206, 'x', {
        'content-range': ['bytes 0-0/$fileSize'],
        'content-length': ['1'],
      });
    }
    switch (r.uri.path) {
      case '/1/clouddrive/config':
        return _ok({});
      case '/1/clouddrive/share/sharepage/token':
        return _ok({'stoken': 'private-share-token', 'first_fid': '0'});
      case '/1/clouddrive/file/sort':
      case '/1/clouddrive/share/sharepage/detail':
        return _ok({
          'list': [
            for (final file in [_file, _second])
              {
                'fid': file.id,
                'file_name': file.name,
                'size': file.id == _file.id ? fileSize : file.size,
                'pdir_fid': '0',
                'share_fid_token': file.token,
                'dir': false,
              },
            {'fid': 'base-folder', 'file_name': '文析助手临时转存', 'dir': true},
          ],
        });
      case '/1/clouddrive/file':
        return _ok({'fid': 'temporary-${++directories}'});
      case '/1/clouddrive/share/sharepage/save':
        if (capacityExceeded) {
          return jsonResponse({
            'status': 400,
            'code': 32003,
            'message': 'capacity limit[{0}]',
          }, 400);
        }
        final id = 'task-${tasks.length + 1}';
        tasks[id] = 'saved-${r.json['fid_list'][0]}-$directories';
        return _ok({'task_id': id});
      case '/1/clouddrive/task':
        return _ok({
          'status': 2,
          'save_as': {
            'save_as_top_fids': [tasks[r.uri.queryParameters['task_id']]],
          },
        });
      case '/1/clouddrive/chat/conv/msg/batch_send':
        final fid = r.json['conversations'][0]['file_list'][0]['fid'] as String;
        final id = '${2000000000000000 + ++messages}';
        messageFiles[id] = fid;
        return _ok({
          'send_msg_list': [_msg(id: id, fid: fid)],
        });
      case '/1/clouddrive/chat/conv/file/acquire_dl_token':
        return _ok({'token': 'private-dl-token-${r.json['msg_id']}'});
      case '/1/clouddrive/file/download':
        final fid = r.json['fids'][0] as String;
        if (r.json.containsKey('pwd_id')) {
          if (!directAvailable) {
            return jsonResponse({'status': 400, 'code': 23018}, 400);
          }
          return _ok([
            {
              'fid': fid,
              'size': fileSize,
              'download_url': 'https://dl.quark.cn/share-original',
            },
          ]);
        }
        return _ok([
          {
            'fid': fid,
            'size': fileSize,
            'download_url':
                'https://media.example/$fid?sig=private-url&key=1&key=2',
          },
        ]);
      case '/1/clouddrive/file/delete':
        return _ok({});
      default:
        throw StateError('Unexpected fixture request ${r.uri.path}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture f;
  setUp(() => f = _Fixture());

  test(
    'Personal playback follows the recovered three-stage request contract',
    () async {
      final source = await f.play();
      final batch = f.calls('/batch_send').single;
      expect(batch.method, 'POST');
      expect(batch.uri.host, 'drive-social-api.quark.cn');
      expect(batch.uri.queryParameters, {
        'pr': 'ucpro',
        'fr': 'pc',
        'sys': 'win32',
        've': '3.19.0',
      });
      final extras =
          batch.json['conversations'][0]['file_list'][0]['client_extra'];
      expect(extras['group_id'], matches(r'^\d{19}$'));
      expect(extras['local_msg_id'], matches(r'^\d{19}$'));
      expect(batch.json, {
        'conversations': [
          {
            'merge_file': 0,
            'conversation_id': _pc,
            'conversation_type': 3,
            'file_list': [
              {
                'fid': _file.id,
                'content': _file.name,
                'client_extra': {
                  'group_id': extras['group_id'],
                  'device_model': 'Administrator',
                  'local_msg_id': extras['local_msg_id'],
                },
              },
            ],
          },
        ],
        'return_msg_as_list': 1,
      });
      final token = f.calls('/acquire_dl_token').single;
      expect(token.uri.host, batch.uri.host);
      expect(token.uri.queryParameters, batch.uri.queryParameters);
      expect(token.json, {
        'conversation_id': _conversation,
        'conversation_type': 3,
        'msg_id': '2000000000000001',
      });
      final download = f.calls('/file/download').single;
      expect(download.uri.host, 'drive-pc.quark.cn');
      expect(download.uri.queryParameters, {
        'pr': 'ucpro',
        'fr': 'pc',
        'sys': 'win32',
        've': '3.23.2',
      });
      expect(download.json, {
        'fids': [_file.id],
        'speedup_session': '',
        'token': 'private-dl-token-2000000000000001',
      });
      expect(
        source.url,
        'https://media.example/video-1?sig=private-url&key=1&key=2',
      );
      expect(source.fileName, _file.name);
      expect(source.expectedSize, _file.size);
      for (final headers in [
        ...f.http.calls.map((r) => r.headers),
        source.headers,
      ]) {
        expect(headers['Cookie'], f.account.primary);
        expect(headers['User-Agent'], QuarkConnector.cloudUa);
        expect(headers['Referer'], 'https://pan.quark.cn/');
        expect(headers['Origin'], 'https://pan.quark.cn');
      }
      expect(f.http.calls, hasLength(3));
      expect(source.cleanup, isNull);
    },
  );

  test(
    'Renewed cookies propagate between fast stages and into the player',
    () async {
      f.intercept = (r) {
        final original = f.reply(r);
        return HttpResult(original.status, original.body, {
          'set-cookie': [
            '__puus=private-renewed-${f.http.calls.length}; Path=/',
          ],
        });
      };
      final source = await f.play();
      expect(
        f.calls('/acquire_dl_token').single.headers['Cookie'],
        contains('private-renewed-1'),
      );
      expect(
        f.calls('/file/download').single.headers['Cookie'],
        contains('private-renewed-2'),
      );
      expect(source.headers['Cookie'], contains('private-renewed-3'));
      expect(f.vault.credential(CloudPlatform.quark)!.updatedAt, 42);
    },
  );

  for (final variant in [
    'numeric',
    'msg_id',
    'id',
    'serialized',
    'single',
    'no-fid',
    'no-conversation',
  ]) {
    test(
      'Fast response variant $variant resolves the same selected file',
      () async {
        f.intercept = (r) {
          if (!r.uri.path.endsWith('/batch_send')) return null;
          final message = _msg();
          if (variant == 'numeric') message['store_msg_id'] = 2000000000000001;
          if (variant == 'msg_id' || variant == 'id') {
            message[variant] = message.remove('store_msg_id');
          }
          if (variant == 'serialized') {
            message['extra'] = encoded(message['extra']);
          }
          if (variant == 'no-fid') message.remove('extra');
          if (variant == 'no-conversation') message.remove('conversation_id');
          final data = variant == 'single'
              ? message
              : {
                  'send_msg_list': [message],
                };
          return _ok(variant == 'serialized' ? encoded(data) : data);
        };
        await f.play();
        expect(
          f.calls('/acquire_dl_token').single.json['msg_id'],
          '2000000000000001',
        );
        expect(
          f.calls('/acquire_dl_token').single.json['conversation_id'],
          variant == 'no-conversation' ? _pc : _conversation,
        );
      },
    );
  }

  test(
    'Message selection uses the matching fid instead of the first entry',
    () async {
      f.intercept = (r) => r.uri.path.endsWith('/batch_send')
          ? _ok({
              'send_msg_list': [_msg(id: 'foreign', fid: 'other-file'), _msg()],
            })
          : null;
      await f.play();
      expect(
        f.calls('/acquire_dl_token').single.json['msg_id'],
        '2000000000000001',
      );
    },
  );

  for (final variant in [
    'foreign',
    'ambiguous',
    'conflicting',
    'wrong-type',
    'missing-id',
  ]) {
    test('Rejects $variant fast messages before requesting a token', () async {
      f.intercept = (r) {
        if (!r.uri.path.endsWith('/batch_send')) return null;
        final message = _msg();
        if (variant == 'foreign') {
          return _ok({
            'send_msg_list': [_msg(fid: 'other-file')],
          });
        }
        if (variant == 'ambiguous') {
          return _ok({
            'send_msg_list': [_msg(fid: null), _msg(id: 'second', fid: null)],
          });
        }
        if (variant == 'conflicting') message['fid'] = 'other-file';
        if (variant == 'wrong-type') message['conversation_type'] = 1;
        if (variant == 'missing-id') message.remove('store_msg_id');
        return _ok({
          'send_msg_list': [message],
        });
      };
      await expectLater(f.play(), throwsA(isA<AppException>()));
      expect(f.calls('/acquire_dl_token'), isEmpty);
      expect(f.calls('/file/download'), isEmpty);
    });
  }

  test(
    'Token fallback reuses the message once with the extracted PC target',
    () async {
      f.intercept = (r) =>
          r.uri.path.endsWith('/acquire_dl_token') &&
              f.calls('/acquire_dl_token').length == 1
          ? _ok({'token': ''})
          : null;
      await f.play();
      expect(f.calls('/batch_send'), hasLength(1));
      expect(
        f.calls('/acquire_dl_token').map((r) => r.json['conversation_id']),
        [_conversation, _pc],
      );
      expect(
        f.calls('/acquire_dl_token').map((r) => r.json['msg_id']).toSet(),
        {'2000000000000001'},
      );
      expect(f.calls('/file/download'), hasLength(1));
    },
  );

  for (final token in [
    null,
    '',
    'null',
    123,
    <String, Object>{},
    'bad\nvalue',
  ]) {
    test(
      'Invalid token ${token.runtimeType}: ${encoded(token)} stops after bounded fallback',
      () async {
        f.intercept = (r) => r.uri.path.endsWith('/acquire_dl_token')
            ? _ok({'token': token})
            : null;
        await expectLater(f.play(), throwsA(isA<AppException>()));
        expect(f.calls('/batch_send'), hasLength(1));
        expect(f.calls('/acquire_dl_token'), hasLength(2));
        expect(f.calls('/file/download'), isEmpty);
      },
    );
  }

  test('A missing token on the PC target is not requested twice', () async {
    f.intercept = (r) {
      if (r.uri.path.endsWith('/batch_send')) {
        return _ok({
          'send_msg_list': [_msg()..remove('conversation_id')],
        });
      }
      if (r.uri.path.endsWith('/acquire_dl_token')) return _ok({});
      return null;
    };
    await expectLater(f.play(), throwsA(isA<AppException>()));
    expect(f.calls('/acquire_dl_token'), hasLength(1));
    expect(f.calls('/file/download'), isEmpty);
  });

  for (final json in [false, true]) {
    test(
      'HTTP 401 ${json ? 'JSON' : 'HTML'} requires login without another conversation or ordinary link',
      () async {
        f.intercept = (r) => r.uri.path.endsWith('/acquire_dl_token')
            ? HttpResult(
                401,
                json
                    ? encoded({'status': 401, 'code': 31001})
                    : '<html>Login required</html>',
              )
            : null;
        await expectLater(f.play(), throwsA(isA<AccountLoginRequired>()));
        expect(f.calls('/acquire_dl_token'), hasLength(1));
        expect(f.calls('/config'), hasLength(1));
        expect(f.calls('/file/download'), isEmpty);
      },
    );
  }

  for (final stage in ['/batch_send', '/acquire_dl_token', '/file/download']) {
    for (final action in ['cancel', 'switch', 'logout']) {
      test(
        '$action during $stage prevents any next request or stale source',
        () async {
          final gate = Completer<void>(), scope = RequestScope();
          f.intercept = (r) async {
            if (r.uri.path.endsWith(stage)) await gate.future;
            return null;
          };
          final pending = scope.run(() => f.play());
          final assertion = expectLater(pending, throwsA(isA<AppException>()));
          await until(() => f.calls(stage).isNotEmpty);
          final sent = f.http.calls.length;
          if (action == 'cancel') scope.cancel();
          if (action == 'switch') {
            await f.vault.putCredential(
              CloudPlatform.quark,
              Credential('replacement', {
                'primary': '__pus=replacement; __puus=replacement',
              }, updatedAt: 43),
            );
          }
          if (action == 'logout') {
            await f.vault.removeCredential(CloudPlatform.quark);
          }
          gate.complete();
          await assertion;
          expect(f.http.calls, hasLength(sent));
          expect(f.calls('/file/delete'), isEmpty);
          if (action == 'switch') {
            expect(
              f.vault.credential(CloudPlatform.quark)!.primary,
              contains('replacement'),
            );
          }
          if (action == 'logout') {
            expect(f.vault.credential(CloudPlatform.quark), isNull);
          }
        },
      );
    }
  }

  for (final variant in [
    'foreign-fid',
    'ambiguous',
    'bad-url',
    'wrong-size',
    'business-error',
  ]) {
    test(
      'Rejects $variant final source without falling back to ordinary download',
      () async {
        f.intercept = (r) {
          if (!r.uri.path.endsWith('/file/download')) return null;
          final item = {
            'fid': variant == 'foreign-fid' ? 'other-file' : _file.id,
            'size': variant == 'wrong-size' ? 1 : _file.size,
            'download_url': variant == 'bad-url'
                ? 'file:///private'
                : 'https://media.example/file',
          };
          if (variant == 'business-error') {
            return jsonResponse({
              'status': 200,
              'code': 32001,
              'message': 'private-server-token',
            });
          }
          if (variant == 'ambiguous') return _ok([item, item]);
          return _ok([item]);
        };
        await expectLater(f.play(), throwsA(isA<AppException>()));
        expect(f.calls('/file/download'), hasLength(1));
        expect(f.calls('/file/download').single.json['token'], isNotEmpty);
      },
    );
  }

  test(
    'Share playback stages cleanup before save and authorizes only the saved fid',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      f.intercept = (r) {
        if (r.uri.path.endsWith('/share/sharepage/save')) {
          expect(progress.value.last.stage, OperationStage.transfer);
          expect(progress.value.last.status, OperationStepStatus.running);
          expect(f.cleanups.pendingCount, 1);
          expect(
            asJson(f.store.data.obj('cleanups').values.single)['ready'],
            false,
          );
          expect(r.json['fid_list'], [_file.id]);
          expect(r.json['fid_token_list'], [_file.token]);
        }
        return null;
      };
      final source = await progress.run(() => f.play(_share));
      expect(progress.value.map((step) => step.stage), [
        OperationStage.createTemporary,
        OperationStage.transfer,
        OperationStage.playbackLink,
      ]);
      expect(
        progress.value.every(
          (step) => step.status == OperationStepStatus.completed,
        ),
        isTrue,
      );
      expect(
        f
            .calls('/batch_send')
            .single
            .json['conversations'][0]['file_list'][0]['fid'],
        'saved-video-1-1',
      );
      expect(f.calls('/file/download').single.json['fids'], [
        'saved-video-1-1',
      ]);
      expect(source.source!['file']['id'], _file.id);
      await f.cleanups.ready(source.cleanup);
      await f.cleanups.drain();
      expect(f.calls('/file/delete'), isEmpty);
      expect(f.cleanups.progress.value, isEmpty);
      await f.cleanups.release(source.cleanup);
      await f.cleanups.ready(source.cleanup);
      await f.cleanups.drain();
      expect(f.cleanups.progress.value.single.stage, OperationStage.cleanup);
      expect(
        f.cleanups.progress.value.single.status,
        OperationStepStatus.completed,
      );
      expect(f.calls('/file/delete').single.json['filelist'], ['temporary-1']);
      expect(f.cleanups.pendingCount, 0);
    },
  );

  for (final enabled in [false, true]) {
    test(
      'large share plays after quota rejection with download bypass=$enabled',
      () async {
        f.fileSize = 8 * 1024 * 1024 * 1024;
        f.capacityExceeded = true;
        await f.store.change(
          (draft) => draft['settings'] = const AppSettings().update({
            'quarkAuthenticatedDirectDownload': enabled,
          }).toJson(),
        );
        final settings = encoded(f.store.data['settings']);
        final source = await f.play(_share);
        expect(source.url, 'https://dl.quark.cn/share-original');
        expect(source.expectedSize, f.fileSize);
        expect(source.guestDownload, isFalse);
        expect(source.cleanup, isNull);
        expect(source.headers['Cookie'], contains('__pus=private-account'));
        expect(f.calls('/batch_send'), isEmpty);
        final direct = f.calls('/file/download').single;
        expect(direct.json['fids'], [_file.id]);
        expect(direct.json['pwd_id'], 'fixture');
        expect(direct.json['fids_token'], [_file.token]);
        expect(f.calls('/file/delete').single.json['filelist'], [
          'temporary-1',
        ]);
        await f.cleanups.drain();
        expect(f.cleanups.pendingCount, 0);
        expect(encoded(f.store.data['settings']), settings);
      },
    );
  }

  test(
    'large share playback survives enable then disable in the same app and session',
    () async {
      f.fileSize = 8 * 1024 * 1024 * 1024;
      f.capacityExceeded = true;
      for (final enabled in [false, true, false]) {
        await f.store.change(
          (draft) => draft['settings'] = AppSettings.fromJson(
            draft.obj('settings'),
          ).update({'quarkAuthenticatedDirectDownload': enabled}).toJson(),
        );
        final source = await f.play(_share);
        expect(source.url, 'https://dl.quark.cn/share-original');
        expect(source.cleanup, isNull);
        expect(source.source!['file']['id'], _file.id);
        await f.cleanups.drain();
      }
      expect(f.calls('/file/download'), hasLength(3));
      expect(f.calls('/batch_send'), isEmpty);
      expect(f.cleanups.pendingCount, 0);
      expect(
        AppSettings.fromJson(
          f.store.data.obj('settings'),
        ).quarkAuthenticatedDirectDownload,
        isFalse,
      );
    },
  );

  test(
    'quota playback cannot repeatedly transfer when direct access is denied',
    () async {
      f.capacityExceeded = true;
      f.directAvailable = false;
      await expectLater(
        f.play(_share),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('免转存播放但未成功'),
          ),
        ),
      );
      expect(f.calls('/share/sharepage/save'), hasLength(1));
      expect(f.calls('/file/download'), hasLength(1));
      expect(f.calls('/batch_send'), isEmpty);
      await f.cleanups.drain();
      expect(f.cleanups.pendingCount, 0);
    },
  );

  test(
    'ordinary transfer rejection does not try account direct playback',
    () async {
      f.intercept = (r) => r.uri.path.endsWith('/share/sharepage/save')
          ? jsonResponse({
              'status': 403,
              'code': 41017,
              'message': '分享已失效',
            }, 403)
          : null;
      await expectLater(f.play(_share), throwsA(isA<AppException>()));
      expect(f.calls('/file/download'), isEmpty);
      expect(f.calls('/batch_send'), isEmpty);
    },
  );

  for (final action in ['cancel', 'switch']) {
    test(
      '$action during quota direct playback cannot accept a stale source',
      () async {
        f.capacityExceeded = true;
        final gate = Completer<void>();
        final scope = RequestScope();
        f.intercept = (r) async {
          if (r.uri.path.endsWith('/file/download')) await gate.future;
          return null;
        };
        final pending = scope.run(() => f.play(_share));
        final failure = expectLater(pending, throwsA(isA<AppException>()));
        await until(() => f.calls('/file/download').isNotEmpty);
        if (action == 'cancel') {
          scope.cancel();
        } else {
          await f.vault.putCredential(
            CloudPlatform.quark,
            Credential('replacement', {
              'primary': '__pus=replacement; __puus=replacement',
            }, updatedAt: 43),
          );
        }
        gate.complete();
        await failure;
        expect(f.http.calls.where((r) => r.uri.host == 'dl.quark.cn'), isEmpty);
        expect(f.calls('/share/sharepage/save'), hasLength(1));
        expect(f.calls('/file/download'), hasLength(1));
      },
    );
  }

  test(
    'quota playback refresh and history reopen resolve the share again without saved state',
    () async {
      f.capacityExceeded = true;
      f.fileSize = 8 * 1024 * 1024 * 1024;
      final directory = Directory.systemTemp.createTempSync(
        'asterlink-quota-playback-',
      );
      final services = AppServices(
        controlEnabled: false,
        store: f.store,
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(directory),
        http: f.http,
        platformFeatures: false,
      );
      FakePlaybackBackend backend(PlaybackEntry entry, bool hardware) =>
          FakePlaybackBackend(entry.id, [])..hardwareAcceleration = hardware;
      final player = cloudPlayback(services, _share, f.selectedFile, [
        f.selectedFile,
      ], backendFactory: backend);
      addTearDown(() async {
        await player.close();
        await services.close();
        directory.deleteSync(recursive: true);
      });
      await player.start();
      expect(player.error, isEmpty);
      await player.seek(const Duration(seconds: 120));
      await services.updateSettings({'quarkAuthenticatedDirectDownload': true});
      await player.load(
        0,
        refreshSource: true,
        startPosition: const Duration(seconds: 120),
      );
      expect(player.error, isEmpty);
      await player.close();
      final record = PlaybackStore(f.store).recent.single;
      await services.updateSettings({
        'quarkAuthenticatedDirectDownload': false,
      });
      final restored = await restoreRecentPlayback(
        services,
        record,
        backendFactory: backend,
      );
      addTearDown(restored.close);
      await restored.start();
      expect(restored.error, isEmpty);
      expect(f.calls('/file/download'), hasLength(3));
      expect(
        f.calls('/file/download').every((r) => r.json.containsKey('pwd_id')),
        isTrue,
      );
      expect(f.calls('/batch_send'), isEmpty);
      await restored.close();
      expect(services.cleanups.pendingCount, 0);
      final history = encoded(f.store.data['playbackHistory']);
      expect(history, isNot(contains('share-original')));
      expect(history, isNot(contains('private-old-cookie')));
    },
  );

  for (final enabled in [false, true]) {
    test(
      'normal share retains fast playback when download bypass=$enabled',
      () async {
        await f.store.change(
          (draft) => draft['settings'] = const AppSettings().update({
            'quarkAuthenticatedDirectDownload': enabled,
          }).toJson(),
        );
        final source = await f.play(_share);
        expect(source.cleanup, isNotNull);
        expect(f.calls('/batch_send'), hasLength(1));
        expect(f.calls('/file/download').single.json['token'], isNotEmpty);
        expect(
          f.calls('/file/download').single.json.containsKey('pwd_id'),
          isFalse,
        );
      },
    );
  }

  test(
    'An ambiguous share transfer never authorizes an arbitrary saved file',
    () async {
      f.intercept = (r) => r.uri.path.endsWith('/task')
          ? _ok({
              'status': 2,
              'save_as': {
                'save_as_top_fids': ['saved-one', 'saved-two'],
              },
            })
          : null;
      await expectLater(f.play(_share), throwsA(isA<AppException>()));
      expect(f.calls('/batch_send'), isEmpty);
      expect(f.calls('/file/download'), isEmpty);
      await f.cleanups.drain();
      expect(f.cleanups.pendingCount, 0);
      for (final request in f.calls('/file/delete')) {
        expect(request.json['filelist'], ['temporary-1']);
      }
    },
  );

  for (final cancelled in [false, true]) {
    test(
      'Share ${cancelled ? 'cancel' : 'failure'} leaves only its temporary directory eligible for cleanup',
      () async {
        final scope = RequestScope();
        f.intercept = (r) {
          if (r.uri.path.endsWith('/acquire_dl_token')) {
            if (cancelled) scope.cancel();
            return _ok({});
          }
          return null;
        };
        await expectLater(
          scope.run(() => f.play(_share)),
          throwsA(isA<AppException>()),
        );
        expect(f.cleanups.pendingCount, 1);
        expect(
          asJson(f.store.data.obj('cleanups').values.single)['ready'],
          true,
        );
        await f.cleanups.drain();
        expect(f.cleanups.pendingCount, 0);
        for (final request in f.calls('/file/delete')) {
          expect(request.json['filelist'], ['temporary-1']);
        }
        expect(f.calls('/file/download'), isEmpty);
      },
    );
  }

  test('Quark and UC original downloads keep their request bodies', () async {
    // UC verifies the original file with a one-byte CDN probe.
    f.intercept = (r) => r.uri.host == 'media.example'
        ? HttpResult(206, 'x', {
            'content-range': ['bytes 0-0/${_file.size}'],
            'content-length': ['1'],
            'content-type': ['video/mp4'],
          })
        : null;
    await f.repository.prepare(_personal, _file);
    await f.repository.prepare(
      const BrowseSession(
        platform: CloudPlatform.uc,
        mode: BrowseMode.personal,
        title: '',
        rootId: '0',
      ),
      _file,
    );
    expect(f.calls('/batch_send'), isEmpty);
    expect(f.calls('/acquire_dl_token'), isEmpty);
    expect(f.calls('/file/download').map((r) => r.json), [
      {
        'fids': [_file.id],
      },
      {
        'fids': [_file.id],
      },
    ]);
  });

  for (final mode in BrowseMode.values) {
    test(
      '${mode.name} playback, refresh, history reopen and episode switching share the real fast provider',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'asterlink-fast-playback-',
        );
        final services = AppServices(
          controlEnabled: false,
          store: f.store,
          dataDirectory: directory,
          cacheDirectory: Directory('${directory.path}/cache'),
          transport: FakeNative(),
          files: FakeFiles(directory),
          http: f.http,
          platformFeatures: false,
        );
        final backends = <FakePlaybackBackend>[];
        FakePlaybackBackend backend(PlaybackEntry entry, bool hardware) {
          final value = FakePlaybackBackend(entry.id, [])
            ..hardwareAcceleration = hardware;
          backends.add(value);
          return value;
        }

        final session = mode == BrowseMode.share ? _share : _personal;
        final player = cloudPlayback(services, session, _file, [
          _file,
          _second,
        ], backendFactory: backend);
        addTearDown(() async {
          await player.close();
          await services.close();
          directory.deleteSync(recursive: true);
        });
        await player.start();
        expect(player.error, isEmpty);
        expect(f.calls('/batch_send'), hasLength(1));
        await player.seek(const Duration(seconds: 92));
        expect(f.calls('/batch_send'), hasLength(1));
        await player.load(
          0,
          refreshSource: true,
          startPosition: const Duration(seconds: 92),
        );
        expect(player.error, isEmpty);
        expect(f.calls('/batch_send'), hasLength(2));
        await player.close();
        final record = PlaybackStore(f.store).recent.single;
        final history = encoded(f.store.data['playbackHistory']);
        for (final secret in [
          'private-dl-token',
          'private-url',
          'private-old-cookie',
          'saved-video',
          'private-share-token',
        ]) {
          expect(history, isNot(contains(secret)));
        }
        final recent = await restoreRecentPlayback(
          services,
          record,
          backendFactory: backend,
        );
        addTearDown(recent.close);
        await recent.start();
        expect(recent.error, isEmpty);
        expect(f.calls('/batch_send'), hasLength(3));
        expect(backends.last.openedStart, const Duration(seconds: 92));
        await recent.next();
        expect(recent.error, isEmpty);
        expect(recent.current.id, _second.id);
        expect(f.calls('/batch_send'), hasLength(4));
        expect(
          f.calls('/file/download').every((r) => r.json['token'] != null),
          isTrue,
        );
        expect(
          backends.every((b) => b.connections == 128 && b.segmentSizeMiB == 4),
          isTrue,
        );
        await recent.close();
        expect(services.cleanups.pendingCount, 0);
      },
    );
  }

  test(
    'Stage diagnostics identify token failure and never expose protocol secrets',
    () async {
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = null;
        log.close();
      });
      f.intercept = (r) => r.uri.path.endsWith('/acquire_dl_token')
          ? jsonResponse({
              'status': 200,
              'code': 32001,
              'message': 'private-server-secret',
            })
          : null;
      await expectLater(f.play(), throwsA(isA<AppException>()));
      final failed = log
          .entries(errorsOnly: true)
          .where((e) => e.event == 'cloud.playback_source_failed')
          .toList();
      expect(failed, hasLength(2));
      for (final entry in failed) {
        final fields = asJson(entry.data['fields']);
        expect(fields['stage'], 'acquire_dl_token');
        expect(fields['route'], 'fast_transfer');
        expect(fields['responseCode'], 32001);
        expect(entry.data['stack'], isNotEmpty);
      }
      final exported = log.exportFiles().values.join();
      for (final secret in [
        'private-',
        _conversation,
        '2000000000000001',
        _file.id,
      ]) {
        expect(exported, isNot(contains(secret)));
      }
    },
  );
}
