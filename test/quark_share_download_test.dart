import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/download/download_request.dart';
import 'support.dart';

HttpResult _ok(Object data) =>
    jsonResponse({'status': 200, 'code': 0, 'data': data});

HttpResult _notShared() => jsonResponse({
  'status': 400,
  'code': 41017,
  'message': '文件没有被分享:[{0}]',
}, 400);

class _Fixture {
  _Fixture({
    this.platform = CloudPlatform.quark,
    this.root = '0',
    bool signedIn = true,
    bool Function(CloudPlatform, bool)? directPolicy,
  }) {
    final stamp = '${DateTime.now().millisecondsSinceEpoch}';
    account = Credential('fixture', {
      'primary': '__pus=fixture-account; __puus=fixture-session',
      'quarkSessionRefreshedAt': stamp,
      'ucSessionRefreshedAt': stamp,
    }, updatedAt: 42);
    store = StateStore.memory({
      'credentials': {if (signedIn) platform.key: account.toJson()},
      'settings': const AppSettings().toJson(),
    });
    vault = Vault(store);
    http = FakeHttp(reply);
    repository = CloudRepository(
      http,
      vault,
      CleanupOutbox(store, http),
      directShareDownloadEnabled: directPolicy,
    );
  }

  final CloudPlatform platform;
  final String root;
  late final Credential account;
  late final StateStore store;
  late final Vault vault;
  late final FakeHttp http;
  late final CloudRepository repository;
  int generation = 0, directories = 0;
  String rootFileId = 'shared-file';
  int rootFileSize = 4;
  bool rootUnavailable = false;
  String? capacityFailure;
  AppException? outsideError;
  AppException? saveError, directError;
  bool authenticatedDirectAvailable = false, failCleanup = false;
  String? transferCookie;
  bool guestRefreshNeedsLogin = false;
  String? directFileId;
  int? probeSize;
  int directExpirations = 0;
  final tasks = <String, String>{};
  final savedSizes = <String, int>{};

  ParsedLink get link => ParsedLink(
    source:
        'https://${platform == CloudPlatform.quark ? 'pan.quark.cn' : 'drive.uc.cn'}/s/fixture',
    url:
        'https://${platform == CloudPlatform.quark ? 'pan.quark.cn' : 'drive.uc.cn'}/s/fixture',
    kind: LinkKind.cloudShare,
    platform: platform,
    shareId: 'fixture',
  );

  List<RecordedRequest> calls(String suffix) =>
      http.calls.where((r) => r.uri.path.endsWith(suffix)).toList();

  List<String> get shareParents => http.calls
      .where((r) => r.uri.path.endsWith('/detail'))
      .map((r) => r.uri.queryParameters['pdir_fid']!)
      .toList();

