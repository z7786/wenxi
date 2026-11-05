import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/native_http_probe.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _ProbeTransport extends FakeNative {
  Json result = {};
  final starts = <Json>[], stopped = <String>[];
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'httpProbeStart') {
      starts.add(args);
      return null;
    }
    if (method == 'httpProbeStatus') return result;
    if (method == 'httpProbeStop') {
      stopped.add(args.str('id'));
      return null;
    }
    return super.call(method, args);
  }
}

void main() {
  late Directory root;
  late _ProbeTransport transport;
  late GopeedEngine engine;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-native-probe-');
    transport = _ProbeTransport();
    final store = StateStore.memory();
    engine = GopeedEngine(
      transport,
      store,
      Vault(store),
      Directory('${root.path}/engine'),
      Directory('${root.path}/cache'),
    );
  });
  tearDown(() async {
    await engine.close();
    await root.delete(recursive: true);
  });

  test(
    'Connectivity checks validate actual file bytes and stop their native request',
    () async {
      transport.result = {
        'status': 'done',
        'code': 206,
        'body': base64Encode(utf8.encode('Hello World!\n')),
      };
      await NativeHttpProbe(engine).request(
        'https://example.test/test',
        {},
        readLimit: 4096,
        validate: (b) => utf8.decode(b).trim() == 'Hello World!',
      );
      expect(transport.starts.single.integer('readLimit'), 4096);
      expect(transport.stopped, [transport.starts.single.str('id')]);
    },
  );

  test('HTTP 200 error pages cannot pass a file connectivity check', () async {
    transport.result = {
      'status': 'done',
      'code': 200,
      'body': base64Encode(utf8.encode('<html>mirror unavailable</html>')),
    };
    await expectLater(
      NativeHttpProbe(engine).request(
        'https://example.test/test',
        {},
        readLimit: 4096,
        validate: (b) => utf8.decode(b).trim() == 'Hello World!',
      ),
      throwsA(isA<AppException>()),
    );
    expect(transport.stopped.length, 1);
  });

  test(
    'Connection failures and incorrect ranges keep their distinct causes',
    () async {
      transport.result = {'status': 'error', 'errorKind': 'content'};
      await expectLater(
        NativeHttpProbe(engine).probe(
          const DownloadSpec(
            url: 'https://example.test/file',
            fileName: 'file',
          ),
          sampleBytes: 1024,
        ),
        throwsA(isA<DownloadProbeContentException>()),
      );
      transport.result = {
        'status': 'error',
        'errorKind': 'network',
        'retryable': true,
      };
      await expectLater(
        NativeHttpProbe(engine).request('https://example.test/file', {}),
        throwsA(isA<DownloadNetworkException>()),
      );
      expect(transport.stopped.length, 2);
    },
  );

  test(
    'Cancelling a pending test closes its native probe without creating a download',
    () async {
      transport.result = {'status': 'running'};
      final scope = RequestScope();
      final pending = scope.run(
        () => NativeHttpProbe(engine).request('https://example.test/file', {}),
      );
      final check = expectLater(pending, throwsA(anything));
      await until(() => transport.starts.isNotEmpty);
      scope.cancel();
      await check;
      expect(transport.stopped.length, 1);
      expect(transport.begins, isEmpty);
    },
  );

  test(
    'A range sample uses the real native client and preserves the full file size',
    () async {
      final bytes = Uint8List.fromList(List.generate(16384, (i) => i % 251));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        try {
          expect(request.headers.value('range'), 'bytes=0-1023');
          expect(request.headers.value('accept-encoding'), 'identity');
          response.statusCode = 206;
          response.headers.set('content-range', 'bytes 0-1023/${bytes.length}');
          response.headers.set('etag', '"file"');
          response.contentLength = 1024;
          response.add(bytes.take(1024).toList());
          await response.close();
        } on IOException {
          // A completed sample closes its response immediately.
        }
      });
      final store = StateStore.memory();
      final native = GopeedEngine(
        DesktopGopeedTransport(executable: gopeedTestExecutable()),
        store,
        Vault(store),
        Directory('${root.path}/live-engine'),
        Directory('${root.path}/live-cache'),
      );
      try {
        final result = await NativeHttpProbe(native).probe(
          DownloadSpec(
            url: 'http://127.0.0.1:${server.port}/file',
            fileName: 'file',
          ),
          sampleBytes: 1024,
        );
        expect(result.identity.total, bytes.length);
        expect(result.rangeSupported, isTrue);
        expect(result.host, '127.0.0.1');
      } finally {
        await native.close();
        await server.close(force: true);
      }
    },
  );
}
