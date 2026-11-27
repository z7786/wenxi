import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/system_proxy_http_adapter.dart';
import 'package:asterlink/platform/windows_system_proxy.dart';

Future<HttpServer> endpoint(String name, List<HttpRequest> requests) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    requests.add(request);
    await request.drain<void>();
    request.response.write(name);
    await request.response.close();
  });
  return server;
}

DioJsonHttp client(
  Future<WindowsProxyRoute> Function(Uri) resolve, {
  bool allRequests = true,
  Duration timeout = const Duration(seconds: 3),
}) {
  final dio = Dio(
    BaseOptions(connectTimeout: timeout, receiveTimeout: timeout),
  );
  dio.httpClientAdapter = SystemProxyHttpClientAdapter(
    resolve: resolve,
    shouldProxy: allRequests
        ? (_) => true
        : SystemProxyHttpClientAdapter.pikpakRequest,
  );
  addTearDown(() => dio.close(force: true));
  return DioJsonHttp(client: dio);
}

void main() {
  test(
    'A routed subtitle client preserves its request User-Agent across redirects',
    () async {
      final requests = <HttpRequest>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(request);
        if (request.uri.path == '/start') {
          request.response.statusCode = 302;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/subtitle.srt',
          );
        } else {
          request.response.write('subtitle');
        }
        await request.response.close();
      });
      final dio = Dio()
        ..httpClientAdapter = SystemProxyHttpClientAdapter(
          resolve: (_) async => const WindowsProxyRoute('DIRECT', 'direct'),
          shouldProxy: (_) => true,
          diagnosticPlatform: '在线字幕',
          createHttpClient: () => HttpClient()..userAgent = null,
        );
      addTearDown(() => dio.close(force: true));
      final http = DioJsonHttp(client: dio);
      expect(
        (await http.get('http://127.0.0.1:${server.port}/start', {
          HttpHeaders.userAgentHeader: 'fixture-subtitle-agent',
        })).body,
        'subtitle',
      );
      expect(requests, hasLength(2));
      expect(
        requests.map((r) => r.headers.value(HttpHeaders.userAgentHeader)),
        ['fixture-subtitle-agent', 'fixture-subtitle-agent'],
      );
    },
  );

  test(
    'Existing direct connections cannot bypass a newly enabled or changed proxy',
    () async {
      final directRequests = <HttpRequest>[],
          firstRequests = <HttpRequest>[],
          secondRequests = <HttpRequest>[];
      final destination = await endpoint('direct', directRequests);
      final first = await endpoint('first-proxy', firstRequests);
      final second = await endpoint('second-proxy', secondRequests);
      var config = const WindowsProxyConfig();
      final proxy = WindowsSystemProxy(readConfig: () async => config);
      final http = client(proxy.resolve);
      final url = 'http://127.0.0.1:${destination.port}/v1/user/me';
      expect((await http.get(url)).body, 'direct');
      config = WindowsProxyConfig(proxy: '127.0.0.1:${first.port}');
      expect((await http.get(url)).body, 'first-proxy');
      config = WindowsProxyConfig(proxy: '127.0.0.1:${second.port}');
      expect((await http.get(url)).body, 'second-proxy');
      config = const WindowsProxyConfig();
      expect((await http.get(url)).body, 'direct');
      expect(directRequests.length, 2);
      expect(firstRequests.single.uri.toString(), url);
      expect(secondRequests.single.uri.toString(), url);
    },
  );

  test(
    'A configured broken proxy fails without sending anything directly',
    () async {
      final requests = <HttpRequest>[];
      final destination = await endpoint('must-not-reach', requests);
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();
      final http = client(
        (_) async => WindowsProxyRoute('PROXY 127.0.0.1:$port', 'manual'),
      );
      await expectLater(
        http.get('http://127.0.0.1:${destination.port}/'),
        throwsA(
          isA<HttpRequestFailure>().having(
            (error) => error.message,
            'proxy guidance',
            contains('Windows 系统代理'),
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'PikPak HTTPS requests use CONNECT without exposing tokens to the proxy',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final requests = <HttpRequest>[];
      proxy.listen((request) async {
        requests.add(request);
        request.response.statusCode = 407;
        await request.response.close();
      });
      final http = client(
        (_) async =>
            WindowsProxyRoute('PROXY 127.0.0.1:${proxy.port}', 'manual'),
        allRequests: false,
      );
      await expectLater(
        http.get('https://user.mypikpak.com/v1/user/me', {
          'Authorization': 'Bearer fixture-private-token-123456',
        }),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(requests.single.method, 'CONNECT');
      expect(requests.single.uri.toString(), contains('user.mypikpak.com:443'));
      expect(requests.single.headers.value('authorization'), isNull);
    },
  );

  test(
    'Cancellation during proxy resolution never sends a delayed login request',
    () async {
      final requests = <HttpRequest>[];
      final proxy = await endpoint('must-not-send', requests);
      final entered = Completer<void>(),
          resolving = Completer<WindowsProxyRoute>();
      final http = client((_) {
        entered.complete();
        return resolving.future;
      });
      final scope = RequestScope();
      final login = scope.run(
        () => http.request(
          'POST',
          'http://unresolved.invalid/login',
          body: 'fixture',
        ),
      );
      final cancelled = expectLater(
        login,
        throwsA(
          isA<HttpRequestFailure>().having(
            (error) => error.kind,
            'kind',
            'cancel',
          ),
        ),
      );
      await entered.future;
      scope.cancel();
      await cancelled;
      resolving.complete(
        WindowsProxyRoute('PROXY 127.0.0.1:${proxy.port}', 'manual'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, isEmpty);
    },
  );

  test(
    'Proxy lookup obeys the connection timeout and cannot send after timing out',
    () async {
      final requests = <HttpRequest>[];
      final proxy = await endpoint('must-not-send', requests);
      final resolving = Completer<WindowsProxyRoute>();
      final http = client(
        (_) => resolving.future,
        timeout: const Duration(milliseconds: 80),
      );
      await expectLater(
        http.get('http://unresolved.invalid/'),
        throwsA(
          isA<HttpRequestFailure>().having(
            (error) => error.kind,
            'kind',
            'connectionTimeout',
          ),
        ),
      );
      resolving.complete(
        WindowsProxyRoute('PROXY 127.0.0.1:${proxy.port}', 'manual'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, isEmpty);
    },
  );

  test('Closing during proxy resolution prevents a later request', () async {
    final requests = <HttpRequest>[];
    final proxy = await endpoint('must-not-send', requests);
    final entered = Completer<void>(),
        resolving = Completer<WindowsProxyRoute>();
    final http = client((_) {
      entered.complete();
      return resolving.future;
    });
    final pending = http.get('http://unresolved.invalid/');
    final rejected = expectLater(pending, throwsA(isA<HttpRequestFailure>()));
    await entered.future;
    http.dio.close(force: true);
    resolving.complete(
      WindowsProxyRoute('PROXY 127.0.0.1:${proxy.port}', 'manual'),
    );
    await rejected;
    expect(requests, isEmpty);
  });

  test(
    'Automatic proxy routing is limited to the two PikPak API origins',
    () async {
      for (final host in ['user.mypikpak.com', 'api-drive.mypikpak.com']) {
        expect(
          SystemProxyHttpClientAdapter.pikpakRequest(
            Uri.parse('https://$host/'),
          ),
          isTrue,
        );
      }
      for (final url in [
        'https://pan.baidu.com/',
        'https://user.mypikpak.com.invalid/',
        'https://unrelated.mypikpak.com/',
        'http://user.mypikpak.com/',
      ]) {
        expect(
          SystemProxyHttpClientAdapter.pikpakRequest(Uri.parse(url)),
          isFalse,
        );
      }
      final requests = <HttpRequest>[];
      final server = await endpoint('unaffected', requests);
      final http = client(
        (_) async => fail('unrelated request must not resolve proxy'),
        allRequests: false,
      );
      expect(
        (await http.get('http://127.0.0.1:${server.port}/')).body,
        'unaffected',
      );
      final defaultHttp = DioJsonHttp();
      addTearDown(() => defaultHttp.dio.close(force: true));
      expect(
        defaultHttp.dio.httpClientAdapter is SystemProxyHttpClientAdapter,
        Platform.isWindows,
      );
    },
  );
}