  HttpResult reply(RecordedRequest r) {
    if (r.uri.host == 'dl.quark.cn') {
      expect(r.headers['Range'], 'bytes=0-0');
      expect(r.headers['Cookie'], contains('__pus=fixture-account'));
      return HttpResult(206, 'x', {
        'content-range': ['bytes 0-0/${probeSize ?? rootFileSize}'],
        'content-length': ['1'],
      });
    }
    switch (r.uri.path) {
      case '/1/clouddrive/config':
        return _ok({});
      case '/1/clouddrive/share/sharepage/token':
        if (guestRefreshNeedsLogin && (r.headers['Cookie'] ?? '').isEmpty) {
          return jsonResponse({'status': 401, 'code': 31001}, 401);
        }
        return _ok({
          'first_fid': root,
          'stoken': 'share-token-${++generation}',
        });
      case '/1/clouddrive/share/sharepage/detail':
      case '/1/clouddrive/transfer_share/detail':
        final parent = r.uri.queryParameters['pdir_fid'];
        if (parent == 'owner-only-folder') {
          if (outsideError != null) throw outsideError!;
          return _notShared();
        }
        if (parent == '0' && rootUnavailable) return _notShared();
        if (parent != '0' && parent != 'shared-folder') {
          throw StateError('Unexpected share directory');
        }
        return _ok({
          'list': [
            {
              'fid': parent == '0' ? rootFileId : 'nested-file',
              'file_name': 'fixture.bin',
              'size': parent == '0' ? rootFileSize : 4,
              // Root entries retain their owner's unshared physical parent.
              'pdir_fid': parent == '0' ? 'owner-only-folder' : parent,
              'share_fid_token': 'file-token-$generation',
              'dir': false,
            },
            if (parent == '0')
              {
                'fid': 'shared-folder',
                'file_name': 'folder',
                'pdir_fid': 'owner-only-folder',
                'share_fid_token': 'folder-token-$generation',
                'dir': true,
              },
          ],
        });
      case '/1/clouddrive/file/sort':
        return _ok({
          'list': [
            {
              'fid': 'temporary-base',
              'file_name': '文析助手临时转存',
              'pdir_fid': 'personal-parent',
              'dir': true,
            },
          ],
        });
      case '/1/clouddrive/file':
        return _ok({'fid': 'temporary-${++directories}'});
      case '/1/clouddrive/share/sharepage/save':
        if (saveError != null) throw saveError!;
        if (capacityFailure == 'save') {
          return jsonResponse({
            'status': 400,
            'code': 32003,
            'message': 'capacity limit[{0}]',
          }, 400);
        }
        final id = 'task-${tasks.length + 1}';
        tasks[id] = 'saved-${r.json['fid_list'][0]}-$directories';
        savedSizes[tasks[id]!] = r.json['fid_list'][0] == rootFileId
            ? rootFileSize
            : 4;
        final result = _ok({'task_id': id});
        return transferCookie == null
            ? result
            : HttpResult(result.status, result.body, {
                'set-cookie': ['__puus=$transferCookie; Path=/; Secure'],
              });
      case '/1/clouddrive/task':
        if (capacityFailure == 'response' || capacityFailure == 'code') {
          return jsonResponse({
            'status': 400,
            'code': 32003,
            if (capacityFailure == 'response') 'message': 'capacity limit[{0}]',
          }, 400);
        }
        if (capacityFailure == 'task') {
          return _ok({'status': 3, 'message': 'capacity limit[{0}]'});
        }
        if (capacityFailure == 'task_code') {
          return _ok({'task_status': 4, 'code': 32003});
        }
        return _ok({
          'status': 2,
          'save_as': {
            'save_as_top_fids': [tasks[r.uri.queryParameters['task_id']]],
          },
        });
      case '/1/clouddrive/file/download':
        if (r.json.containsKey('pwd_id')) {
          if (directError != null) throw directError!;
          if (directExpirations > 0) {
            directExpirations--;
            return jsonResponse({'status': 400, 'code': 41020}, 400);
          }
          if (authenticatedDirectAvailable &&
              (r.headers['Cookie'] ?? '').contains('__pus=fixture-account')) {
            return _ok([
              {
                'fid': directFileId ?? rootFileId,
                'size': rootFileSize,
                'download_url': 'https://dl.quark.cn/original',
              },
            ]);
          }
          return jsonResponse({'status': 400, 'code': 23018}, 400);
        }
        final fid = r.json['fids'][0] as String;
        return _ok([
          {
            'fid': fid,
            'size': savedSizes[fid] ?? 4,
            'download_url': 'https://cdn.example/$fid',
          },
        ]);
      case '/1/clouddrive/file/delete':
        if (failCleanup) return const HttpResult(503, '{}');
        return _ok({});
      default:
        throw StateError('Unexpected fixture request ${r.uri.path}');
    }
  }

