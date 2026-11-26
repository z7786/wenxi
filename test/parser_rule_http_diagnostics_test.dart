import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/http.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/diagnostics/app_log.dart';

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String, List<String>) action) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.stream);
  final Stream<List<int>> stream;
  @override
  final headers = _Headers();
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  @override
  final headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  bool aborted = false;
  Object? failure;
  HttpClientResponse response = _Response(Stream.value([123, 125]));
  @override
  void add(List<int> data) {}
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;
  @override
  Future<HttpClientResponse> close() async {
    if (failure case final Object error) throw error;
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  Object? failure;
  Future<HttpClientRequest> Function(String method, Uri url)? onOpenUrl;
  int opens = 0;
  bool closed = false;
  final request = _Request();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    opens++;
    if (onOpenUrl case final handler?) return handler(method, url);
    if (failure case final Object error) throw error;
    return request;
  }

  @override
  void close({bool force = false}) => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secretUrl = 'https://parser.example/api?token=private-query';
  Future<void> request(_Client client, {ParserRuleHttp? transport}) =>
      HttpOverrides.runZoned(() async {
        final http = transport ?? ParserRuleHttp();
        try {
          await http.request(
            'POST',
            secretUrl,
            body: {'password': 'private-body'},
            headers: {'Cookie': 'private-cookie'},
          );
        } finally {
          if (transport == null) http.close(force: true);
        }
      }, createHttpClient: (_) => client);

  test(
    'Network failures record stage and category without secrets or POST replay',
    () async {
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = null;
        log.dispose();
      });
      final cases = <(String, Object, String)>[
        (
          'connect',
          const SocketException('Failed host lookup: private-host'),
          'dns',
        ),
        (
          'connect',
          const SocketException('HTTP connection timed out after 10s'),
          'timeout',
        ),
        ('connect', const HandshakeException('private-tls-details'), 'tls'),
        (
          'connect',
          const SocketException('Connection refused'),
          'connection_refused',
        ),
        (
          'send',
          const SocketException(
            'Connection reset by peer',
            osError: OSError('private-os-details', 10054),
          ),
          'connection_reset',
        ),
        ('send', const HttpException('private-http-details'), 'http'),
        ('receive', TimeoutException('private-timeout-details'), 'timeout'),
      ];
      for (final (phase, error, kind) in cases) {
        final client = _Client();
        if (phase == 'connect') {
          client.failure = error;
        } else if (phase == 'send') {
          client.request.failure = error;
        } else {
          client.request.response = _Response(Stream.error(error));
        }
        final transport = ParserRuleHttp();
        await expectLater(
          request(client, transport: transport),
          throwsA(
            isA<ParserRuleError>().having(
              (e) => e.code,
              'code',
              'RULE_NETWORK',
            ),
          ),
        );
        final event = log.entries().firstWhere(
          (e) => e.event == 'parser.upstream.network_failed',
        );
        final fields = event.data['fields'] as Map;
        expect(fields['host'], 'parser.example');
        expect(fields['phase'], phase);
        expect(fields['errorKind'], kind);
        if (phase == 'receive') expect(fields['httpStatus'], 200);
        if (kind == 'connection_reset') expect(fields['osCode'], 10054);
        expect(client.opens, 1);
        expect(client.closed, true);
        expect(client.request.aborted, phase != 'connect');
        transport.close(force: true);
      }
      final exported = log.exportFiles().values.join('\n');
      for (final secret in [
        'private-query',
        'private-body',
        'private-cookie',
        'private-host',
        'private-tls-details',
        'private-os-details',
        'private-http-details',
        'private-timeout-details',
      ]) {
        expect(exported, isNot(contains(secret)));
      }
    },
  );

  test(
    'Cancellation remains cancellation and creates no false network event',
    () async {
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = null;
        log.dispose();
      });
      final client = _Client();
      final scope = RequestScope()..cancel();
      await expectLater(
        scope.run(() => request(client)),
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '请求已取消'),
        ),
      );
      expect(client.opens, 0);
      expect(
        log.entries().where((e) => e.event == 'parser.upstream.network_failed'),
        isEmpty,
      );
    },
  );

  test(
    'HttpOverrides creates per-request clients and closes them without pinning',
    () async {
      var created = 0;
      final clients = <_Client>[];
      final transport = ParserRuleHttp();
      await HttpOverrides.runZoned(() async {
        final first = await transport.get('https://parser.example/first');
        final second = await transport.get('https://parser.example/second');
        expect(first.status, 200);
        expect(second.status, 200);
      }, createHttpClient: (_) {
        created++;
        final client = _Client();
        clients.add(client);
        return client;
      });
      expect(created, 2);
      expect(clients.every((c) => c.opens == 1 && c.closed), isTrue);
      transport.close(force: true);
    },
  );

  test('Pooled HttpClient is reused across requests until closed', () async {
    var created = 0;
    final client = _Client();
    final transport = ParserRuleHttp(
      clientFactory: () {
        created++;
        return client;
      },
    );
    final first = await transport.get('https://parser.example/first');
    client.request.response = _Response(Stream.value([123, 125]));
    final second = await transport.get('https://parser.example/second');
    expect(first.status, 200);
    expect(second.status, 200);
    expect(created, 1);
    expect(client.opens, 2);
    expect(client.closed, false);
    transport.close(force: true);
    expect(client.closed, true);
  });

  test(
    'Connect timeout aborts late openUrl request without unhandled errors',
    () async {
      final pendingOpen = Completer<HttpClientRequest>();
      final lateRequest = _Request();
      final client = _Client()..onOpenUrl = (_, _) => pendingOpen.future;
      final transport = ParserRuleHttp(
        clientFactory: () => client,
        connectTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(() => transport.close(force: true));
      await expectLater(
        transport.get('https://parser.example/slow-connect'),
        throwsA(
          isA<ParserRuleError>().having((e) => e.code, 'code', 'RULE_NETWORK'),
        ),
      );
      pendingOpen.complete(lateRequest);
      await Future<void>.delayed(Duration.zero);
      expect(lateRequest.aborted, isTrue);
    },
  );

  test(
    'Connect cancellation aborts late openUrl request without unhandled errors',
    () async {
      final pendingOpen = Completer<HttpClientRequest>();
      final lateRequest = _Request();
      final client = _Client()..onOpenUrl = (_, _) => pendingOpen.future;
      final transport = ParserRuleHttp(clientFactory: () => client);
      addTearDown(() => transport.close(force: true));
      final scope = RequestScope();
      final future = scope.run(
        () => transport.get('https://parser.example/cancel-connect'),
      );
      await Future<void>.delayed(Duration.zero);
      scope.cancel();
      await expectLater(
        future,
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '请求已取消'),
        ),
      );
      pendingOpen.complete(lateRequest);
      await Future<void>.delayed(Duration.zero);
      expect(lateRequest.aborted, isTrue);
    },
  );
}
