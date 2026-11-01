import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/providers/aliyun.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'package:asterlink/playback/recent_playback.dart';
import 'player_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const platform = CloudPlatform.aliyun;
const previewPath = '/adrive/v1.0/openFile/getVideoPreviewPlayInfo';
const openDownloadPath = '/adrive/v1.0/openFile/getDownloadUrl';
const downloadPath = '/v2/file/get_download_url';
const openAccess = 'fixture-open-access-token-0123456789';
const openRefresh = 'fixture-open-refresh-token-0123456789';
const renewedOpenAccess = 'renewed-open-access-token-0123456789';
const openOAuth = 'https://api.oplist.org/alicloud/callback';
const originalUrl = 'https://cdn.example/original.mp4?signature=download';
const streamUrl = 'https://cdn.example/video.m3u8?signature=playback';

Future<Vault> playbackVault() => tokenVault(
  platform,
  tokenCredential(
    platform,
    fields: {
      'openAccessToken': openAccess,
      'openRefreshToken': openRefresh,
      'openTokenType': 'Bearer',
      'openExpiresAt': '${tokenClock + 3600000}',
    },
  ),
);

HttpResult openAuthResponse(
  RecordedRequest request,
) => switch (request.uri.path) {
  '/alicloud/requests' => jsonResponse({
    'text': query('https://openapi.aliyundrive.com/oauth/authorize', {
      'client_id': 'fixture-client',
      'redirect_uri': openOAuth,
      'response_type': 'code',
    }),
  }),
  '/oauth/users/authorize' => jsonResponse({
    'redirectUri': '$openOAuth?code=fixture-code',
  }),
  '/alicloud/callback' => HttpResult(302, '', {
    'location': [
      'https://doc.oplist.org/#${base64.encode(utf8.encode(encoded({'access_token': renewedOpenAccess, 'refresh_token': openRefresh, 'token_type': 'Bearer', 'expires_in': 7200, 'user_id': 'user-1'})))}',
    ],
  }),
  _ => aliDefaultResponse(request),
};

Json streamTask({
  String template = 'HD',
  String url = streamUrl,
  String status = 'finished',
  int width = 1280,
  int height = 720,
}) => {
  'template_id': template,
  'template_width': width,
  'template_height': height,
  'status': status,
  'url': url,
};

HttpResult previewResponse({
  List<Json>? tasks,
  List<Json>? quick,
  String file = 'file-1',
  String drive = 'resource',
}) => jsonResponse({
  'drive_id': drive,
  'file_id': file,
  'video_preview_play_info': {
    'quick_video_list': ?quick,
    'live_transcoding_task_list': tasks ?? [streamTask()],
  },
});