  Future<DownloadSpec> legacyPlan() async {
    final session = await repository.share(link);
    return repository.planDownload(
      session,
      const CloudFile(
        id: 'shared-file',
        name: 'fixture.bin',
        parentId: 'owner-only-folder',
        token: 'old-file-token',
        size: 4,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final planned in [false, true]) {
    test(
      'Quark new ${planned ? 'queued' : 'direct'} download uses login after guest browsing',
      () async {
        final f = _Fixture(signedIn: false, directPolicy: (_, _) => false)
          ..rootFileSize = 100 * 1024 * 1024;
        final session = await f.repository.share(f.link);
        final file = (await f.repository.list(session, session.rootId)).first;
        expect(session.accountId, isEmpty);
        expect(f.repository.sessionCredential(session), isNull);
        await f.vault.putCredential(CloudPlatform.quark, f.account);
        final owner = f.vault.activeAccountId(CloudPlatform.quark);
        final plan = f.repository.planDownload(session, file);
        final origin = DownloadOrigin.fromJson(plan.source!);
        expect(origin.session.accountId, owner);
        expect(origin.accountRevision, f.account.updatedAt);
        final spec = planned
            ? await f.repository.refresh(plan)
            : await f.repository.prepare(session, file);
        expect(spec.guestDownload, isFalse);
        expect(spec.headers['Cookie'], contains('__pus=fixture-account'));
        expect(f.calls('/share/sharepage/save'), hasLength(1));
        expect(f.calls('/file/download'), hasLength(1));
        expect(
          f.calls('/file/download').single.json.containsKey('pwd_id'),
          isFalse,
        );
        expect(DownloadOrigin.fromJson(spec.source!).session.accountId, owner);
        // Existing browsing and tasks retain their bound identities.
        expect(session.accountId, isEmpty);
      },
    );
  }

  test('Quark existing guest task stays guest after a later login', () async {
    final f = _Fixture(signedIn: false, directPolicy: (_, _) => false)
      ..rootFileSize = 100 * 1024 * 1024;
    final session = await f.repository.share(f.link);
    final file = (await f.repository.list(session, session.rootId)).first;
    final oldPlan = f.repository.planDownload(session, file);
    await f.vault.putCredential(CloudPlatform.quark, f.account);
    await expectLater(
      f.repository.refresh(oldPlan),
      throwsA(
        isA<AccountLoginRequired>().having(
          (error) => error.message,
          'message',
          contains('游客不支持超过50MB'),
        ),
      ),
    );
    expect(f.calls('/share/sharepage/save'), isEmpty);
    expect(f.calls('/file/download').single.headers['Cookie'], isEmpty);
    expect(DownloadOrigin.fromJson(oldPlan.source!).session.accountId, isEmpty);
  });

  test(
    'Quark signed-in guest rejection does not notify on account success',
    () async {
      final f = _Fixture(directPolicy: (_, _) => true)
        ..authenticatedDirectAvailable = true;
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      var notices = 0;
      final spec = await DownloadRequestContext(
        id: 'fixture',
        retries: 0,
        onGuestDownload: () => notices++,
      ).run(() => f.repository.prepare(session, file));
      expect(spec.guestDownload, isFalse);
      expect(spec.headers['Cookie'], contains('__pus=fixture-account'));
      expect(f.calls('/file/download'), hasLength(2));
      expect(f.calls('/file/download').first.headers['Cookie'], isEmpty);
      expect(notices, 0);
    },
  );

  test(
    'Quark guest rejection followed by transfer does not show a guest notice',
    () async {
      final f = _Fixture(directPolicy: (_, authenticated) => !authenticated);
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      var notices = 0;
      final spec = await DownloadRequestContext(
        id: 'fixture-transfer',
        retries: 0,
        onGuestDownload: () => notices++,
      ).run(() => f.repository.prepare(session, file));
      expect(spec.guestDownload, isFalse);
      expect(spec.cleanup, isNotNull);
      expect(spec.headers['Cookie'], contains('__pus=fixture-account'));
      expect(f.calls('/share/sharepage/save'), hasLength(1));
      expect(notices, 0);
    },
  );

  for (final direct in [false, true]) {
    test(
      'Quark guest renewal requiring login allows signed-in ${direct ? 'direct' : 'transfer'} download',
      () async {
        final f =
            _Fixture(
                directPolicy: (_, authenticated) => !authenticated || direct,
              )
              ..directExpirations = 1
              ..authenticatedDirectAvailable = direct;
        final session = await f.repository.share(f.link);
        final file = (await f.repository.list(session, session.rootId)).first;
        f.guestRefreshNeedsLogin = true;
        var notices = 0;
        final spec = await DownloadRequestContext(
          id: 'guest-renewal',
          retries: 0,
          onGuestDownload: () => notices++,
        ).run(() => f.repository.prepare(session, file));
        expect(spec.guestDownload, isFalse);
        expect(spec.headers['Cookie'], contains('__pus=fixture-account'));
        expect(f.calls('/share/sharepage/save'), hasLength(direct ? 0 : 1));
        expect(f.calls('/file/download'), hasLength(2));
        expect(notices, 0);
      },
    );
  }

  test(
    'Quark guest renewal still requests login when no account exists',
    () async {
      final f = _Fixture(signedIn: false)..directExpirations = 1;
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      f.guestRefreshNeedsLogin = true;
      await expectLater(
        f.repository.prepare(session, file),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(f.calls('/share/sharepage/save'), isEmpty);
      expect(f.calls('/file/download'), hasLength(1));
    },
  );

  test(
    'Quark bound account is retained when another account becomes active',
    () async {
      final f = _Fixture(directPolicy: (_, _) => false);
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      final owner = session.accountId;
      final other = await f.vault.createAccount(CloudPlatform.quark);
      await f.vault.withAccount(
        CloudPlatform.quark,
        other,
        () => f.vault.putCredential(
          CloudPlatform.quark,
          f.account.withFields({'primary': '__pus=other; __puus=other'}),
        ),
      );
      await f.vault.activate(CloudPlatform.quark, other);
      final plan = f.repository.planDownload(session, file);
      expect(DownloadOrigin.fromJson(plan.source!).session.accountId, owner);
      final spec = await f.repository.prepare(session, file);
      expect(spec.headers['Cookie'], contains('__pus=fixture-account'));
      expect(spec.headers['Cookie'], isNot(contains('__pus=other')));
      expect(spec.guestDownload, isFalse);
    },
  );

  test('Quark guest size restriction uses unsupported wording', () async {
    final f = _Fixture(signedIn: false)..rootFileSize = 100 * 1024 * 1024;
    final session = await f.repository.share(f.link);
    final file = (await f.repository.list(session, session.rootId)).first;
    await expectLater(
      f.repository.prepare(session, file),
      throwsA(
        isA<AccountLoginRequired>().having(
          (error) => error.message,
          'message',
          '夸克游客不支持超过50MB文件下载，请登录夸克网盘再试',
        ),
      ),
    );
  });

  for (final failure in ['response', 'task']) {
    test(
      'Quark $failure capacity failure explains denied automatic recovery',
      () async {
        final f = _Fixture(directPolicy: (_, _) => false)
          ..capacityFailure = failure;
        final session = await f.repository.share(f.link);
        final file = (await f.repository.list(session, session.rootId)).first;
        await expectLater(
          f.repository.refresh(f.repository.planDownload(session, file)),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              '夸克网盘空间不足，已自动尝试免转存下载但未成功，请清理网盘空间后重试',
            ),
          ),
        );
        expect(f.calls('/share/sharepage/save'), hasLength(1));
        expect(f.calls('/file/download'), hasLength(1));
        expect(
          f.calls('/file/download').where((r) => !r.json.containsKey('pwd_id')),
          isEmpty,
        );
      },
    );
  }

  for (final failure in ['save', 'response', 'task', 'code', 'task_code']) {
    test(
      'Quark $failure capacity failure temporarily uses account direct',
      () async {
        final f = _Fixture(directPolicy: (_, _) => false)
          ..capacityFailure = failure
          ..authenticatedDirectAvailable = true
          ..rootFileSize = 6 * 1024 * 1024 * 1024;
        final settings = encoded(f.store.data.obj('settings'));
        final session = await f.repository.share(f.link);
        final file = (await f.repository.list(session, session.rootId)).first;
        final spec = await f.repository.refresh(
          f.repository.planDownload(session, file),
        );
        expect(spec.url, 'https://dl.quark.cn/original');
        expect(spec.expectedSize, file.size);
        expect(spec.guestDownload, isFalse);
        expect(spec.cleanup, isNull);
        expect(spec.headers['Cookie'], contains('__pus=fixture-account'));
        final direct = f.calls('/file/download').single;
        expect(direct.json['fids'], [file.id]);
        expect(direct.json['fids_token'], ['file-token-2']);
        expect(direct.json['stoken'], 'share-token-2');
        expect(f.calls('/share/sharepage/save'), hasLength(1));
        expect(f.calls('/file/delete').single.json['filelist'], [
          'temporary-1',
        ]);
        expect(f.store.data.obj('cleanups').values, hasLength(1));
        expect(
          asJson(f.store.data.obj('cleanups').values.single).boolean('ready'),
          isTrue,
        );
        expect(encoded(f.store.data.obj('settings')), settings);
      },
    );
  }

  test('Quark normal transfer does not enable account direct', () async {
    final f = _Fixture(directPolicy: (_, _) => false)
      ..authenticatedDirectAvailable = true;
    final session = await f.repository.share(f.link);
    final file = (await f.repository.list(session, session.rootId)).first;
    final spec = await f.repository.prepare(session, file);
    expect(spec.cleanup, isNotNull);
    expect(
      f.calls('/file/download').single.json.containsKey('pwd_id'),
      isFalse,
    );
    expect(f.calls('/file/delete'), isEmpty);
    expect(
      asJson(f.store.data.obj('cleanups').values.single).boolean('ready'),
      isFalse,
    );
  });

  test('Quark automatic direct is scoped to the current download', () async {
    final f = _Fixture(directPolicy: (_, _) => false)
      ..capacityFailure = 'save'
      ..authenticatedDirectAvailable = true;
    final session = await f.repository.share(f.link);
    final file = (await f.repository.list(session, session.rootId)).first;
    final direct = await f.repository.prepare(session, file);
    expect(direct.cleanup, isNull);
    f.capacityFailure = null;
    final normal = await f.repository.refresh(direct);
    expect(normal.cleanup, isNotNull);
    expect(f.calls('/share/sharepage/save'), hasLength(2));
    expect(
      f.calls('/file/download').where((r) => r.json.containsKey('pwd_id')),
      hasLength(1),
    );
    expect(
      f.store.data.obj('settings').boolean('quarkAuthenticatedDirectDownload'),
      isFalse,
    );
  });

  for (final error in [
    const HttpRequestFailure('连接超时', kind: 'connectionTimeout'),
    const AccountLoginRequired('请重新登录'),
    const AppException('请求已取消'),
    const AppException('本地磁盘空间不足'),
    const AppException('网盘拒绝转存'),
  ]) {
    test('Quark adaptive recovery does not hide ${error.message}', () async {
      final f = _Fixture(directPolicy: (_, _) => false)
        ..saveError = error
        ..authenticatedDirectAvailable = true;
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      await expectLater(
        f.repository.prepare(session, file),
        throwsA(same(error)),
      );
      expect(f.calls('/file/download'), isEmpty);
      expect(f.calls('/share/sharepage/save'), hasLength(1));
    });
  }

  for (final error in [
    const HttpRequestFailure('免转存连接超时', kind: 'connectionTimeout'),
    const AccountLoginRequired('免转存登录已失效'),
  ]) {
    test(
      'Quark automatic direct reports ${error.message} without another transfer',
      () async {
        final f = _Fixture(directPolicy: (_, _) => false)
          ..capacityFailure = 'save'
          ..directError = error;
        final session = await f.repository.share(f.link);
        final file = (await f.repository.list(session, session.rootId)).first;
        await expectLater(
          f.repository.prepare(session, file),
          throwsA(same(error)),
        );
        expect(f.calls('/share/sharepage/save'), hasLength(1));
        expect(f.calls('/file/download'), hasLength(1));
      },
    );
  }

  test(
    'Quark automatic direct uses cookies renewed by the failed transfer',
    () async {
      final f = _Fixture(directPolicy: (_, _) => false)
        ..capacityFailure = 'task'
        ..authenticatedDirectAvailable = true
        ..transferCookie = 'renewed-session';
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      final spec = await f.repository.prepare(session, file);
      expect(
        f.calls('/file/download').single.headers['Cookie'],
        contains('__puus=renewed-session'),
      );
      expect(spec.headers['Cookie'], contains('__puus=renewed-session'));
      expect(
        f.vault.credential(CloudPlatform.quark)!.primary,
        contains('__puus=renewed-session'),
      );
      expect(
        f.vault.credential(CloudPlatform.quark)!.updatedAt,
        f.account.updatedAt,
      );
    },
  );

  test(
    'Quark successful recovery keeps failed directory cleanup retryable',
    () async {
      final f = _Fixture(directPolicy: (_, _) => false)
        ..capacityFailure = 'save'
        ..authenticatedDirectAvailable = true
        ..failCleanup = true;
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      final spec = await f.repository.prepare(session, file);
      expect(spec.cleanup, isNull);
      expect(
        asJson(f.store.data.obj('cleanups').values.single).boolean('ready'),
        isTrue,
      );
      f.failCleanup = false;
      await f.repository.cleanups.drain();
      expect(f.store.data.obj('cleanups'), isEmpty);
      expect(f.calls('/file/delete'), hasLength(2));
      expect(
        f.calls('/file/delete').map((r) => r.json['filelist']),
        everyElement(['temporary-1']),
      );
    },
  );

  test(
    'Quark automatic direct refreshes expired tokens for the same file',
    () async {
      final f = _Fixture(directPolicy: (_, _) => false)
        ..capacityFailure = 'save'
        ..authenticatedDirectAvailable = true
        ..directExpirations = 1;
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      final spec = await f.repository.prepare(session, file);
      expect(spec.expectedSize, file.size);
      expect(f.calls('/file/download'), hasLength(2));
      expect(f.calls('/file/download').last.json['fids_token'], [
        'file-token-2',
      ]);
      expect(f.calls('/share/sharepage/save'), hasLength(1));
    },
  );

  for (final wrongId in [true, false]) {
    test(
      'Quark automatic direct rejects mismatched ${wrongId ? 'file' : 'length'}',
      () async {
        final f = _Fixture(directPolicy: (_, _) => false)
          ..capacityFailure = 'task'
          ..authenticatedDirectAvailable = true
          ..directFileId = wrongId ? 'another-file' : null
          ..probeSize = wrongId ? null : 1024;
        final session = await f.repository.share(f.link);
        final file = (await f.repository.list(session, session.rootId)).first;
        await expectLater(
          f.repository.prepare(session, file),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('不一致'),
            ),
          ),
        );
        expect(f.calls('/share/sharepage/save'), hasLength(1));
      },
    );
  }

  test(
    'UC quota failure retains its existing account download policy',
    () async {
      final f =
          _Fixture(platform: CloudPlatform.uc, directPolicy: (_, _) => false)
            ..capacityFailure = 'task'
            ..authenticatedDirectAvailable = true;
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, session.rootId)).first;
      await expectLater(
        f.repository.prepare(session, file),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            '网盘空间不足，可尝试打开实用性功能的突破文件大小限制再试',
          ),
        ),
      );
      expect(f.calls('/file/download'), isEmpty);
    },
  );

  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    for (final root in ['0', '']) {
      test(
        '${platform.key} share entries retain the browsed root ($root)',
        () async {
          final f = _Fixture(platform: platform, root: root);
          final session = await f.repository.share(f.link);
          final files = await f.repository.list(session, session.rootId);
          expect(files, hasLength(2));
          expect(files.map((file) => file.parentId), everyElement('0'));
          expect(files.first.id, 'shared-file');
          expect(files.first.token, 'file-token-1');
        },
      );
    }

    test('${platform.key} personal entries retain the API parent', () async {
      final f = _Fixture(platform: platform);
      final session = await f.repository.personal(platform);
      final files = await f.repository.list(session, session.rootId);
      expect(files.single.parentId, 'personal-parent');
    });
  }

  for (final root in ['0', '']) {
    test(
      'A queued Quark root download restores the share and fresh tokens ($root)',
      () async {
        final f = _Fixture(root: root);
        final session = await f.repository.share(f.link);
        final file = (await f.repository.list(session, session.rootId)).first;
        final planned = f.repository.planDownload(session, file);
        final source = DownloadOrigin.fromJson(planned.source!);
        final restoredPlan = planned.copyWith(source: source.toJson());
        final downloaded = await f.repository.refresh(restoredPlan);
        expect(downloaded.needsPreparation, isFalse);
        expect(downloaded.expectedSize, 4);
        expect(downloaded.cleanup, isNotNull);
        expect(f.shareParents, ['0', '0']);
        final save = f.calls('/share/sharepage/save').single.json;
        expect(save['pdir_fid'], '0');
        expect(save['fid_list'], ['shared-file']);
        expect(save['fid_token_list'], ['file-token-2']);
        expect(save['stoken'], 'share-token-2');
        expect(
          f
              .calls('/file/download')
              .where((r) => !r.json.containsKey('pwd_id'))
              .single
              .json['fids'],
          ['saved-shared-file-1'],
        );
      },
    );
  }

  test(
    'A nested Quark download restores only its shared subdirectory',
    () async {
      final f = _Fixture();
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, 'shared-folder')).single;
      final source = await f.repository.refresh(
        f.repository.planDownload(session, file),
      );
      expect(source.needsPreparation, isFalse);
      expect(f.shareParents, ['shared-folder', 'shared-folder']);
      expect(
        f.calls('/share/sharepage/save').single.json['pdir_fid'],
        'shared-folder',
      );
      expect(f.calls('/share/sharepage/save').single.json['fid_list'], [
        'nested-file',
      ]);
    },
  );

  test(
    'An old failed Quark root task is repaired and persists the correct parent',
    () async {
      final f = _Fixture();
      final source = await f.repository.refresh(await f.legacyPlan());
      expect(source.needsPreparation, isFalse);
      expect(f.shareParents, ['owner-only-folder', '0']);
      final origin = DownloadOrigin.fromJson(source.source!);
      expect(origin.file.id, 'shared-file');
      expect(origin.file.parentId, '0');
      expect(origin.file.token, 'file-token-2');
      final refreshed = await f.repository.refresh(source);
      expect(f.shareParents, ['owner-only-folder', '0', '0']);
      expect(DownloadOrigin.fromJson(refreshed.source!).file.parentId, '0');
    },
  );

  test(
    'Legacy fallback requires the original file ID even when names match',
    () async {
      final f = _Fixture()..rootFileId = 'another-file';
      await expectLater(
        f.repository.refresh(await f.legacyPlan()),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('文件没有被分享'),
          ),
        ),
      );
      expect(f.shareParents, ['owner-only-folder', '0']);
      expect(f.calls('/share/sharepage/save'), isEmpty);
    },
  );

  test(
    'Legacy fallback retains source-content validation before transferring',
    () async {
      final f = _Fixture()..rootFileSize = 5;
      await expectLater(
        f.repository.refresh(await f.legacyPlan()),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('内容已变化'),
          ),
        ),
      );
      expect(f.shareParents, ['owner-only-folder', '0']);
      expect(f.calls('/share/sharepage/save'), isEmpty);
    },
  );

  for (final error in [
    const AppException('网络暂时不可用'),
    const AccountLoginRequired('请重新登录'),
    const AppException('请求已取消'),
  ]) {
    test('Legacy fallback does not hide ${error.message}', () async {
      final f = _Fixture()..outsideError = error;
      await expectLater(
        f.repository.refresh(await f.legacyPlan()),
        throwsA(same(error)),
      );
      expect(f.shareParents, ['owner-only-folder']);
      expect(f.calls('/share/sharepage/save'), isEmpty);
    });
  }

  test(
    'An unavailable share root is not repeatedly retried or transferred',
    () async {
      final f = _Fixture()..rootUnavailable = true;
      final session = await f.repository.share(f.link);
      final planned = f.repository.planDownload(
        session,
        const CloudFile(
          id: 'shared-file',
          name: 'fixture.bin',
          parentId: '0',
          size: 4,
        ),
      );
      await expectLater(
        f.repository.refresh(planned),
        throwsA(isA<AppException>()),
      );
      expect(f.shareParents, ['0']);
      expect(f.calls('/share/sharepage/save'), isEmpty);
    },
  );
}
