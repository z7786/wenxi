import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
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

class _SubtitleTransfer extends TransferHttp {
  Future<void>? barrier;
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
    return Uint8List.fromList(
      utf8.encode('1\n00:00:00,000 --> 00:00:08,000\n中文字幕\n'),
    );
  }
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
