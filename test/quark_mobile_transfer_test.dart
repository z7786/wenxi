import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/quark_mobile_transfer.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/redaction.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/quark_share_transfer.dart';
import 'package:asterlink/platform/quark_transfer_device.dart';
import 'support.dart';

// Synthetic account from the independently verified Python signer.
const _kps =
    'AASVvziY9xCitAbP9nqPFJEUGWMrUves7gInDbUtknHZ1+gXpTTh/OOcDdoVjpCVQrdHXX0SJCM25vH4QVXOXQHnManr8A76OxZcB/2QLeS8sw==';
const _sign =
    'AARwEmAbwX0WYsknSRlTCN95urjPBKlZRXpuJYTLyjgatCE/DGfzujZoKKod1rKPX+c=';
const _stamp = 1792589322133;
const _file = CloudFile(
  id: 'selected',
  name: 'fixture.txt',
  size: 4,
  parentId: '0',
  token: 'web-file-token',
);
final _link = ParsedLink(
  source: 'https://pan.quark.cn/s/fixture',
  url: 'https://pan.quark.cn/s/fixture',
  kind: LinkKind.cloudShare,
  platform: CloudPlatform.quark,
  shareId: 'fixture',
  passcode: 'aB12',
);
final _share = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.share,
  title: 'fixture',
  rootId: '0',
  sourceLink: _link,
  metadata: {
    'shareId': 'fixture',
    'stoken': 'web-stoken',
    'passcode': 'aB12',
    QuarkShareTransfer.preferenceKey: 'true',
  },
);
HttpResult _ok(Object data) =>
    jsonResponse({'status': 200, 'code': 0, 'data': data});

class _Fixture {
  _Fixture({QuarkTransferDevice? transferDevice}) {
    account = Credential('fixture', {
      'primary': '__pus=account; __puus=session',
      'quarkSessionRefreshedAt': '$_stamp',
    }, updatedAt: 42);
    vault = Vault(StateStore.memory());
    http = FakeHttp(reply);
    connector = QuarkConnector(
      http,
      store: vault,
      now: () => _stamp,
      taskDelay: Duration.zero,
      transferDevice:
          transferDevice ??
          QuarkTransferDevice(
            platform: 'android',
            readEnvironment: () async => {
              'deviceType': 'phone',
              'model': 'fixture-phone',
              'osVersion': '15',
              'screenWidth': 393,
              'screenHeight': 852,
              'locale': 'zh-CN',
              'networkTransport': 'wifi',
              'cellularSubtype': 0,
            },
          ),
    );
  }
  late Credential account;
  late Vault vault;
  late FakeHttp http;
  late QuarkConnector connector;
  String? failStage;
  bool pendingSave = false,
      pendingTask = false,
      badIds = false,
      missingKps = false;
  bool mismatch = false, transientTask = false;
  FutureOr<HttpResult> Function(RecordedRequest)? intercept;
  int mobileTaskReads = 0;
  List<RecordedRequest> calls(String host, String suffix) => http.calls
      .where((r) => r.uri.host == host && r.uri.path.endsWith(suffix))
      .toList();
  Future<void> init() => vault.putCredential(CloudPlatform.quark, account);
  FutureOr<HttpResult> reply(RecordedRequest r) {
    if (intercept != null) return intercept!(r);
    return normal(r);
  }

