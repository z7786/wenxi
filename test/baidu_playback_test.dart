import 'package:asterlink/data/providers/baidu_link_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/providers/baidu_playback.dart';
import 'package:asterlink/data/providers/baidu_public_parser.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/baidu_share_route.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'player_support.dart';
import 'support.dart';

const _personal = BrowseSession(
  platform: CloudPlatform.baidu,
  mode: BrowseMode.personal,
  title: '我的百度网盘',
  rootId: '/',
);
const _file = CloudFile(
  id: '9007199254740993',
  name: '视频 + # 中文.mp4',
  token: '/视频 + # 中文.mp4',
  parentId: '/',
  size: 4096,
  hashType: 'md5',
  hashValue: '08d6c05a21512a79a1dfeb9d2a8f262f',
);
const _dispatcher =
    'https://d.pcs.baidu.com/file/video?sign=a%2Bb%2Fc&key=1&key=2';
const _cdn = 'https://appall01.baidupcs.com/file/video?ticket=fixture';

Credential _account([String name = 'alice']) => Credential('fixture', {
  // The last Cookie pair intentionally has no trailing semicolon.
  'primary': 'STOKEN=fixture-token; BDCLND=old-share; BDUSS=$name',
}, updatedAt: name == 'alice' ? 41 : 42);

BrowseSession _share({String id = '123', String owner = '456'}) =>
    BrowseSession(
      platform: CloudPlatform.baidu,
      mode: BrowseMode.share,
      title: '分享视频',
      rootId: '/',
      sourceLink: ParsedLink(
        source: 'https://pan.baidu.com/s/1fixture?pwd=abcd',
        url: 'https://pan.baidu.com/s/1fixture?pwd=abcd',
        kind: LinkKind.cloudShare,
        platform: CloudPlatform.baidu,
        shareId: 'fixture',
        passcode: 'abcd',
      ),
      metadata: {
        'shortId': 'fixture',
        'shareId': id,
        'uk': owner,
        'sekey': 'stale-share',
        'cookie': 'BDUSS=must-not-be-replayed',
      },
    );

class _Fixture {
  _Fixture() {
    http = _PlaybackHttp(
      (request) async => await intercept?.call(request) ?? reply(request),
    );
    final transport = RetryingJsonHttp(http);
    connector = BaiduConnector(
      transport,
      playbackClient: BaiduPlaybackClient(
        transport,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1793250000123),
      ),
      linkLookup:
          ({
            required cookie,
            required path,
            required fileId,
            required appId,
            required device,
          }) async {
            downloads++;
            return const BaiduResolvedLink(
              url: 'https://download.baidupcs.com/original',
              preview: false,
            );
          },
    );
  }
  late final _PlaybackHttp http;
  late final BaiduConnector connector;
  FutureOr<HttpResult?> Function(RecordedRequest)? intercept;
  int downloads = 0;
  List<RecordedRequest> calls(String path) =>
      http.calls.where((r) => r.uri.path == path).toList();
  Future<DownloadSpec> play([
    BrowseSession session = _personal,
    Credential? account,
  ]) => connector.playback(session, _file, account ?? _account());

  HttpResult reply(RecordedRequest r) {
    switch (r.uri.path) {
      case '/api/mediainfo':
        return jsonResponse({
          'errno': 133,
          'info': {'dlink': _dispatcher},
        });
      case '/share/verify':
        return jsonResponse({'errno': 0, 'randsk': 'a%2Bb%2Fc%3D'});
      case '/userx/v1/info/get':
        return jsonResponse({
          'errno': 0,
          'data': {
            'fields': {'uid': '789'},
          },
        });
      case '/share/list':
        return jsonResponse({
          'errno': 0,
          'list': [
            {'fs_id': _file.id, 'dlink': _dispatcher},
          ],
        });
      case '/rest/2.0/xpan/share':
        return jsonResponse({
          'errno': 0,
          'share_id': '123',
          'uk': '456',
          'list': [],
        });
      case '/api/list':
        return jsonResponse({
          'errno': 0,
          'list': [
            {
              'fs_id': _file.id,
              'server_filename': _file.name,
              'path': _file.token,
              'size': _file.size,
              'isdir': 0,
            },
          ],
        });
      case '/file/video':
        if (r.uri.host == 'd.pcs.baidu.com') {
          return const HttpResult(302, '', {
            'location': [_cdn],
          });
        }
        return _range();
      default:
        throw StateError('Unexpected request ${r.uri.path}');
    }
  }
}

