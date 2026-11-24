import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _LocalIo extends HttpOverrides {}

class _Files extends LanFiles {
  _Files() : super(android: false);
  final calls = <bool>[];
  @override
  Future<void> network(bool enabled) async => calls.add(enabled);
}

void main() {
  late DiagnosticLog log;
  DiagnosticLog? previous;
  setUp(() {
    previous = DiagnosticLog.active;
    log = DiagnosticLog.open(null);
    DiagnosticLog.active = log;
  });
  tearDown(() {
    log.dispose();
    DiagnosticLog.active = previous;
  });

  LanService device({
    required Future<List<String>> Function() addresses,
    Future<void> Function()? foreground,
    int port = 0,
    _Files? files,
  }) {
    final store = StateStore.memory();
    final service = LanService(
      store: store,
      files: files ?? _Files(),
      discoveryEnabled: false,
      requestedPort: port,
      bindAddress: InternetAddress.loopbackIPv4,
      addresses: addresses,
      foreground: foreground,
    );
    addTearDown(() async {
      await service.close();
      store.dispose();
    });
    return service;
  }

  Json failure() => asJson(
    log
        .entries()
        .singleWhere((entry) => entry.event == 'lan.start_failed')
        .data['fields'],
  );

  test(
    'Unavailable addresses report the failing stage and can be retried',
    () async {
      var found = ['8.8.8.8'];
      final service = device(addresses: () async => found);
      await expectLater(
        service.start(),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'guidance',
            contains('未检测到可用的局域网 IPv4 地址'),
          ),
        ),
      );
      expect(service.running, isFalse);
      expect(service.port, 0);
      expect(service.connectionCode, isEmpty);
      expect(service.addresses, isEmpty);
      expect(failure()['stage'], 'addresses');
      expect(failure()['detectedAddresses'], 1);
      found = ['100.64.12.5'];
      await service.start();
      expect(service.running, isTrue);
      expect(service.base().host, '100.64.12.5');
      expect(service.connectionCode, hasLength(6));
    },
  );

  test(
    'Interface enumeration errors keep errno and do not masquerade as disconnected',
    () async {
      var broken = true;
      final service = device(
        addresses: () async {
          if (broken) {
            throw const SocketException(
              'Failed to list interfaces',
              osError: OSError('fixture', 10022),
            );
          }
          return ['127.0.0.1'];
        },
      );
      await expectLater(
        service.start(),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'guidance',
            contains('无法读取本机网络地址'),
          ),
        ),
      );
      expect(failure()['stage'], 'addresses');
      expect(failure()['errno'], 10022);
      expect(service.port, 0);
      broken = false;
      await service.start();
      expect(service.running, isTrue);
    },
  );

  test(
    'A failed foreground start closes the listener and permits another start',
    () async {
      var broken = true;
      final files = _Files();
      final service = device(
        addresses: () async => ['127.0.0.1'],
        files: files,
        foreground: () async {
          if (broken) throw const AppException('fixture foreground failure');
        },
      );
      await expectLater(service.start(), throwsA(isA<AppException>()));
      expect(service.running, isFalse);
      expect(service.port, 0);
      expect(service.addresses, isEmpty);
      expect(files.calls, [true, false]);
      expect(failure()['stage'], 'foreground');
      broken = false;
      await service.start();
      expect(service.running, isTrue);
      expect(files.calls, [true, false, true]);
    },
  );

  test(
    'An occupied port falls back to a real listener and records the bind error',
    () async {
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => occupied.close());
      final service = device(
        addresses: () async => ['127.0.0.1'],
        port: occupied.port,
      );
      await service.start();
      expect(service.running, isTrue);
      expect(service.port, isNot(occupied.port));
      final entry = log.entries().singleWhere(
        (e) => e.event == 'lan.http_port_fallback',
      );
      expect(asJson(entry.data['fields'])['requestedPort'], occupied.port);
      expect(asJson(entry.data['fields'])['errno'], isA<int>());
    },
  );

  test(
    'Cancellation during address detection cannot leave interconnection running',
    () async {
      final entered = Completer<void>(), gate = Completer<List<String>>();
      var calls = 0;
      final service = device(
        addresses: () {
          if (calls++ > 0) return Future.value(['127.0.0.1']);
          entered.complete();
          return gate.future;
        },
      );
      final scope = RequestScope();
      final rejected = expectLater(
        scope.run(service.start),
        throwsA(isA<AppException>()),
      );
      await entered.future;
      scope.cancel();
      gate.complete(['127.0.0.1']);
      await rejected;
      expect(service.running, isFalse);
      expect(service.port, 0);
      expect(
        log.entries().where((e) => e.event == 'lan.start_failed'),
        isEmpty,
      );
      await service.start();
      expect(service.running, isTrue);
    },
  );

  test(
    'Shared IPv4 Host is accepted while pairing and public-host restrictions still apply',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final service = device(addresses: () async => ['100.64.12.5']);
        await service.start();
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        addTearDown(() => client.close(force: true));
        Future<int> fetch(String host, String path) async {
          final request = await client.getUrl(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: service.port,
              path: path,
            ),
          );
          request.headers.set(HttpHeaders.hostHeader, '$host:${service.port}');
          final response = await request.close();
          await response.transform(utf8.decoder).join();
          return response.statusCode;
        }

        expect(await fetch('100.64.12.5', '/v1/info'), 200);
        expect(await fetch('100.64.12.5', '/v1/shares'), 401);
        expect(await fetch('8.8.8.8', '/v1/info'), 400);
      }, _LocalIo());
    },
  );
}
