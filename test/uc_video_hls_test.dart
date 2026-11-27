import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/download_network_policy.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uc_video_download.dart';
import 'uc_tv_support.dart';
import 'uc_video_download_support.dart';

const _url = 'https://video-play.drive.uc.cn/qv/media.m3u8?sign=synthetic';
const _playlist =
    '#EXTM3U\n#EXT-X-VERSION:3\n'
    '#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:10\n'
    '#EXTINF:10,\nsegment0.ts\n#EXTINF:4,\nsegment1.ts\n#EXT-X-ENDLIST\n';

Json _track() => {
  ...ucPlayableItem(url: _url),
  'supports_format': 'p_qv',
  'video_info': {
    ...ucPlayableItem(url: _url).obj('video_info'),
    'format': 'm3u8',
    'file_format': 'm3u8',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'UC p_qv transcode can use the existing segmented download path',
    () async {
      final f = ucPlayableFixture();
      f.respond = (r) {
        if (r.uri.path.endsWith('/v2/play')) {
          return ucPlayableResponse(
            items: [
              ucPlayableItem(resolution: 'high', accessible: false),
              _track(),
            ],
          );
        }
        if (r.uri.host == 'video-play.drive.uc.cn') {
          return const HttpResult(200, _playlist);
        }
        return null;
      };
      final spec = await f.repository.prepareUcPlayable(ucTvShare, ucTvVideo);
      expect(spec.url, _url);
      expect(spec.fileName, '视频（流畅 270×480）.ts');
      expect(spec.expectedSize, 0);
      expect(spec.checksumType, isNull);
      expect(spec.checksumValue, isNull);
      final saved = DownloadSpec.fromJson(spec.toJson());
      final quality = UcVideoDownload.fromSpec(saved)!;
      expect(quality.size, 120);
      expect(quality.segmented, isTrue);
      expect(quality.format, 'hls_ts');
      expect(
        saved.networkPolicy!.checkedUrl(_url).host,
        'video-play.drive.uc.cn',
      );
      expect(
        () => saved.networkPolicy!.checkedUrl('https://other.example/part.ts'),
        throwsA(isA<DownloadNetworkPolicyException>()),
      );
      expect(saved.headers['Cookie'], f.credential.primary);
      expect(f.http.redirectPolicies.last, isFalse);
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
      await f.cleanups.release(spec.cleanup);
      await f.cleanups.ready(spec.cleanup);
      await f.cleanups.drain();
      expect(f.cleanups.pendingCount, 0);
    },
  );

  for (final variant in [
    'encrypted',
    'truncated',
    'foreign-segment',
    'foreign-map',
    'http-segment',
    'redirect',
    'html',
    'master',
    'range',
  ]) {
    test(
      'Reject unsafe or unsupported HLS before adding a task: $variant',
      () async {
        final f = ucPlayableFixture();
        f.respond = (r) {
          if (r.uri.path.endsWith('/v2/play')) {
            return ucPlayableResponse(items: [_track()]);
          }
          if (r.uri.host == 'video-play.drive.uc.cn') {
            return switch (variant) {
              'encrypted' => HttpResult(
                200,
                _playlist.replaceFirst(
                  '#EXTINF:',
                  '#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:',
                ),
              ),
              'truncated' => HttpResult(
                200,
                _playlist.replaceAll('#EXT-X-ENDLIST', ''),
              ),
              'foreign-segment' => HttpResult(
                200,
                _playlist.replaceFirst(
                  'segment0.ts',
                  'https://other.example/part.ts',
                ),
              ),
              'foreign-map' => HttpResult(
                200,
                _playlist.replaceFirst(
                  '#EXTINF:',
                  '#EXT-X-MAP:URI="https://other.example/init.mp4"\n#EXTINF:',
                ),
              ),
              'http-segment' => HttpResult(
                200,
                _playlist.replaceFirst(
                  'segment0.ts',
                  'http://video-play.drive.uc.cn/part.ts',
                ),
              ),
              'redirect' => const HttpResult(302, '', {
                'location': ['https://other.example/list.m3u8'],
              }),
              'html' => const HttpResult(200, '<html>login required</html>'),
              'master' => const HttpResult(
                200,
                '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nchild.m3u8\n#EXT-X-ENDLIST',
              ),
              _ => HttpResult(
                200,
                _playlist.replaceFirst(
                  '#EXTINF:',
                  '#EXT-X-BYTERANGE:120@0\n#EXTINF:',
                ),
              ),
            };
          }
          return null;
        };
        await expectLater(
          f.repository.prepareUcPlayable(ucTvShare, ucTvVideo),
          throwsA(isA<AppException>()),
        );
        expect(
          f.http.calls.where((r) => r.uri.host == 'other.example'),
          isEmpty,
        );
        await f.cleanups.drain();
        expect(f.cleanups.pendingCount, 0);
      },
    );
  }

  test(
    'Expired HLS refresh preserves format and rejects a container change',
    () async {
      final f = ucPlayableFixture();
      var fragmented = false;
      f.respond = (r) {
        if (r.uri.path.endsWith('/v2/play')) {
          return ucPlayableResponse(items: [_track()]);
        }
        if (r.uri.host == 'video-play.drive.uc.cn') {
          return HttpResult(
            200,
            fragmented
                ? _playlist.replaceFirst(
                    '#EXTINF:',
                    '#EXT-X-MAP:URI="init.mp4"\n#EXTINF:',
                  )
                : _playlist,
          );
        }
        return null;
      };
      final spec = await f.repository.prepareUcPlayable(
        ucTvPersonal,
        ucTvVideo,
      );
      final fresh = await f.repository.refresh(
        DownloadSpec.fromJson(spec.toJson()),
      );
      expect(fresh.source!['ucVideo'], spec.source!['ucVideo']);
      expect(fresh.networkPolicy, isNotNull);
      fragmented = true;
      await expectLater(
        f.repository.refresh(spec),
        throwsA(isA<AppException>()),
      );
    },
  );

  for (final cancel in [true, false]) {
    test(
      'HLS read respects ${cancel ? 'cancellation' : 'account removal'}',
      () async {
        final f = ucPlayableFixture(), scope = RequestScope();
        f.respond = (r) {
          if (r.uri.path.endsWith('/v2/play')) {
            return ucPlayableResponse(items: [_track()]);
          }
          if (r.uri.host == 'video-play.drive.uc.cn') {
            return () async {
              if (cancel) {
                scope.cancel();
              } else {
                await f.vault.removeCredential(CloudPlatform.uc);
              }
              return const HttpResult(200, _playlist);
            }();
          }
          return null;
        };
        await expectLater(
          scope.run(
            () => f.repository.prepareUcPlayable(ucTvPersonal, ucTvVideo),
          ),
          throwsA(isA<AppException>()),
        );
      },
    );
  }
}