  HttpResult normal(RecordedRequest r) {
    final mobile = r.uri.host == 'drive-m.quark.cn';
    if (mobile) {
      expect(
        r.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(r.headers['User-Agent'], contains('Android 15; fixture-phone'));
      expect(r.uri.queryParameters['device_model'], 'fixture-phone');
      expect(r.uri.queryParameters['mi'], 'fixture-phone');
      expect(r.uri.queryParameters['ss'], '393x852');
      expect(r.uri.queryParameters['la'], 'zh');
      expect(r.uri.queryParameters['nt'], '5');
      expect(r.uri.queryParameters['nw'], '0');
      expect(
        r.uri.queryParameters['ve'],
        QuarkTransferDeviceInfo.clientVersion,
      );
      expect(r.uri.queryParameters['pr'], QuarkTransferDeviceInfo.product);
      for (final key in [
        'ut',
        'ds',
        'ni',
        'dn',
        'imei',
        'imsi',
        'sn',
        'mac',
        'dmn',
        'client_id',
        'client_info',
        'local_ip',
      ]) {
        expect(r.uri.queryParameters, isNot(contains(key)));
      }
      expect(r.uri.queryParameters['kps'], _kps);
      expect(r.uri.queryParameters['sign'], _sign);
      expect(r.uri.queryParameters['vcode'], '$_stamp');
      expect(r.uri.queryParameters['fr'], 'android');
      expect(r.uri.queryParametersAll['fr'], hasLength(1));
      if (r.uri.path.endsWith('/task')) {
        mobileTaskReads++;
        if (transientTask && mobileTaskReads == 1) {
          throw const HttpRequestFailure('timeout', kind: 'receiveTimeout');
        }
      }
      final stage = r.uri.path.split('/').last;
      if (failStage == stage) {
        return jsonResponse({
          'status': 400,
          'code': stage == 'task' ? 32003 : 14007,
        }, 400);
      }
    }
    switch (r.uri.path) {
      case '/account/info':
        if (failStage == 'account') {
          throw const HttpRequestFailure('timeout', kind: 'receiveTimeout');
        }
        return jsonResponse({
          'success': true,
          'data': {if (!missingKps) 'mobilekps': _kps},
        });
      case '/1/clouddrive/config':
        return _ok({});
      case '/1/clouddrive/share/sharepage/token':
        return _ok({
          'stoken': mobile ? 'mobile-stoken' : 'web-stoken',
          'first_fid': '0',
        });
      case '/1/clouddrive/share/sharepage/detail':
        return _ok({
          'list': [
            {
              'fid': 'selected',
              'file_name': 'fixture.txt',
              'dir': false,
              'size': mismatch ? 99 : 4,
              'share_fid_token': mobile
                  ? 'fresh-mobile-token'
                  : 'web-file-token',
            },
          ],
        });
      case '/1/clouddrive/share/sharepage/save':
        if (mobile && pendingSave) {
          throw const HttpRequestFailure('timeout', kind: 'receiveTimeout');
        }
        return _ok({'task_id': mobile ? 'mobile-task' : 'web-task'});
      case '/1/clouddrive/task':
        return _ok({
          'status': mobile && pendingTask ? 1 : 2,
          'save_as': {
            if (!badIds)
              (mobile ? 'save_as_select_top_fids' : 'save_as_top_fids'): [
                mobile ? 'mobile-saved' : 'web-saved',
              ],
          },
        });
      case '/1/clouddrive/file/sort':
        return _ok({
          'list': [
            {'fid': 'temp-base', 'file_name': '文析助手临时转存', 'dir': true},
          ],
        });
      case '/1/clouddrive/file':
        return _ok({'fid': 'temp-operation'});
      case '/1/clouddrive/file/delete':
        return _ok({});
      case '/1/clouddrive/file/download':
        return _ok([
          {
            'fid': 'mobile-saved',
            'size': 4,
            'file_name': 'fixture.txt',
            'download_url': 'https://cdn.quark.cn/file',
          },
        ]);
    }
    throw StateError('Unexpected fixture request ${r.uri.path}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'key4 account signing matches independent Python vector and URL roundtrip',
    () {
      final auth = QuarkMobileAuth.fromKps(Uri.encodeComponent(_kps));
      final signed = auth.sign(_stamp);
      expect(signed, {'kps': _kps, 'sign': _sign, 'vcode': '$_stamp'});
      final uri = Uri.https('drive-m.quark.cn', '/1/clouddrive/task', signed);
      expect(uri.queryParameters, signed);
      expect(auth.sign(_stamp + 1)['sign'], isNot(_sign));
      expect(
        () => QuarkMobileAuth.fromKps('AAQ='),
        throwsA(isA<QuarkMobileUnavailable>()),
      );
    },
  );

  test(
    'searched share refreshes mobile tokens and saves/polls without PC cookie',
    () async {
      final f = _Fixture();
      await f.init();
      await f.connector.saveShare(_share, [_file], 'target', f.account);
      final save = f.calls('drive-m.quark.cn', '/save').single;
      expect(save.json, containsPair('fid_token_list', ['fresh-mobile-token']));
      expect(save.json, containsPair('stoken', 'mobile-stoken'));
      expect(save.json, containsPair('pdir_fid', ''));
      expect(save.json, containsPair('to_pdir_fid', 'target'));
      expect(save.json, containsPair('save_all', false));
      expect(f.calls('drive-pc.quark.cn', '/save'), isEmpty);
    },
  );

  for (final stage in ['account', 'token', 'detail', 'save', 'task']) {
    test(
      'confirmed mobile $stage failure falls back to original web save',
      () async {
        final f = _Fixture()..failStage = stage;
        await f.init();
        await f.connector.saveShare(_share, [_file], 'target', f.account);
        final save = f.calls('drive-pc.quark.cn', '/save').single;
        expect(save.json['stoken'], 'web-stoken');
        expect(save.json['fid_token_list'], ['web-file-token']);
        expect(save.headers['Cookie'], contains('__pus=account'));
        expect(f.calls('drive-pc.quark.cn', '/task'), hasLength(1));
      },
    );
  }

  test(
    'old Cookie backups missing mobilekps continue through web save',
    () async {
      final f = _Fixture()..missingKps = true;
      await f.init();
      await f.connector.saveShare(_share, [_file], 'target', f.account);
      expect(f.calls('drive-m.quark.cn', '/save'), isEmpty);
      expect(f.calls('drive-pc.quark.cn', '/save'), hasLength(1));
    },
  );
  test(
    'changed mobile file is never saved with old selection tokens',
    () async {
      final f = _Fixture()..mismatch = true;
      await f.init();
      await f.connector.saveShare(_share, [_file], 'target', f.account);
      expect(f.calls('drive-m.quark.cn', '/save'), isEmpty);
      expect(f.calls('drive-pc.quark.cn', '/save'), hasLength(1));
    },
  );
  for (final kind in [
    'save_timeout',
    'task_pending',
    'completed_missing_ids',
  ]) {
    test(
      '$kind never repeats an uncertain/already completed save through web',
      () async {
        final f = _Fixture()
          ..pendingSave = kind == 'save_timeout'
          ..pendingTask = kind == 'task_pending'
          ..badIds = kind == 'completed_missing_ids';
        await f.init();
        await expectLater(
          f.connector.saveShare(_share, [_file], 'target', f.account),
          throwsA(isA<QuarkMobilePending>()),
        );
        expect(f.calls('drive-m.quark.cn', '/save'), hasLength(1));
        expect(f.calls('drive-pc.quark.cn', '/save'), isEmpty);
      },
    );
  }
  test(
    'a task read timeout resumes the same ID without submitting another save',
    () async {
      final f = _Fixture()..transientTask = true;
      await f.init();
      await f.connector.saveShare(_share, [_file], 'target', f.account);
      expect(f.mobileTaskReads, 2);
      expect(f.calls('drive-m.quark.cn', '/save'), hasLength(1));
      expect(f.calls('drive-pc.quark.cn', '/save'), isEmpty);
    },
  );
  test(
    'malformed completed file IDs cannot cause download or web resave',
    () async {
      for (final ids in <List<Object?>>[
        [null],
        ['null'],
        ['0'],
        [' '],
        [{}],
        ['saved', 'saved'],
      ]) {
        final f = _Fixture();
        await f.init();
        f.intercept = (r) =>
            r.uri.host == 'drive-m.quark.cn' && r.uri.path.endsWith('/task')
            ? _ok({
                'status': 2,
                'save_as': {'save_as_top_fids': ids},
              })
            : f.normal(r);
        await expectLater(
          f.connector.downloadFallback(_share, _file, f.account),
          throwsA(isA<QuarkMobilePending>()),
        );
        expect(f.calls('drive-m.quark.cn', '/save'), hasLength(1));
        expect(f.calls('drive-pc.quark.cn', '/save'), isEmpty);
        expect(f.calls('drive-pc.quark.cn', '/download'), isEmpty);
      }
    },
  );

  test(
    'task authentication loss cannot trigger a duplicate web save',
    () async {
      final f = _Fixture();
      await f.init();
      f.intercept = (r) =>
          r.uri.host == 'drive-m.quark.cn' && r.uri.path.endsWith('/task')
          ? jsonResponse({'status': 400, 'code': 31001}, 400)
          : f.normal(r);
      await expectLater(
        f.connector.saveShare(_share, [_file], 'target', f.account),
        throwsA(isA<QuarkMobilePending>()),
      );
      expect(f.calls('drive-m.quark.cn', '/save'), hasLength(1));
      expect(f.calls('drive-pc.quark.cn', '/save'), isEmpty);
    },
  );

  test(
    'a connection failure before sending mobile save permits web fallback',
    () async {
      final f = _Fixture();
      await f.init();
      f.intercept = (r) {
        if (r.uri.host == 'drive-m.quark.cn' && r.uri.path.endsWith('/save')) {
          throw const HttpRequestFailure(
            'timeout',
            kind: 'connectionTimeout',
            requestNotSent: true,
          );
        }
        return f.normal(r);
      };
      await f.connector.saveShare(_share, [_file], 'target', f.account);
      expect(f.calls('drive-m.quark.cn', '/save'), hasLength(1));
      expect(f.calls('drive-pc.quark.cn', '/save'), hasLength(1));
    },
  );
  test('manual non-search shares retain the original web route', () async {
    final f = _Fixture();
    await f.init();
    final manual = BrowseSession(
      platform: _share.platform,
      mode: _share.mode,
      title: _share.title,
      rootId: _share.rootId,
      sourceLink: _link,
      metadata: {..._share.metadata}..remove(QuarkShareTransfer.preferenceKey),
    );
    await f.connector.saveShare(manual, [_file], 'target', f.account);
    expect(f.calls('pan.quark.cn', '/account/info'), isEmpty);
    expect(f.calls('drive-m.quark.cn', '/save'), isEmpty);
    expect(f.calls('drive-pc.quark.cn', '/save'), hasLength(1));
  });
  for (final platform in ['windows', 'macos', 'linux', 'ios']) {
    test(
      '$platform uses web transfer even with a restored mobile preference',
      () async {
        final f = _Fixture(
          transferDevice: QuarkTransferDevice(
            platform: platform,
            readEnvironment: () async =>
                throw StateError('must not read device'),
          ),
        );
        await f.init();
        await f.connector.saveShare(_share, [_file], 'target', f.account);
        expect(f.calls('pan.quark.cn', '/account/info'), isEmpty);
        expect(f.calls('drive-m.quark.cn', '/save'), isEmpty);
        expect(f.calls('drive-pc.quark.cn', '/save'), hasLength(1));
      },
    );
  }
  test(
    'unavailable phone information falls back before reading mobile credentials',
    () async {
      final f = _Fixture(
        transferDevice: QuarkTransferDevice(
          platform: 'android',
          readEnvironment: () async => {},
        ),
      );
      await f.init();
      await f.connector.saveShare(_share, [_file], 'target', f.account);
      expect(f.calls('pan.quark.cn', '/account/info'), isEmpty);
      expect(f.calls('drive-m.quark.cn', '/save'), isEmpty);
      expect(f.calls('drive-pc.quark.cn', '/save'), hasLength(1));
    },
  );
  test(
    'temporary download transfers use the same mobile route and web cleanup',
    () async {
      final f = _Fixture();
      await f.init();
      final spec = await f.connector.downloadFallback(_share, _file, f.account);
      expect(spec.url, 'https://cdn.quark.cn/file');
      expect(spec.cleanup?.url, contains('drive-pc.quark.cn'));
      expect(
        f.calls('drive-m.quark.cn', '/save').single.json['to_pdir_fid'],
        'temp-operation',
      );
      expect(f.calls('drive-pc.quark.cn', '/save'), isEmpty);
    },
  );
  test(
    'playback authorizes the mobile-saved ID and retains web cleanup',
    () async {
      final f = _Fixture();
      await f.init();
      f.intercept = (r) {
        if (r.uri.path.endsWith('/batch_send')) {
          expect(
            r.json['conversations'][0]['file_list'][0]['fid'],
            'mobile-saved',
          );
          return _ok({
            'send_msg_list': [
              {
                'store_msg_id': 'fixture-message',
                'conversation_id': '3000008641494773',
                'conversation_type': 3,
                'fid': 'mobile-saved',
              },
            ],
          });
        }
        if (r.uri.path.endsWith('/acquire_dl_token')) {
          return _ok({'token': 'fixture-playback-token'});
        }
        return f.normal(r);
      };
      final source = await f.connector.playback(_share, _file, f.account);
      expect(source.url, 'https://cdn.quark.cn/file');
      expect(source.cleanup?.url, contains('drive-pc.quark.cn'));
      expect(f.calls('drive-m.quark.cn', '/save'), hasLength(1));
      expect(f.calls('drive-pc.quark.cn', '/save'), isEmpty);
      expect(f.calls('drive-pc.quark.cn', '/download').single.json['fids'], [
        'mobile-saved',
      ]);
    },
  );
  test(
    'nested selections use the current share parent with freshly fetched token',
    () async {
      final f = _Fixture();
      await f.init();
      final nested = CloudFile(
        id: _file.id,
        name: _file.name,
        size: 4,
        parentId: 'shared-folder',
        token: _file.token,
      );
      await f.connector.saveShare(_share, [nested], 'target', f.account);
      expect(
        f
            .calls('drive-m.quark.cn', '/detail')
            .single
            .uri
            .queryParameters['pdir_fid'],
        'shared-folder',
      );
      expect(
        f.calls('drive-m.quark.cn', '/save').single.json['pdir_fid'],
        'shared-folder',
      );
    },
  );
  for (final changed in [false, true]) {
    test(
      '${changed ? 'account replacement' : 'cancellation'} stops before fallback or save',
      () async {
        final f = _Fixture();
        await f.init();
        final scope = RequestScope();
        f.intercept = (r) async {
          if (r.uri.path == '/account/info') {
            if (changed) {
              await f.vault.putCredential(
                CloudPlatform.quark,
                Credential('replacement', {
                  'primary': '__pus=new; __puus=new',
                }, updatedAt: 99),
              );
            } else {
              scope.cancel();
            }
          }
          return f.normal(r);
        };
        await expectLater(
          scope.run(
            () => f.connector.saveShare(_share, [_file], 'target', f.account),
          ),
          throwsA(isA<AppException>()),
        );
        expect(f.calls('drive-m.quark.cn', '/save'), isEmpty);
        expect(f.calls('drive-pc.quark.cn', '/save'), isEmpty);
      },
    );
  }
  test(
    'search preference survives reopening and origin serialization',
    () async {
      final f = _Fixture();
      await f.init();
      final store = StateStore.memory();
      final repo = CloudRepository(
        f.http,
        f.vault,
        CleanupOutbox(store, f.http),
      );
      final session = await repo.share(_link, preferQuarkMobileTransfer: true);
      expect(QuarkShareTransfer.prefersMobile(session), isTrue);
      final restored = BrowseSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())),
      );
      expect(QuarkShareTransfer.prefersMobile(restored), isTrue);
      expect(
        QuarkShareTransfer.prefersMobile(
          await repo.reopenTransferSource(restored),
        ),
        isTrue,
      );
      expect(
        QuarkShareTransfer.prefersMobile(await repo.share(_link)),
        isFalse,
      );
    },
  );
  test('mobile auth is hidden from structured and text diagnostics', () {
    final fields = {
      'kps': 'private-kps',
      'mobilekps': 'private-mobilekps',
      'sign': 'private-sign',
      'vcode': 'private-time',
      'service_ticket': 'private-ticket',
    };
    expect(LogRedactor.json(fields), isNot(contains('private-')));
    expect(
      LogRedactor.text(
        fields.entries.map((e) => '${e.key}=${e.value}').join('; '),
      ),
      isNot(contains('private-')),
    );
  });
}