HttpResult originalResponse() =>
    jsonResponse({...aliFile('file-1'), 'url': originalUrl});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'personal video uses the highest available full stream and CDN headers',
    () async {
      final vault = await playbackVault();
      final http = FakeHttp((r) {
        expect(r.uri.host, 'open.aliyundrive.com');
        expect(r.uri.path, previewPath);
        expect(r.json, {
          'drive_id': 'backup',
          'file_id': 'file-1',
          'category': 'live_transcoding',
          'url_expire_sec': '14400',
        });
        expect(JsonHttp.isReadRequest(r.method, r.url), isTrue);
        expect(r.headers['Authorization'], 'Bearer $openAccess');
        expect(r.headers['X-Signature'], isNull);
        expect(r.headers['X-Device-Id'], isNull);
        expect(r.headers['X-Canary'], isNull);
        return previewResponse(
          drive: 'backup',
          tasks: [
            streamTask(
              template: 'SD',
              width: 960,
              height: 540,
              url: '$streamUrl-sd',
            ),
            streamTask(template: 'FHD', width: 1920, height: 1080, url: ''),
            streamTask(),
            streamTask(
              template: 'QHD',
              width: 2560,
              height: 1440,
              status: 'running',
            ),
            streamTask(
              template: 'QHD',
              width: 2560,
              height: 1440,
              url: 'file:///private',
            ),
          ],
        );
      });
      const file = CloudFile(
        id: 'file-1',
        name: 'movie.mp4',
        size: 4,
        hashType: 'sha1',
        hashValue: '0123456789abcdef0123456789abcdef01234567',
      );
      final source = await AliyunConnector(http, vault, now: () => tokenClock)
          .playback(
            tokenPersonal(platform, drive: 'backup'),
            file,
            vault.credential(platform),
          );
      expect(source.url, streamUrl);
      expect(source.fileName, file.name);
      expect(source.expectedSize, 0);
      expect(source.checksumType, isNull);
      expect(source.checksumValue, isNull);
      expect(source.headers.keys, unorderedEquals(['Referer', 'User-Agent']));
      expect(source.headers['Referer'], 'https://www.aliyundrive.com/');
      expect(source.headers['User-Agent'], contains('Windows NT'));
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'quick-video streams take precedence and can omit task status',
    () async {
      final vault = await playbackVault();
      final quick = <String, dynamic>{
        ...streamTask(
          template: 'FHD',
          width: 1920,
          height: 1080,
          url: '$streamUrl-quick',
        ),
      }..remove('status');
      final http = FakeHttp((r) {
        expect(r.uri.path, previewPath);
        return previewResponse(
          quick: [streamTask(), quick],
          tasks: [
            streamTask(
              template: 'QHD',
              width: 2560,
              height: 1440,
              url: '$streamUrl-transcoded',
            ),
          ],
        );
      });
      final source = await AliyunConnector(http, vault, now: () => tokenClock)
          .playback(
            tokenPersonal(platform),
            tokenFile,
            vault.credential(platform),
          );
      expect(source.url, '$streamUrl-quick');
    },
  );

  test(
    'stream selection follows template width rather than pixel area',
    () async {
      final vault = await playbackVault();
      final http = FakeHttp(
        (_) => previewResponse(
          tasks: [
            streamTask(width: 1080, height: 1920, url: '$streamUrl-portrait'),
            streamTask(width: 1920, height: 800, url: '$streamUrl-wide'),
          ],
        ),
      );
      final source = await AliyunConnector(http, vault, now: () => tokenClock)
          .playback(
            tokenPersonal(platform),
            tokenFile,
            vault.credential(platform),
          );
      expect(source.url, '$streamUrl-wide');
    },
  );

  for (final unavailable in [
    ('no transcodes', previewResponse(tasks: [])),
    ('empty quick list', previewResponse(quick: [])),
    (
      'pending transcode',
      previewResponse(tasks: [streamTask(status: 'running')]),
    ),
    (
      'trial only',
      previewResponse(
        tasks: [
          {...streamTask(url: ''), 'preview_url': streamUrl},
        ],
      ),
    ),
    (
      'invalid address',
      previewResponse(
        tasks: [streamTask(url: 'https://user:secret@cdn.example/v.m3u8')],
      ),
    ),
    ('unsupported API', jsonResponse({'code': 'NotFound.Api'}, 404)),
    (
      'temporary API failure',
      jsonResponse({'code': 'ServiceUnavailable'}, 503),
    ),
    ('invalid API response', const HttpResult(502, 'upstream unavailable')),
  ]) {
    test(
      '${unavailable.$1} falls back to the complete original file',
      () async {
        final vault = await playbackVault();
        final http = FakeHttp((r) {
          if (r.uri.path == previewPath) return unavailable.$2;
          expect(r.uri.path, openDownloadPath);
          expect(r.headers['Authorization'], 'Bearer $openAccess');
          return originalResponse();
        });
        final source = await AliyunConnector(http, vault, now: () => tokenClock)
            .playback(
              tokenPersonal(platform),
              tokenFile,
              vault.credential(platform),
            );
        expect(source.url, originalUrl);
        expect(source.expectedSize, tokenFile.size);
        expect(http.calls.map((r) => r.uri.path), [
          previewPath,
          openDownloadPath,
        ]);
      },
    );
  }

  for (final invalid in [
    ('file ID', {...aliFile('another-file'), 'url': originalUrl}),
    (
      'drive ID',
      {...aliFile('file-1'), 'drive_id': 'another-drive', 'url': originalUrl},
    ),
    ('size', {...aliFile('file-1'), 'size': 400, 'url': originalUrl}),
    ('folder', {...aliFile('file-1', folder: true), 'url': originalUrl}),
    (
      'URL',
      {
        ...aliFile('file-1'),
        'url': 'https://user:secret@cdn.example/original.mp4',
      },
    ),
    (
      'download-only field',
      {...aliFile('file-1'), 'download_url': originalUrl},
    ),
  ]) {
    test(
      'invalid original ${invalid.$1} is rejected by the open playback fallback',
      () async {
        final vault = await playbackVault();
        final http = FakeHttp(
          (r) => r.uri.path == previewPath
              ? previewResponse(tasks: [])
              : jsonResponse(invalid.$2),
        );
        await expectLater(
          AliyunConnector(http, vault, now: () => tokenClock).playback(
            tokenPersonal(platform),
            tokenFile,
            vault.credential(platform),
          ),
          throwsA(isA<AppException>()),
        );
        expect(http.calls.map((r) => r.uri.path), [
          previewPath,
          openDownloadPath,
        ]);
      },
    );
  }

  test(
    'a retryable preview network failure can still use the original file',
    () async {
      final vault = await playbackVault();
      final http = FakeHttp((r) {
        if (r.uri.path == previewPath) {
          throw const HttpRequestFailure(
            'timeout',
            kind: 'receiveTimeout',
            retryable: true,
          );
        }
        return originalResponse();
      });
      final source = await AliyunConnector(http, vault, now: () => tokenClock)
          .playback(
            tokenPersonal(platform),
            tokenFile,
            vault.credential(platform),
          );
      expect(source.url, originalUrl);
    },
  );

  test(
    'video previews renew a rejected OpenToken through the ordinary login',
    () async {
      final vault = await playbackVault();
      var previews = 0;
      final http = FakeHttp((r) {
        if (r.uri.path == previewPath) {
          previews++;
          if (previews == 1) {
            return jsonResponse({'code': 'AccessTokenExpired'}, 401);
          }
          expect(r.headers['Authorization'], 'Bearer $renewedOpenAccess');
          expect(r.headers['X-Signature'], isNull);
          return previewResponse();
        }
        return openAuthResponse(r);
      });
      final source = await AliyunConnector(http, vault, now: () => tokenClock)
          .playback(
            tokenPersonal(platform),
            tokenFile,
            vault.credential(platform),
          );
      expect(source.url, streamUrl);
      expect(previews, 2);
      expect(vault.credential(platform)!.field('refreshToken'), refreshToken);
      expect(
        vault.credential(platform)!.field('openAccessToken'),
        renewedOpenAccess,
      );
      expect(vault.credential(platform)!.updatedAt, 42);
      expect(http.calls.where((r) => r.uri.path == downloadPath), isEmpty);
    },
  );

  for (final invalid in [
    ('wrong file', previewResponse(file: 'different-file')),
    ('wrong drive', previewResponse(drive: 'different-drive')),
    ('deleted file', jsonResponse({'code': 'NotFound.FileId'}, 404)),
    (
      'recycled file',
      jsonResponse({'code': 'ForbiddenFileInTheRecycleBin'}, 403),
    ),
  ]) {
    test('${invalid.$1} is not hidden by a download fallback', () async {
      final vault = await playbackVault();
      final http = FakeHttp((_) => invalid.$2);
      await expectLater(
        AliyunConnector(http, vault, now: () => tokenClock).playback(
          tokenPersonal(platform),
          tokenFile,
          vault.credential(platform),
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.map((r) => r.uri.path), [previewPath]);
    });
  }

  test(
    'invalid login is reported without trying an original download',
    () async {
      final vault = await playbackVault();
      final http = FakeHttp(
        (r) => r.uri.path == '/v2/account/token'
            ? jsonResponse({'code': 'InvalidParameter.RefreshToken'}, 400)
            : r.uri.path == '/alicloud/requests'
            ? openAuthResponse(r)
            : jsonResponse({'code': 'AccessTokenExpired'}, 401),
      );
      await expectLater(
        AliyunConnector(http, vault, now: () => tokenClock).playback(
          tokenPersonal(platform),
          tokenFile,
          vault.credential(platform),
        ),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls.where((r) => r.uri.path == openDownloadPath), isEmpty);
    },
  );

  for (final replaceAccount in [false, true]) {
    test(
      '${replaceAccount ? 'account replacement' : 'cancellation'} rejects a pending preview',
      () async {
        final vault = await playbackVault();
        final entered = Completer<void>(), release = Completer<void>();
        final http = FakeHttp((r) async {
          expect(r.uri.path, previewPath);
          entered.complete();
          await release.future;
          return previewResponse();
        });
        final connector = AliyunConnector(http, vault, now: () => tokenClock);
        final scope = RequestScope();
        final pending = scope.run(
          () => connector.playback(
            tokenPersonal(platform),
            tokenFile,
            vault.credential(platform),
          ),
        );
        final rejected = expectLater(pending, throwsA(isA<AppException>()));
        await entered.future;
        if (replaceAccount) {
          await vault.putCredential(
            platform,
            tokenCredential(platform, revision: 99),
          );
        } else {
          scope.cancel();
        }
        release.complete();
        await rejected;
        expect(http.calls, hasLength(1));
      },
    );
  }

  test(
    'non-video playback and direct video downloads keep original bytes',
    () async {
      final vault = await playbackVault();
      final http = FakeHttp((r) {
        expect(r.uri.path, downloadPath);
        expect(r.headers['Authorization'], 'Bearer $accessToken');
        return originalResponse();
      });
      final connector = AliyunConnector(http, vault, now: () => tokenClock);
      final audio = await connector.playback(
        tokenPersonal(platform),
        const CloudFile(id: 'file-1', name: 'song.flac', size: 4),
        vault.credential(platform),
      );
      final download = await connector.download(
        tokenPersonal(platform),
        tokenFile,
        vault.credential(platform),
      );
      expect(audio.url, originalUrl);
      expect(download.url, originalUrl);
      expect(download.expectedSize, 4);
      expect(http.calls, hasLength(2));
    },
  );

  for (final fallback in [false, true]) {
    test(
      'share ${fallback ? 'fallback' : 'stream'} keeps its copied file until playback releases it',
      () async {
        final vault = await playbackVault();
        var name = '', copies = 0, deletions = 0;
        late CleanupOutbox cleanups;
        final http = FakeHttp((r) {
          switch (r.uri.path) {
            case '/adrive/v1.0/user/getDriveInfo':
              return jsonResponse({
                'resource_drive_id': 'resource',
                'backup_drive_id': 'backup',
                'user_id': 'user-1',
              });
            case '/adrive/v1.0/openFile/create':
              name = r.json.str('name');
              return jsonResponse(
                aliFile('temporary', folder: true, name: name),
              );
            case '/adrive/v2/file/copy':
              copies++;
              expect(cleanups.pendingCount, 1);
              expect(r.json['to_drive_id'], 'resource');
              expect(r.json['to_parent_file_id'], 'temporary');
              expect(r.json['share_id'], 'Share123');
              expect(r.headers['Authorization'], 'Bearer $accessToken');
              expect(r.headers['X-Signature'], isNull);
              expect(r.headers['X-Share-Token'], 'fixture-share-token');
              return jsonResponse({'file_id': 'copied'});
            case '/adrive/v1.0/openFile/list':
              return jsonResponse({
                'items': [aliFile('copied', parent: 'temporary')],
              });
            case previewPath:
              expect(r.json['file_id'], 'copied');
              expect(r.json['drive_id'], 'resource');
              return previewResponse(
                file: 'copied',
                tasks: fallback ? [] : null,
              );
            case openDownloadPath:
              expect(r.json['file_id'], 'copied');
              return jsonResponse({...aliFile('copied'), 'url': originalUrl});
            case '/v2/file/get':
              return jsonResponse(
                aliFile('temporary', folder: true, name: name),
              );
            case '/v2/recyclebin/trash':
              deletions++;
              expect(r.json['file_id'], 'temporary');
              return jsonResponse({});
            default:
              return aliDefaultResponse(r);
          }
        });
        cleanups = CleanupOutbox(vault.store, http);
        final repo = CloudRepository(http, vault, cleanups);
        repo.connectors[platform] = AliyunConnector(
          http,
          vault,
          now: () => tokenClock,
          taskDelay: Duration.zero,
          stageCleanup: (cleanup) => cleanups.stage(cleanup),
        );
        final source = await repo.preparePlayback(
          tokenShare(platform),
          tokenFile,
        );
        expect(source.url, fallback ? originalUrl : streamUrl);
        expect(source.cleanup, isNotNull);
        expect(copies, 1);
        await cleanups.ready(source.cleanup);
        await cleanups.drain();
        expect(deletions, 0);
        await cleanups.release(source.cleanup);
        await cleanups.ready(source.cleanup);
        await cleanups.drain();
        expect(deletions, 1);
        expect(cleanups.pendingCount, 0);
      },
    );
  }

  test(
    'player download, URL refresh and history reopen resolve the appropriate Aliyun source',
    () async {
      final vault = await tokenVault(
        platform,
        tokenCredential(
          platform,
          fields: {
            'expiresAt': '4102444800000',
            'sessionExpiresAt': '4102444800000',
            'openAccessToken': openAccess,
            'openRefreshToken': openRefresh,
            'openExpiresAt': '4102444800000',
          },
        ),
      );
      var previews = 0, downloads = 0;
      final http = FakeHttp((r) {
        if (r.uri.path == previewPath) {
          previews++;
          return previewResponse(
            tasks: [streamTask(url: '$streamUrl-$previews')],
          );
        }
        if (r.uri.path == downloadPath) {
          downloads++;
          return originalResponse();
        }
        if (r.uri.path == '/adrive/v3/file/list') {
          return jsonResponse({
            'items': [aliFile('file-1')],
          });
        }
        return aliDefaultResponse(r);
      });
      final services = AppServices(
        store: vault.store,
        dataDirectory: Directory('test-fixture'),
        cacheDirectory: Directory('test-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('test-fixture')),
        http: http,
        platformFeatures: false,
        controlEnabled: false,
      );
      addTearDown(services.close);
      FakePlaybackBackend backend(entry, _) =>
          FakePlaybackBackend(entry.id, []);
      final controller = cloudPlayback(
        services,
        tokenPersonal(platform),
        tokenFile,
        [tokenFile],
        backendFactory: backend,
      );
      addTearDown(controller.close);
      await controller.start();
      expect(controller.ready, isTrue);
      expect(
        (controller.backend as FakePlaybackBackend).openedSource!.url,
        '$streamUrl-1',
      );
      final downloaded = await controller.acquireForDownload();
      expect(downloaded.url, originalUrl);
      expect(downloaded.expectedSize, tokenFile.size);
      expect(downloads, 1);
      final firstBackend = controller.backend as FakePlaybackBackend;
      firstBackend.emit(
        firstBackend.state.copyWith(position: const Duration(seconds: 35)),
      );
      await controller.retry();
      expect(
        (controller.backend as FakePlaybackBackend).openedSource!.url,
        '$streamUrl-2',
      );
      expect(controller.state.position, const Duration(seconds: 35));
      await controller.saveProgress();
      final history = PlaybackStore(vault.store).recent.single;
      final serialized = jsonEncode(vault.store.data['playbackHistory']);
      expect(serialized, isNot(contains('signature=')));
      expect(serialized, isNot(contains(accessToken)));
      expect(serialized, isNot(contains(openAccess)));
      expect(serialized, isNot(contains(openRefresh)));
      await controller.close();
      final reopened = await restoreRecentPlayback(
        services,
        history,
        backendFactory: backend,
      );
      addTearDown(reopened.close);
      await reopened.start();
      expect(reopened.ready, isTrue);
      expect(
        (reopened.backend as FakePlaybackBackend).openedSource!.url,
        '$streamUrl-3',
      );
      expect(reopened.resumedFrom, const Duration(seconds: 35));
      expect(downloads, 1);
    },
  );
}