class _PlaybackHttp extends FakeHttp {
  _PlaybackHttp(super.respond);
  final redirectModes = <bool>[];
  final probeSizes = <int>[];
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) {
    redirectModes.add(followRedirects);
    return super.request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    );
  }

  @override
  Future<HttpResult> peek(
    String url,
    Map<String, String> headers, {
    int maxBytes = 8192,
    bool followRedirects = true,
  }) {
    probeSizes.add(maxBytes);
    return super.peek(
      url,
      headers,
      maxBytes: maxBytes,
      followRedirects: followRedirects,
    );
  }
}

class _PublicVideoParser extends BaiduPublicParser {
  _PublicVideoParser() : super(FakeHttp());
  int downloads = 0;
  @override
  Future<DownloadSpec> download(BrowseSession session, CloudFile file) async {
    downloads++;
    return DownloadSpec(
      url: 'https://download.baidupcs.com/public-video',
      fileName: file.name,
      profile: BaiduShareRoute.publicDownloadProfile,
    );
  }
}

HttpResult _range({
  int size = 4096,
  String? contentRange,
  String type = 'video/mp4',
}) => HttpResult(
  206,
  '\x00\x00\x00\x20ftypisom${List.filled(1012, '\x00').join()}',
  {
    'content-type': [type],
    'content-range': [contentRange ?? 'bytes 0-1023/$size'],
    'content-length': ['1024'],
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture f;
  setUp(() => f = _Fixture());

  test(
    'Personal playback uses the live-verified DLNA API and media headers',
    () async {
      final source = await f.play();
      final api = f.calls('/api/mediainfo').single;
      expect(api.method, 'GET');
      expect(api.uri.host, 'pan.baidu.com');
      expect(api.uri.queryParameters['path'], _file.token);
      expect(api.uri.queryParameters['type'], 'M3U8_FLV_264_480');
      expect(api.uri.queryParameters['origin'], 'dlna');
      expect(api.uri.queryParameters['clienttype'], '80');
      expect(api.uri.queryParameters['version'], '12.11.9');
      expect(api.uri.queryParameters['check_blue'], '1');
      expect(api.uri.queryParameters['app_id'], '250528');
      expect(
        api.uri.queryParameters['devuid'],
        matches(r'^[A-Z0-9]{32}\|[A-Z0-9]{9}$'),
      );
      expect(api.headers['Cookie'], _account().primary);
      expect(api.headers['User-Agent'], BaiduPlaybackClient.appUserAgent);
      expect(api.headers['Referer'], 'https://pan.baidu.com/disk/main');
      expect(f.http.redirectModes, everyElement(isFalse));
      expect(f.http.probeSizes, [1024, 1024]);
      for (final media in f.calls('/file/video')) {
        expect(media.headers['Range'], 'bytes=0-1023');
        expect(media.headers['User-Agent'], BaiduPlaybackClient.mediaUserAgent);
        expect(media.headers['Accept-Encoding'], 'identity');
        expect(media.headers, isNot(contains('Cookie')));
      }
      expect(source.url, _dispatcher);
      expect(source.headers, {
        'User-Agent': BaiduPlaybackClient.mediaUserAgent,
        'Accept-Encoding': 'identity',
      });
      expect(source.expectedSize, _file.size);
      expect(source.checksumValue, _file.hashValue);
      expect(source.profile, 'baidu');
      expect(source.cleanup, isNull);
      expect(f.downloads, 0);
    },
  );

  test(
    'HTTP 400 with a valid dlink remains playable despite errno 31023',
    () async {
      f.intercept = (r) => r.uri.path == '/api/mediainfo'
          ? jsonResponse({
              'errno': 31023,
              'error_code': 31023,
              'info': [
                {'dlink': _dispatcher},
              ],
            }, 400)
          : null;
      final source = await f.play();
      expect(source.url, _dispatcher);
      expect(f.calls('/api/mediainfo'), hasLength(1));
    },
  );

  for (final reason in ['empty', '403', 'html']) {
    test('An $reason primary response tries the alternate video API', () async {
      f.intercept = (r) {
        if (r.uri.path == '/api/mediainfo') {
          if (r.uri.queryParameters['type'] == 'VideoURL') {
            return jsonResponse({'errno': 31023, 'dlink': _dispatcher}, 400);
          }
          if (reason == 'empty') return jsonResponse({'errno': 31023});
          return jsonResponse({
            'errno': 0,
            'info': {'dlink': 'https://d.pcs.baidu.com/rejected'},
          });
        }
        if (r.uri.path == '/rejected') {
          return reason == '403'
              ? const HttpResult(403, 'denied')
              : const HttpResult(200, '<html>error</html>', {
                  'content-type': ['text/html'],
                });
        }
        return null;
      };
      final source = await f.play();
      final alternate = f.calls('/api/mediainfo').last;
      expect(alternate.uri.queryParameters, {
        'type': 'VideoURL',
        'path': _file.token,
        'fs_id': _file.id,
        'devuid': '0%1',
        'clienttype': '1',
        'channel': 'android_15_25010PN30C_bd-netdisk_1523a',
        'nom3u8': '1',
        'dlink': '1',
        'media': '1',
        'origin': 'dlna',
      });
      expect(alternate.headers['User-Agent'], BaiduPlaybackClient.webUserAgent);
      expect(source.headers['User-Agent'], 'netdisk');
      expect(f.downloads, 0);
    });
  }

  test(
    'Rejected media from both video routes cannot become a playback source',
    () async {
      f.intercept = (r) =>
          r.uri.path == '/file/video' ? const HttpResult(403, 'denied') : null;
      await expectLater(f.play(), throwsA(isA<AppException>()));
      expect(f.calls('/api/mediainfo'), hasLength(2));
      expect(f.downloads, 0);
    },
  );

  for (final response in [
    jsonResponse({'errno': -6}),
    const HttpResult(401, 'expired'),
    jsonResponse({'errno': -9}),
  ]) {
    test(
      'Authentication and missing-file failures do not try another route (${response.status}/${response.body})',
      () async {
        f.intercept = (r) => r.uri.path == '/api/mediainfo' ? response : null;
        await expectLater(f.play(), throwsA(isA<AppException>()));
        expect(f.calls('/api/mediainfo'), hasLength(1));
      },
    );
  }

  test(
    'A matching file ID is selected without losing a large numeric identity',
    () async {
      f.intercept = (r) => r.uri.path == '/api/mediainfo'
          ? jsonResponse({
              'errno': 0,
              'info': [
                {'dlink': 'https://d.pcs.baidu.com/unidentified'},
                {'fs_id': '42', 'dlink': 'https://d.pcs.baidu.com/wrong'},
                {'fs_id': _file.id, 'dlink': _dispatcher},
              ],
            })
          : null;
      expect((await f.play()).url, _dispatcher);
      expect(f.calls('/wrong'), isEmpty);
      expect(f.calls('/unidentified'), isEmpty);
    },
  );

  test(
    'A mismatched file identity cannot replace the selected video',
    () async {
      f.intercept = (r) => r.uri.path == '/api/mediainfo'
          ? jsonResponse({
              'errno': 0,
              'info': [
                {'fs_id': '42', 'dlink': _dispatcher},
              ],
            })
          : null;
      await expectLater(f.play(), throwsA(isA<AppException>()));
      expect(f.calls('/file/video'), isEmpty);
    },
  );

  for (final url in [
    'https://baidupcs.com.evil.invalid/video',
    'https://private@d.pcs.baidu.com/video',
    'file:///private/video.mp4',
  ]) {
    test(
      'Invalid media URL is rejected before sending a request ($url)',
      () async {
        f.intercept = (r) => r.uri.path == '/api/mediainfo'
            ? jsonResponse({
                'errno': 0,
                'info': {'dlink': url},
              })
            : null;
        await expectLater(f.play(), throwsA(isA<AppException>()));
        expect(f.http.probeSizes, isEmpty);
      },
    );
  }

  test(
    'Redirects to unrelated hosts are rejected without forwarding credentials',
    () async {
      f.intercept = (r) => r.uri.path == '/file/video'
          ? const HttpResult(302, '', {
              'location': ['https://evil.invalid/video'],
            })
          : null;
      await expectLater(f.play(), throwsA(isA<AppException>()));
      expect(f.http.calls.any((r) => r.uri.host == 'evil.invalid'), isFalse);
    },
  );

  for (final range in [
    'bytes 0-1023/8192',
    'bytes 1-1024/4096',
    'bytes 0-511/4096',
  ]) {
    test('Invalid size or Range identity is rejected ($range)', () async {
      f.intercept = (r) => r.uri.host == 'appall01.baidupcs.com'
          ? _range(contentRange: range)
          : null;
      await expectLater(f.play(), throwsA(isA<AppException>()));
    });
  }

  test('HLS carries no original-file size or checksum', () async {
    f.intercept = (r) => r.uri.host == 'appall01.baidupcs.com'
        ? const HttpResult(200, '#EXTM3U\n#EXTINF:10\nsegment.ts', {
            'content-type': ['application/vnd.apple.mpegurl'],
          })
        : null;
    final source = await f.play();
    expect(source.expectedSize, 0);
    expect(source.checksumType, isNull);
    expect(source.checksumValue, isNull);
  });

  test('Compressed media cannot be used as an original Range source', () async {
    f.intercept = (r) => r.uri.host == 'appall01.baidupcs.com'
        ? HttpResult(206, 'compressed-video', {
            ..._range().headers,
            'content-encoding': ['gzip'],
          })
        : null;
    await expectLater(f.play(), throwsA(isA<AppException>()));
    expect(f.calls('/api/mediainfo'), hasLength(2));
  });

  test('Legacy personal video reloads its path by exact file ID', () async {
    final source = await f.connector.playback(
      _personal,
      CloudFile(id: _file.id, name: _file.name, parentId: '/'),
      _account(),
    );
    expect(f.calls('/api/list'), hasLength(1));
    expect(
      f.calls('/api/mediainfo').single.uri.queryParameters['path'],
      _file.token,
    );
    expect(source.expectedSize, _file.size);
  });

  test(
    'Share playback signs current-account UID and freshly verifies its extraction code',
    () async {
      final source = await f.play(_share());
      final verify = f.calls('/share/verify').single;
      expect(verify.uri.queryParameters['surl'], 'fixture');
      expect(Uri.splitQueryString(verify.body as String)['pwd'], 'abcd');
      final user = f.calls('/userx/v1/info/get').single;
      expect(user.uri.host, 'mbd.baidu.com');
      final request = f.calls('/share/list').single;
      final parameters = request.uri.queryParameters;
      String sha(String value) => sha1.convert(utf8.encode(value)).toString();
      expect(
        parameters['rand'],
        sha(
          '${sha('alice')}789ebrcUYiuxaZv2XGu7KIYKxUrqfnOfpDF179325000012373CED981D0F186D12BC18CAE1684FFD5|VSRCQTF6W11.30.2ae5821440fab5e1a61a025f014bd8972',
        ),
      );
      expect(parameters['time'], '1793250000123');
      expect(parameters['shareid'], '123');
      expect(parameters['uk'], '456');
      expect(parameters['fid'], _file.id);
      expect(parameters['sekey'], 'a+b/c=');
      expect(parameters['origin'], 'dlna');
      expect(request.headers['User-Agent'], BaiduPlaybackClient.dlnaUserAgent);
      for (final api in [user, request]) {
        final pairs = LoginCredentials.cookiePairs(api.headers['Cookie']!);
        expect(pairs['BDUSS'], 'alice');
        expect(pairs['BDCLND'], 'a%2Bb%2Fc%3D');
        expect(api.headers['Cookie'], isNot(contains('stale-share')));
        expect(api.headers['Cookie'], isNot(contains('must-not-be-replayed')));
      }
      expect(source.headers, {
        'User-Agent': BaiduPlaybackClient.dlnaUserAgent,
        'Referer': 'https://pan.baidu.com/',
        'Accept-Encoding': 'identity',
      });
      expect(f.downloads, 0);
      expect(
        f.http.calls.any(
          (r) => {
            '/api/create',
            '/share/transfer',
            '/api/filemanager',
            '/api/recycle/clear',
          }.contains(r.uri.path),
        ),
        isFalse,
      );
    },
  );

  test(
    'Concurrent share requests keep account, share key and UID isolated',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      f.intercept = (r) async {
        final account = LoginCredentials.cookiePairs(
          r.headers['Cookie'] ?? '',
        )['BDUSS'];
        if (r.uri.path == '/share/verify') {
          return jsonResponse({'errno': 0, 'randsk': '$account%2Bgrant'});
        }
        if (r.uri.path == '/userx/v1/info/get') {
          if (account == 'alice') {
            entered.complete();
            await release.future;
          }
          return jsonResponse({
            'data': {
              'fields': {'uid': account == 'alice' ? '111' : '222'},
            },
          });
        }
        return null;
      };
      final first = f.play(_share(id: '123'), _account('alice'));
      await entered.future;
      final second = await f.play(_share(id: '124'), _account('bob'));
      release.complete();
      await first;
      final requests = f.calls('/share/list');
      expect(requests, hasLength(2));
      for (final r in requests) {
        final account = LoginCredentials.cookiePairs(
          r.headers['Cookie']!,
        )['BDUSS'];
        expect(
          r.uri.queryParameters['shareid'],
          account == 'alice' ? '123' : '124',
        );
        expect(r.uri.queryParameters['sekey'], '$account+grant');
      }
      expect(
        requests.first.uri.queryParameters['rand'],
        isNot(requests.last.uri.queryParameters['rand']),
      );
      expect(second.cleanup, isNull);
    },
  );

  test('Share playback requires a logged-in account', () async {
    await expectLater(
      f.connector.playback(_share(), _file, null),
      throwsA(isA<AccountLoginRequired>()),
    );
    expect(f.http.calls, isEmpty);
  });

  for (final cancelAt in [
    '/api/mediainfo',
    '/file/video',
    '/userx/v1/info/get',
  ]) {
    test(
      'Cancellation at $cancelAt prevents publishing a source or trying another route',
      () async {
        final scope = RequestScope();
        f.intercept = (r) {
          if (r.uri.path == cancelAt) scope.cancel();
          return null;
        };
        await expectLater(
          scope.run(
            () =>
                f.play(cancelAt == '/userx/v1/info/get' ? _share() : _personal),
          ),
          throwsA(
            isA<AppException>().having((e) => e.message, 'message', '请求已取消'),
          ),
        );
        expect(f.calls('/api/mediainfo').length, lessThanOrEqualTo(1));
      },
    );
  }

  test(
    'Audio playback uses download lookup while video downloads use the video API',
    () async {
      await f.connector.playback(
        _personal,
        const CloudFile(id: '42', name: 'audio.mp3', token: '/audio.mp3'),
        _account(),
      );
      final source = await f.connector.download(_personal, _file, _account());
      expect(f.downloads, 1);
      expect(f.calls('/api/mediainfo'), hasLength(1));
      expect(source.url, _dispatcher);
    },
  );

  test(
    'Public-parser videos with a logged-in account also use the built-in share API',
    () async {
      final session = BrowseSession.fromJson({
        ..._share().toJson(),
        'metadata': {
          ..._share().metadata,
          BaiduShareRoute.metadataKey: BaiduShareRoute.publicParser.key,
        },
      });
      final source = await f.play(session);
      expect(source.url, _dispatcher);
      expect(f.calls('/share/list'), hasLength(1));
      expect(f.http.calls.every((r) => r.uri.host != 'mf.dg22.top'), isTrue);
    },
  );

  test(
    'Share video download uses DLNA without transfer or relay lookup',
    () async {
      final source = await f.connector.download(_share(), _file, _account());
      expect(source.url, _dispatcher);
      expect(source.cleanup, isNull);
      expect(f.downloads, 0);
      expect(f.calls('/share/list'), hasLength(1));
      expect(f.calls('/share/transfer'), isEmpty);
      expect(f.calls('/api/create'), isEmpty);
    },
  );

  test(
    'Legacy shares recover their IDs from the official share before playing',
    () async {
      final session = BrowseSession.fromJson({
        ..._share().toJson(),
        'metadata': {'shortId': 'fixture'},
      });
      final source = await f.play(session);
      expect(source.url, _dispatcher);
      expect(f.calls('/share/verify'), hasLength(1));
      expect(f.calls('/rest/2.0/xpan/share'), hasLength(1));
      expect(
        f.calls('/share/list').single.uri.queryParameters['shareid'],
        '123',
      );
      expect(f.downloads, 0);
    },
  );

  test(
    'Anonymous public-parser video playback retains its existing route',
    () async {
      final parser = _PublicVideoParser();
      final connector = BaiduConnector(f.http, publicParser: parser);
      final session = BrowseSession.fromJson({
        ..._share().toJson(),
        'metadata': {
          ..._share().metadata,
          BaiduShareRoute.metadataKey: BaiduShareRoute.publicParser.key,
        },
      });
      final source = await connector.playback(session, _file, null);
      expect(source.url, 'https://download.baidupcs.com/public-video');
      expect(parser.downloads, 1);
      expect(f.http.calls, isEmpty);
    },
  );

  test(
    'Repository refresh obtains a new video link using the bound account',
    () async {
      final store = StateStore.memory();
      final vault = Vault(store);
      await vault.putCredential(CloudPlatform.baidu, _account());
      final originalOwner = vault.activeAccountId(CloudPlatform.baidu)!;
      final other = await vault.createAccount(CloudPlatform.baidu);
      await vault.withAccount(
        CloudPlatform.baidu,
        other,
        () => vault.putCredential(CloudPlatform.baidu, _account('bob')),
      );
      await vault.activate(CloudPlatform.baidu, other);
      final repository = CloudRepository(
        f.http,
        vault,
        CleanupOutbox(store, f.http),
      );
      repository.connectors[CloudPlatform.baidu] = f.connector;
      final session = _personal.withAccount(originalOwner);
      final first = await repository.preparePlayback(session, _file);
      var ticket = 0;
      f.intercept = (r) => r.uri.path == '/api/mediainfo'
          ? jsonResponse({
              'errno': 0,
              'info': {'dlink': '$_dispatcher&fresh=${++ticket}'},
            })
          : null;
      final refreshed = await repository.refreshPlayback(
        DownloadOrigin.fromJson(first.source!),
      );
      expect(refreshed.url, contains('fresh=1'));
      expect(f.calls('/api/mediainfo'), hasLength(2));
      expect(
        LoginCredentials.cookiePairs(
          f.calls('/api/mediainfo').last.headers['Cookie']!,
        )['BDUSS'],
        'alice',
      );
      expect(vault.activeAccountId(CloudPlatform.baidu), other);
      expect(f.downloads, 0);
    },
  );

  test(
    'Changing the account during resolution rejects the stale source',
    () async {
      final store = StateStore.memory();
      final vault = Vault(store);
      await vault.putCredential(CloudPlatform.baidu, _account());
      final repository = CloudRepository(
        f.http,
        vault,
        CleanupOutbox(store, f.http),
      );
      repository.connectors[CloudPlatform.baidu] = f.connector;
      f.intercept = (r) async {
        if (r.uri.path == '/api/mediainfo') {
          await vault.putCredential(CloudPlatform.baidu, _account('bob'));
        }
        return null;
      };
      await expectLater(
        repository.preparePlayback(_personal, _file),
        throwsA(isA<AppException>()),
      );
      expect(f.calls('/file/video'), isEmpty);
    },
  );

  test(
    'Video link diagnostics exclude account credentials and signed URLs',
    () async {
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = null;
        log.close();
      });
      await f.play(_share());
      final text = log.entries().map((e) => e.detail).join('\n');
      expect(text, contains('baidu.video_link_ready'));
      for (final secret in [
        'BDUSS',
        'alice',
        'fixture-token',
        'a%2Bb',
        'ticket=fixture',
        'key=1',
        _file.name,
      ]) {
        expect(text, isNot(contains(secret)));
      }
    },
  );

  test(
    'The player download button requests a fresh video ticket through the playback API',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-baidu-playback-',
      );
      final store = StateStore.memory();
      await Vault(store).putCredential(CloudPlatform.baidu, _account());
      final services = AppServices(
        store: store,
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(directory),
        http: f.http,
        platformFeatures: false,
        controlEnabled: false,
      );
      services.cloud.connectors[CloudPlatform.baidu] = f.connector;
      final events = <String>[];
      final backend = FakePlaybackBackend('baidu', events);
      final controller = cloudPlayback(services, _personal, _file, [
        _file,
      ], backendFactory: (_, _) => backend);
      addTearDown(() async {
        await controller.close();
        await services.close();
        await directory.delete(recursive: true);
      });
      await controller.load(0);
      expect(backend.openedSource!.url, _dispatcher);
      final download = await controller.acquireForDownload();
      expect(download.url, _dispatcher);
      expect(f.downloads, 0);
      expect(f.calls('/api/mediainfo'), hasLength(2));
    },
  );
}
