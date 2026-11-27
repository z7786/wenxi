import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'player_support.dart';
import 'support.dart';

class _SubtitleCloud extends QuarkConnector {
  _SubtitleCloud() : super(FakeHttp());
  final files = <String>[];
  final requested = <CloudFile>[];
  @override
  Future<DownloadSpec> playback(BrowseSession s, CloudFile f, Credential? c) =>
      download(s, f, c);
  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    files.add(f.id);
    requested.add(f);
    return DownloadSpec(
      url: 'https://example.invalid/${f.id}',
      fileName: f.name,
      expectedSize: f.size,
      headers: {'Cookie': c!.primary},
    );
  }
}

class _ShareSubtitleCloud extends QuarkConnector {
  _ShareSubtitleCloud(super.http, Vault store)
    : super(
        store: store,
        directShareDownloadEnabled: (authenticated) => authenticated,
      );

  @override
  Future<DownloadSpec> playback(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async => DownloadSpec(
    url: 'https://example.invalid/video',
    fileName: f.name,
    expectedSize: f.size,
  );
}

class _SubtitleTransfer extends TransferHttp {
  Future<void>? barrier;
  Uint8List bytes = Uint8List.fromList(
    utf8.encode('1\n00:00:00,000 --> 00:00:08,000\n中文字幕\n'),
  );
  String? requestedUrl;
  Map<String, String>? requestedHeaders;
  @override
  Future<Uint8List> limited(
    String url,
    Map<String, String> headers,
    int limit,
  ) async {
    requestedUrl = url;
    requestedHeaders = headers;
    await barrier;
    return bytes;
  }
}

class _SubtitleAdapter implements HttpClientAdapter {
  _SubtitleAdapter(this.bytes);
  final Uint8List bytes;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    expect(options.uri.toString(), 'https://dl.quark.cn/caption');
    expect(
      options.headers['Cookie'],
      '__pus=caption-owner; __puus=caption-session',
    );
    expect(options.headers['Referer'], 'https://pan.quark.cn/');
    return ResponseBody(Stream.value(bytes), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppServices services;
  late PlaybackController controller;
  late _SubtitleCloud cloud;
  late _SubtitleTransfer transfer;
  late FakePlaybackBackend backend;
  const video = CloudFile(
    id: 'video',
    name: 'Show.S01E02.mkv',
    parentId: 'folder',
    size: 1000000,
  );
  const caption = CloudFile(
    id: 'caption',
    name: 'Show.S01E02.zh-cn.srt',
    parentId: 'folder',
    size: 64,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'asterlink-player-cloud-subtitles-',
    );
    transfer = _SubtitleTransfer();
    services = AppServices(
      store: StateStore.memory({
        'credentials': {
          'Quark': Credential('fixture', {
            'primary': '__pus=caption-owner',
          }, updatedAt: 42).toJson(),
        },
      }),
      dataDirectory: root,
      cacheDirectory: Directory('${root.path}/cache'),
      transport: FakeNative(),
      files: FakeFiles(root),
      http: FakeHttp(),
      transferHttp: transfer,
      platformFeatures: false,
      controlEnabled: false,
    );
    cloud = _SubtitleCloud();
    services.cloud.connectors[CloudPlatform.quark] = cloud;
    controller = cloudPlayback(
      services,
      const BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'fixture',
        rootId: 'folder',
      ),
      video,
      const [
        video,
        caption,
        CloudFile(
          id: 'other-folder',
          name: 'Show.S01E02.chs.ass',
          parentId: 'elsewhere',
        ),
        CloudFile(
          id: 'too-large',
          name: 'Show.S01E02.chs.ass',
          parentId: 'folder',
          size: 9 * 1024 * 1024,
        ),
      ],
      backendFactory: (entry, _) => backend = FakePlaybackBackend(entry.id, []),
    );
  });
  tearDown(() async {
    await controller.close();
    await services.close();
    await removePlayerFixture(root);
  });

  test(
    'Playback labels decode while source and subtitle names stay raw',
    () async {
      await controller.close();
      const episode = CloudFile(
        id: 'episode-15',
        name: '[第15話 Φ&#39;s VS χ].mkv',
        displayName: "[第15話 Φ's VS χ].mkv",
        parentId: 'folder',
        size: 2213557610,
      );
      const subtitle = CloudFile(
        id: 'encoded-subtitle',
        name: 'Φ&#39;s.srt',
        displayName: "Φ's.srt",
        parentId: 'folder',
        size: 64,
      );
      controller = cloudPlayback(
        services,
        const BrowseSession(
          platform: CloudPlatform.quark,
          mode: BrowseMode.personal,
          title: 'fixture',
          rootId: 'folder',
        ),
        episode,
        const [episode, subtitle],
        backendFactory: (entry, _) =>
            backend = FakePlaybackBackend(entry.id, []),
      );
      expect(controller.current.name, episode.displayName);
      expect(controller.current.source!.cloud!.file.name, episode.name);
      expect(controller.current.source!.cloud!.file.token, episode.token);
      await controller.start();
      expect(controller.error, isEmpty);
      expect(controller.current.name, episode.displayName);
      expect(backend.openedSource!.fileName, episode.name);
      expect(controller.availableSubtitles.single.name, subtitle.displayName);
      await controller.loadCloudSubtitle(controller.availableSubtitles.single);
      expect(cloud.files, contains(subtitle.id));
      expect(cloud.requested.first.name, episode.name);
      expect(cloud.requested.last.name, subtitle.name);
    },
  );

  test(
    'A same-directory subtitle uses its own authenticated source and a bounded private copy',
    () async {
      await controller.start();
      await until(() => controller.cloudSubtitleId == 'caption');
      expect(controller.availableSubtitles.map((item) => item.id), ['caption']);
      expect(transfer.requestedUrl, 'https://example.invalid/caption');
      expect(transfer.requestedHeaders!['Cookie'], '__pus=caption-owner');
      expect(cloud.files, ['video', 'caption']);
      final file = File.fromUri(Uri.parse(backend.state.track.subtitle.id));
      expect(
        p.equals(
          file.parent.path,
          p.join(services.cacheDirectory.path, 'subtitles'),
        ),
        isTrue,
      );
      expect(await file.readAsString(), contains('中文字幕'));
      expect(backend.state.playing, isTrue);
      await controller.close();
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'A selected GBK cloud subtitle is normalized before the player reads it',
    () async {
      transfer.bytes = Uint8List.fromList([
        ...ascii.encode('1\n00:00:00,000 --> 00:00:08,000\n'),
        0xd6,
        0xd0,
        0xce,
        0xc4,
        0xd7,
        0xd6,
        0xc4,
        0xbb,
        10,
      ]);
      await controller.start();
      await until(() => controller.cloudSubtitleId == 'caption');
      final file = File.fromUri(Uri.parse(backend.state.track.subtitle.id));
      expect(
        await file.readAsString(),
        '1\n00:00:00,000 --> 00:00:08,000\n中文字幕\n',
      );
      expect(cloud.requested.last.id, caption.id);
      expect(transfer.requestedHeaders!['Cookie'], '__pus=caption-owner');
      expect(controller.error, isEmpty);
    },
  );

  test(
    'An invalid cloud response reports why selection failed and can be retried',
    () async {
      transfer.bytes = Uint8List.fromList(utf8.encode('<html>expired</html>'));
      await controller.start();
      await until(() => !controller.subtitleLoading);
      expect(controller.cloudSubtitleId, isNull);
      expect(controller.notice, isEmpty);
      await controller.loadCloudSubtitle(controller.availableSubtitles.single);
      expect(controller.notice, contains('有效字幕'));
      expect(controller.cloudSubtitleId, isNull);
      expect(backend.state.playing, isTrue);
      transfer.bytes = Uint8List.fromList(
        utf8.encode('1\n00:00:00,000 --> 00:00:08,000\n重试字幕\n'),
      );
      await controller.loadCloudSubtitle(controller.availableSubtitles.single);
      expect(controller.cloudSubtitleId, caption.id);
      expect(controller.notice, isNot(contains('失败')));
      final file = File.fromUri(Uri.parse(backend.state.track.subtitle.id));
      expect(await file.readAsString(), contains('重试字幕'));
    },
  );

  test(
    'A Quark share subtitle uses its own fid and token with the authenticated download headers',
    () async {
      final requests = <RecordedRequest>[];
      final adapter = _SubtitleAdapter(transfer.bytes);
      final dio = Dio()..httpClientAdapter = adapter;
      final http = FakeHttp((request) {
        requests.add(request);
        if (request.uri.path.endsWith('/config')) {
          return jsonResponse({'status': 200, 'code': 0, 'data': {}});
        }
        if (request.uri.path.endsWith('/file/download')) {
          expect(request.json['fids'], [caption.id]);
          expect(request.json['fids_token'], ['caption-token']);
          expect(request.json['pwd_id'], 'share-id');
          expect(request.json['stoken'], 'share-token');
          expect(
            request.headers['Cookie'],
            '__pus=caption-owner; __puus=caption-session',
          );
          return jsonResponse({
            'status': 200,
            'code': 0,
            'data': [
              {
                'fid': caption.id,
                'size': caption.size,
                'download_url': 'https://dl.quark.cn/caption',
              },
            ],
          });
        }
        if (request.uri.host == 'dl.quark.cn') {
          expect(
            request.headers['Cookie'],
            '__pus=caption-owner; __puus=caption-session',
          );
          expect(request.headers['Range'], 'bytes=0-0');
          return const HttpResult(206, '1', {
            'content-range': ['bytes 0-0/64'],
            'content-length': ['1'],
          });
        }
        throw StateError('Unexpected subtitle request: ${request.uri.path}');
      });
      await controller.close();
      final shareServices = AppServices(
        store: StateStore.memory({
          'credentials': {
            'Quark': Credential('fixture', {
              'primary': '__pus=caption-owner; __puus=caption-session',
            }, updatedAt: 42).toJson(),
          },
        }),
        dataDirectory: root,
        cacheDirectory: services.cacheDirectory,
        transport: FakeNative(),
        files: FakeFiles(root),
        http: FakeHttp(),
        transferHttp: TransferHttp(client: dio),
        platformFeatures: false,
        controlEnabled: false,
      );
      addTearDown(() async {
        await controller.close();
        await shareServices.close();
        dio.close(force: true);
      });
      // Video resolution is independent; exercise the production share download
      // implementation only for the subtitle selected in the directory list.
      shareServices.cloud.connectors[CloudPlatform.quark] = _ShareSubtitleCloud(
        http,
        shareServices.vault,
      );
      controller = cloudPlayback(
        shareServices,
        const BrowseSession(
          platform: CloudPlatform.quark,
          mode: BrowseMode.share,
          title: 'share',
          rootId: 'folder',
          metadata: {'stoken': 'share-token', 'shareId': 'share-id'},
        ),
        video,
        [
          video,
          CloudFile.fromJson({...caption.toJson(), 'token': 'caption-token'}),
        ],
        backendFactory: (entry, _) =>
            backend = FakePlaybackBackend(entry.id, []),
      );
      await controller.start();
      expect(controller.error, isEmpty);
      await until(() => !controller.subtitleLoading);
      expect(controller.cloudSubtitleId, caption.id, reason: controller.notice);
      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.headers['User-Agent'],
        contains('QuarkPC'),
      );
      expect(
        requests.where((r) => r.uri.path.endsWith('/file/download')),
        hasLength(1),
      );
      final file = File.fromUri(Uri.parse(backend.state.track.subtitle.id));
      expect(await file.readAsString(), contains('中文字幕'));
    },
  );

  test(
    'A second subtitle selection cancels the first and preserves the selected result',
    () async {
      final gate = Completer<void>();
      transfer.barrier = gate.future;
      await controller.start();
      await until(() => transfer.requestedUrl != null);
      transfer.barrier = null;
      await controller.loadCloudSubtitle(controller.availableSubtitles.single);
      final selected = backend.state.track.subtitle.id;
      gate.complete();
      await controller.close();
      expect(backend.state.track.subtitle.id, selected);
      expect(
        await Directory(
          '${services.cacheDirectory.path}/subtitles',
        ).list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'Switching episodes ignores a late subtitle and attaches the new episode subtitle',
    () async {
      await controller.close();
      const nextVideo = CloudFile(
        id: 'video-3',
        name: 'Show.S01E03.mkv',
        parentId: 'folder',
        size: 1000000,
      );
      const nextCaption = CloudFile(
        id: 'caption-3',
        name: 'Show.S01E03.zh-cn.srt',
        parentId: 'folder',
        size: 64,
      );
      controller = cloudPlayback(
        services,
        const BrowseSession(
          platform: CloudPlatform.quark,
          mode: BrowseMode.personal,
          title: 'fixture',
          rootId: 'folder',
        ),
        video,
        const [video, caption, nextVideo, nextCaption],
        backendFactory: (entry, _) =>
            backend = FakePlaybackBackend(entry.id, []),
      );
      final gate = Completer<void>();
      transfer.barrier = gate.future;
      await controller.start();
      await until(() => transfer.requestedUrl != null);
      transfer.barrier = null;
      await controller.load(1);
      await until(() => controller.cloudSubtitleId == nextCaption.id);
      final selected = backend.state.track.subtitle.id;
      gate.complete();
      expect(controller.current.id, nextVideo.id);
      expect(backend.state.track.subtitle.id, selected);
      await controller.close();
      expect(
        await Directory(
          '${services.cacheDirectory.path}/subtitles',
        ).list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'An account removed during a subtitle read cannot attach its late result',
    () async {
      final gate = Completer<void>();
      transfer.barrier = gate.future;
      await controller.start();
      await until(() => transfer.requestedUrl != null);
      await services.vault.removeCredential(CloudPlatform.quark);
      gate.complete();
      await until(() => !controller.subtitleLoading);
      expect(controller.cloudSubtitleId, isNull);
      expect(backend.state.track.subtitle.uri, isFalse);
      expect(controller.error, isEmpty);
      expect(
        Directory('${services.cacheDirectory.path}/subtitles').existsSync(),
        isFalse,
      );
    },
  );
}
