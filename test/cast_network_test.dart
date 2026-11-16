import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/playback/cast/cast_network.dart';
import 'package:asterlink/playback/cast/cast_session.dart';
import 'package:asterlink/playback/cast/dlna.dart';
import 'package:asterlink/playback/external_stream.dart';

import 'cast_support.dart';

CastDevice deviceAt(String host) => CastDevice(
  id: 'network-test-tv',
  name: 'Test TV',
  description: Uri(scheme: 'http', host: host, path: '/device.xml'),
  transport: CastService(
    'urn:schemas-upnp-org:service:AVTransport:1',
    Uri(scheme: 'http', host: host, path: '/control'),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
  });

  test(
    'Android content URI above 5 GB streams requested ranges without copying the file',
    () async {
      const channel = MethodChannel('cast-content-file-fixture');
      const location = 'content://media/external/downloads/1000011658';
      const size = 5 * 1024 * 1024 * 1024 + 100 * 1024 * 1024;
      final offsets = <int>[];
      var closes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'lanScan':
                expect(call.arguments['path'], location);
                return {
                  'name': 'downloaded.mkv',
                  'files': [
                    {
                      'location': location,
                      'relative': '',
                      'size': size,
                      'modifiedAt': 0,
                    },
                  ],
                };
              case 'lanOpenRead':
                offsets.add(call.arguments['offset'] as int);
                return 'cast-reader';
              case 'lanStat':
                return {'size': size, 'modifiedAt': 0};
              case 'lanRead':
                final length = call.arguments['length'] as int;
                expect(length, 1024);
                return Uint8List.fromList(List.filled(length, 7));
              case 'lanCloseRead':
                closes++;
                return null;
            }
            throw StateError(call.method);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final tv = TestTv(host: '127.0.0.2');
      await tv.start();
      addTearDown(tv.close);
      final session = CastSession(
        tv.device,
        const DownloadSpec(
          url: location,
          fileName: 'downloaded.mkv',
          expectedSize: size,
        ),
        platform: TestCastPlatform(),
        pollInterval: const Duration(days: 1),
        streamFactory: (source, address) => ExternalPlaybackStream.lan(
          source,
          lanAddress: address,
          files: LanFiles(android: true, channel: channel),
        ),
      );
      addTearDown(session.close);
      await session.start(
        title: 'Downloaded MKV',
        position: Duration.zero,
        duration: tv.duration,
      );
      expect(tv.metadata, contains('size="$size"'));
      expect(offsets, isEmpty);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final head = await (await client.headUrl(Uri.parse(tv.media))).close();
      expect(head.contentLength, size);
      await head.drain<void>();
      expect(offsets, isEmpty);
      final request = await client.getUrl(Uri.parse(tv.media));
      request.headers.set('Range', 'bytes=-1024');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(
        response.headers.value('content-range'),
        'bytes ${size - 1024}-${size - 1}/$size',
      );
      expect(
        await response.expand((chunk) => chunk).toList(),
        List.filled(1024, 7),
      );
      expect(offsets, [size - 1024]);
      await castEventually(() => closes == 1);
      expect(closes, 1);
    },
  );
  for (final mode in [
    TestTvResponse.disconnectAfter,
    TestTvResponse.truncated,
  ]) {
    test(
      '5 GB Android MKV relay survives a lost Play response while its file read is pending: $mode',
      () async {
        const channel = MethodChannel('cast-pending-content-file-fixture');
        const location = 'content://media/external/downloads/pending-mkv';
        const size = 5477092182;
        final offsets = <int>[];
        final readRelease = Completer<void>(), playResponse = Completer<void>();
        var reads = 0, closes = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              switch (call.method) {
                case 'lanScan':
                  return {
                    'name': 'downloaded.mkv',
                    'files': [
                      {
                        'location': location,
                        'relative': '',
                        'size': size,
                        'modifiedAt': 0,
                      },
                    ],
                  };
                case 'lanStat':
                  return {'size': size, 'modifiedAt': 0};
                case 'lanOpenRead':
                  offsets.add(call.arguments['offset'] as int);
                  return 'pending-reader';
                case 'lanRead':
                  reads++;
                  await readRelease.future;
                  return Uint8List.fromList(
                    List.filled(call.arguments['length'] as int, 7),
                  );
                case 'lanCloseRead':
                  closes++;
                  return null;
              }
              throw StateError(call.method);
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final log = DiagnosticLog.open(null);
        final previous = DiagnosticLog.active;
        DiagnosticLog.active = log;
        addTearDown(() {
          DiagnosticLog.active = previous;
          log.close();
        });
        final tv = TestTv(host: '127.0.0.2');
        await tv.start();
        addTearDown(tv.close);
        tv.barriers['Play'] = playResponse.future;
        tv.responseSequences['Play'] = [mode];
        final session = CastSession(
          tv.device,
          const DownloadSpec(
            url: location,
            fileName: 'downloaded.mkv',
            expectedSize: size,
          ),
          platform: TestCastPlatform(),
          pollInterval: const Duration(days: 1),
          streamFactory: (source, address) => ExternalPlaybackStream.lan(
            source,
            lanAddress: address,
            files: LanFiles(android: true, channel: channel),
          ),
        );
        addTearDown(session.close);
        final receiver = HttpClient()
          ..connectionFactory = ((uri, _, _) =>
              Socket.startConnect(uri.host, uri.port, sourceAddress: tv.host));
        addTearDown(() => receiver.close(force: true));
        final starting = session.start(
          title: 'Downloaded MKV',
          position: const Duration(seconds: 142),
          duration: tv.duration,
        );
        unawaited(
          starting.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
        try {
          await castEventually(() => tv.events.contains('Play'));
          final media = tv.media;
          final request = await receiver.getUrl(Uri.parse(media));
          request.headers.set('Range', 'bytes=-2048');
          final fetching = request.close();
          unawaited(
            fetching.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
          );
          await castEventually(() => reads == 1);
          expect(closes, 0);
          playResponse.complete();
          await starting;
          expect(session.connected, isTrue);
          expect(tv.media, media);
          expect(tv.transport, 'PLAYING');
          expect(tv.position, const Duration(seconds: 142));
          expect(tv.events.where((event) => event == 'Play'), hasLength(1));
          expect(tv.events, isNot(contains('Stop')));
          expect(closes, 0);
          expect(
            log.entries().where(
              (entry) => entry.event == 'cast.command_confirmed',
            ),
            hasLength(1),
          );
          readRelease.complete();
          final response = await fetching;
          expect(response.statusCode, 206);
          expect(response.contentLength, 2048);
          expect(
            response.headers.value('content-range'),
            'bytes ${size - 2048}-${size - 1}/$size',
          );
          expect(
            await response.expand((chunk) => chunk).toList(),
            List.filled(2048, 7),
          );
          await castEventually(() => closes == 1);
          await castEventually(
            () => log.entries().any(
              (entry) => entry.event == 'cast.relay_request',
            ),
          );
          final transfer = log
              .entries()
              .singleWhere((entry) => entry.event == 'cast.relay_request')
              .data['fields'];
          expect(transfer['status'], 206);
          expect(transfer['cancelled'], isFalse);
          expect(transfer['bytes'], 2048);
          expect(offsets, [size - 2048]);
        } finally {
          if (!playResponse.isCompleted) playResponse.complete();
          if (!readRelease.isCompleted) readRelease.complete();
          await starting;
        }
      },
    );
  }
  test(
    'distinct receiver IP does not become the relay address, local MKV is readable',
    () async {
      final log = DiagnosticLog.open(null);
      final previous = DiagnosticLog.active;
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = previous;
        log.close();
      });
      final tv = TestTv(host: '127.0.0.2');
      await tv.start();
      addTearDown(tv.close);
      final directory = await Directory.systemTemp.createTemp('cast-route-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/local.mkv');
      final bytes = List.generate(2048, (i) => i % 256);
      await file.writeAsBytes(bytes);
      final session = CastSession(
        tv.device,
        DownloadSpec(url: file.uri.toString(), fileName: 'local.mkv'),
        platform: TestCastPlatform(),
        pollInterval: const Duration(days: 1),
      );
      addTearDown(session.close);
      await session.start(
        title: 'Local MKV',
        position: const Duration(seconds: 42),
        duration: tv.duration,
      );
      expect(session.connected, isTrue);
      expect(Uri.parse(tv.media).host, '127.0.0.1');
      expect(Uri.parse(tv.media).host, isNot(tv.host));
      expect(tv.metadata, contains('video/x-matroska'));
      expect(tv.position, const Duration(seconds: 42));
      final receiver = HttpClient()
        ..connectionFactory = ((uri, _, _) =>
            Socket.startConnect(uri.host, uri.port, sourceAddress: tv.host));
      addTearDown(() => receiver.close(force: true));
      final request = await receiver.getUrl(Uri.parse(tv.media));
      request.headers.set('Range', 'bytes=1024-1535');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(
        await response.expand((chunk) => chunk).toList(),
        bytes.sublist(1024, 1536),
      );
      final records = log.entries()
        ..sort(
          (a, b) => (a.data['seq'] as int).compareTo(b.data['seq'] as int),
        );
      final events = records.map((entry) => entry.event).toList();
      expect(
        events,
        containsAllInOrder([
          'cast.route_selected',
          'cast.relay_started',
          'cast.source_prepared',
        ]),
      );
      final prepared = log.entries().singleWhere(
        (entry) => entry.event == 'cast.source_prepared',
      );
      expect(prepared.data['fields']['file_bytes'], bytes.length);
      expect(prepared.data['fields']['parallel'], isFalse);
      await session.close();
      expect(tv.transport, 'STOPPED');
    },
  );

  test(
    'probe uses only matching local candidates and tries the next interface',
    () async {
      final local = InternetAddress('192.168.5.7');
      final attempted = <InternetAddress>[];
      final route = CastNetworkRoute(
        addresses: (_) async => [
          InternetAddress.loopbackIPv4,
          InternetAddress('fd00::7'),
          InternetAddress('8.8.8.8'),
          InternetAddress('10.0.0.7'),
          local,
        ],
        probe: (uri, address, timeout) async {
          expect(uri.host, '192.168.5.6');
          expect(timeout, lessThanOrEqualTo(const Duration(seconds: 2)));
          attempted.add(address);
          if (address != local) throw const SocketException('No route');
        },
      );
      expect(await route.localAddress(deviceAt('192.168.5.6')), local);
      expect(attempted.map((address) => address.address), [
        '10.0.0.7',
        '192.168.5.7',
      ]);
    },
  );

  test(
    'route exhaustion reports the last system error without selecting the TV IP',
    () async {
      final route = CastNetworkRoute(
        addresses: (_) async => [InternetAddress('192.168.5.7')],
        probe: (_, _, _) async => throw const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 111),
        ),
      );
      await expectLater(
        route.localAddress(deviceAt('192.168.5.6')),
        throwsA(
          isA<CastNetworkException>()
              .having((error) => error.stage, 'stage', 'route')
              .having(
                (error) => castFailureFields(error)['errno'],
                'errno',
                111,
              ),
        ),
      );
    },
  );

  test(
    'missing local network prevents both probing and relay creation',
    () async {
      var probes = 0;
      final route = CastNetworkRoute(
        addresses: (_) async => [],
        probe: (_, _, _) async => probes++,
      );
      await expectLater(
        route.localAddress(deviceAt('192.168.5.6')),
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            contains('局域网地址'),
          ),
        ),
      );
      expect(probes, 0);
    },
  );

  test('IPv6 and CGNAT routes retain the matched address family', () async {
    for (final (peer, local) in [
      ('fd00::6', 'fd00::7'),
      ('100.64.1.6', '100.64.1.7'),
    ]) {
      final expected = InternetAddress(local);
      final route = CastNetworkRoute(
        addresses: (_) async => [InternetAddress.loopbackIPv4, expected],
        probe: (_, address, _) async => expect(address, expected),
      );
      expect(await route.localAddress(deviceAt(peer)), expected);
    }
  });

  test('raw socket errors stay redacted in stage diagnostics', () {
    final error = CastNetworkException(
      'bind',
      const SocketException(
        'Failed to create server socket',
        osError: OSError('Cannot assign requested address 192.168.5.6', 99),
      ),
    );
    final log = DiagnosticLog.open(null);
    addTearDown(log.close);
    log.record('cast.connect_failed', fields: castFailureFields(error));
    final fields = log
        .entries()
        .singleWhere((entry) => entry.event == 'cast.connect_failed')
        .data['fields'];
    expect(fields['stage'], 'bind');
    expect(fields['errno'], 99);
    expect(fields['error_type'], 'SocketException');
    expect(fields['os_error'], contains('Cannot assign requested address'));
    expect(jsonEncode(fields), isNot(contains('192.168.5.6')));
    expect(error.message, contains('本机投屏服务'));
  });

  test(
    'a local bind failure stays distinct from route and TV control failures',
    () async {
      final stream = ExternalPlaybackStream.lan(
        const DownloadSpec(
          url: 'https://example.invalid/video.mp4',
          fileName: 'video.mp4',
        ),
        lanAddress: InternetAddress('192.0.2.254'),
      );
      addTearDown(stream.close);
      await expectLater(
        stream.start(),
        throwsA(
          isA<CastNetworkException>()
              .having((error) => error.stage, 'stage', 'bind')
              .having((error) => error.cause, 'cause', isA<SocketException>()),
        ),
      );
    },
  );
}
