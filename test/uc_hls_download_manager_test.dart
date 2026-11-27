import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/download_network_policy.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _MediaAdapter implements HttpClientAdapter {
  _MediaAdapter(this.mode);
  final String mode;
  final calls = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    calls.add(options);
    if (options.uri.path.endsWith('.m3u8')) {
      return ResponseBody.fromString(
        '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n'
        '${mode == 'foreign' ? 'https://outside.example.com/part.ts' : 'part.ts'}\n#EXT-X-ENDLIST\n',
        200,
        headers: {
          'content-type': ['application/vnd.apple.mpegurl'],
        },
      );
    }
    if (mode == 'redirect') {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://outside.example.com/part.ts'],
        },
      );
    }
    expect(options.headers['Cookie'], 'fixture=1');
    return ResponseBody.fromBytes(
      [0x47, 1, 2, 3],
      200,
      headers: {
        'content-type': ['video/mp2t'],
        'content-length': ['4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['success', 'foreign', 'redirect', 'remote-source']) {
    test(
      'UC HLS manager keeps host policy through actual transfer: $mode',
      () async {
        final root = await Directory.systemTemp.createTemp('uc-hls-manager-');
        final adapter = _MediaAdapter(mode);
        final http = TransferHttp(
          restrictedClientFactory: (_) =>
              Dio(BaseOptions(validateStatus: (_) => true))
                ..httpClientAdapter = adapter,
        );
        final store = StateStore.memory({
          'settings': {'retries': 0},
        });
        final native = FakeNative();
        final manager = DownloadManager(
          store: store,
          engine: GopeedEngine(
            native,
            store,
            Vault(store),
            Directory('${root.path}/native'),
            Directory('${root.path}/cache'),
          ),
          files: FakeFiles(Directory('${root.path}/saved')),
          cleanups: CleanupOutbox(store, FakeHttp()),
          http: http,
          refreshSource: (_) async => throw StateError('No refresh'),
        );
        addTearDown(() async {
          await manager.close();
          manager.dispose();
          http.dio.close(force: true);
          await root.delete(recursive: true);
        });
        await manager.initialize();
        final id = await manager.enqueue(
          DownloadSpec(
            url: 'https://video-play.drive.uc.cn/media.m3u8',
            fileName: 'video（流畅 480×270）.ts',
            headers: {'Cookie': 'fixture=1'},
            networkPolicy: DownloadNetworkPolicy.fromJson({
              'hosts': ['*.uc.cn'],
              'schemes': ['https'],
              'ports': [443],
            }),
            source: mode == 'remote-source'
                ? {'kind': 'remoteSource'}
                : {
                    'platform': CloudPlatform.uc.key,
                    'ucVideo': {
                      'resolution': 'low',
                      'width': 480,
                      'height': 270,
                      'size': 100,
                      'format': 'hls_ts',
                    },
                  },
          ),
        );
        await until(
          () => !manager.task(id)!.active && manager.activeCount == 0,
        );
        final task = manager.task(id)!;
        if (mode == 'success') {
          expect(task.status, DownloadStatus.completed, reason: task.error);
          expect(await File(task.savedPath!).readAsBytes(), [0x47, 1, 2, 3]);
          expect(task.spec.fileName, endsWith('.ts'));
        } else {
          expect(task.status, DownloadStatus.failed);
          expect(task.savedPath, isNull);
        }
        expect(
          adapter.calls.every((r) => r.uri.host == 'video-play.drive.uc.cn'),
          isTrue,
        );
        expect(native.begins, isEmpty);
      },
    );
  }
}
