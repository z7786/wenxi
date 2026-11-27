import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/playback/online_subtitles.dart';
import 'package:asterlink/playback/subtitle_files.dart';
import 'package:asterlink/platform/windows_system_proxy.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    unawaited(cancelFuture?.then((_) => cancelled = true));
    return await respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _LocalIo extends HttpOverrides {}

class _EnvironmentIo extends HttpOverrides {
  _EnvironmentIo(this.values);
  final Map<String, String> values;
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      super.findProxyFromEnvironment(url, values);
}

Json _caption({
  String name = 'Show.S01E02.srt',
  String url = 'https://subtitle.example.com/show.srt',
  String format = 'srt',
}) => {
  'name': name,
  'url': url,
  'ext': format,
  'simple_name': '简体[${format.toUpperCase()}]$name',
  'languages': [r'简体\u0026英语'],
  'duration': 2858420,
};

ResponseBody _response(List<Json> data) => ResponseBody.fromString(
  jsonEncode({'code': 0, 'data': data, 'result': 'ok'}),
  200,
  headers: {
    'content-type': ['application/json; charset=utf-8'],
  },
);

void main() {
  XunleiOnlineSubtitleService create(
    _Adapter adapter, {
    Future<void> Function(Duration)? wait,
  }) {
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    final service = XunleiOnlineSubtitleService(
      http: TransferHttp(client: dio),
      wait: wait ?? RequestScope.wait,
    );
    addTearDown(() {
      service.close();
      dio.close(force: true);
    });
    return service;
  }

  Future<Directory> subtitleDirectory() async {
    final directory = await Directory.systemTemp.createTemp(
      'asterlink-online-subtitles-',
    );
    addTearDown(() => directory.delete(recursive: true));
    return directory;
  }

  for (final kind in [
    'socket',
    'receive timeout',
    'HTTP 503',
    'truncated body',
  ]) {
    test(
      'A transient $kind search failure retries once with the same encoded query',
      () async {
        var attempts = 0;
        final waits = <Duration>[];
        final adapter = _Adapter((options) {
          if (++attempts > 1) return _response([_caption()]);
          return switch (kind) {
            'HTTP 503' => ResponseBody.fromString('temporary', 503),
            'truncated body' => ResponseBody(
              Stream.error(
                const HttpException('Connection closed while receiving data'),
              ),
              200,
            ),
            _ =>
              throw kind == 'socket'
                  ? DioException.connectionError(
                      requestOptions: options,
                      reason: 'fixture reset',
                      error: const SocketException(
                        'Connection reset',
                        osError: OSError('reset', 10054),
                      ),
                    )
                  : DioException.receiveTimeout(
                      requestOptions: options,
                      timeout: const Duration(seconds: 45),
                    ),
          };
        });
        final service = create(
          adapter,
          wait: (delay) async => waits.add(delay),
        );
        expect(
          await service.search('Name & S01E03.mkv', RequestScope()),
          hasLength(1),
        );
        expect(adapter.requests, hasLength(2));
        expect(adapter.requests.map((r) => r.uri.queryParameters['name']), [
          'Name & S01E03.mkv',
          'Name & S01E03.mkv',
        ]);
        expect(waits, [const Duration(seconds: 2)]);
      },
    );
  }

  test(
    'Repeated connection failures keep the native cause and stop after one retry',
    () async {
      const cause = SocketException(
        'Failed host lookup: subtitle.example',
        osError: OSError('fixture DNS', 11001),
      );
      final adapter = _Adapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'fixture DNS',
          error: cause,
        ),
      );
      final service = create(adapter, wait: (_) async {});
      await expectLater(
        service.search('Show', RequestScope()),
        throwsA(
          isA<DownloadNetworkException>()
              .having((e) => e.cause, 'native cause', same(cause))
              .having((e) => e.kind, 'kind', 'connectionError'),
        ),
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  for (final kind in [
    'certificate',
    'proxy config',
    'HTTP 403',
    'HTTP 429 long delay',
    'invalid JSON',
  ]) {
    test(
      'Nonrecoverable $kind failures do not trigger automatic retries',
      () async {
        final adapter = _Adapter(
          (options) => switch (kind) {
            'certificate' => throw DioException(
              requestOptions: options,
              error: const HandshakeException(
                'Handshake error',
                OSError('CERTIFICATE_VERIFY_FAILED'),
              ),
            ),
            'proxy config' => throw DioException.connectionError(
              requestOptions: options,
              reason: 'fixture config',
              error: const WindowsProxyException('unsupported'),
            ),
            'HTTP 403' => ResponseBody.fromString('forbidden', 403),
            'HTTP 429 long delay' => ResponseBody.fromString(
              'limited',
              429,
              headers: {
                'retry-after': ['60'],
              },
            ),
            _ => ResponseBody.fromString('invalid response', 200),
          },
        );
        final service = create(
          adapter,
          wait: (_) async => fail('must not retry'),
        );
        await expectLater(
          service.search('Show', RequestScope()),
          throwsA(isA<AppException>()),
        );
        expect(adapter.requests, hasLength(1));
      },
    );
  }

  test('A short Retry-After is observed before one search retry', () async {
    var attempts = 0;
    final waits = <Duration>[];
    final adapter = _Adapter(
      (_) => ++attempts == 1
          ? ResponseBody.fromString(
              'busy',
              429,
              headers: {
                'retry-after': ['4'],
              },
            )
          : _response([]),
    );
    final service = create(adapter, wait: (delay) async => waits.add(delay));
    expect(await service.search('Show', RequestScope()), isEmpty);
    expect(waits, [const Duration(seconds: 4)]);
    expect(adapter.requests, hasLength(2));
  });

  test(
    'Cancelling a retry wait cannot send another request; the next query still works',
    () async {
      final entered = Completer<void>();
      var failRequest = true;
      final adapter = _Adapter((options) {
        if (!failRequest) return _response([]);
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'fixture reset',
        );
      });
      final service = create(
        adapter,
        wait: (delay) {
          entered.complete();
          return RequestScope.wait(delay);
        },
      );
      final scope = RequestScope();
      final rejected = expectLater(
        service.search('Show', scope),
        throwsA(isA<AppException>()),
      );
      await entered.future;
      scope.cancel();
      await rejected;
      expect(adapter.requests, hasLength(1));
      failRequest = false;
      expect(await service.search('Other show', RequestScope()), isEmpty);
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'Interrupted search body diagnostics retain the native socket errno',
    () async {
      const cause = SocketException(
        'fixture reset',
        osError: OSError('reset', 10054),
      );
      final adapter = _Adapter(
        (options) => ResponseBody(
          Stream.error(
            DioException.connectionError(
              requestOptions: options,
              reason: 'fixture',
              error: cause,
            ),
          ),
          200,
        ),
      );
      final service = create(adapter, wait: (_) async {});
      await expectLater(
        service.search('Show', RequestScope()),
        throwsA(
          isA<DownloadNetworkException>().having(
            (e) => e.cause,
            'native cause',
            same(cause),
          ),
        ),
      );
    },
  );

  test(
    'Retry diagnostics preserve DNS classification without query words or private addresses',
    () async {
      final previous = DiagnosticLog.active;
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        log.dispose();
        DiagnosticLog.active = previous;
      });
      final adapter = _Adapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'fixture DNS',
          error: const SocketException(
            'Failed host lookup: https://private.example/?token=private-token',
            osError: OSError('fixture address 10.1.2.3', 11001),
          ),
        ),
      );
      final service = create(adapter, wait: (_) async {});
      await expectLater(
        service.search('fixture-private-show', RequestScope()),
        throwsA(isA<DownloadNetworkException>()),
      );
      final entry = log.entries().singleWhere(
        (e) => e.event == 'player.online_subtitle_retry',
      );
      final fields = asJson(entry.data['fields']);
      expect(fields['stage'], 'search');
      expect(fields['kind'], 'connectionError');
      expect(fields['errno'], 11001);
      expect(fields['dns'], isTrue);
      for (final private in [
        'fixture-private-show',
        'private.example',
        'private-token',
        '10.1.2.3',
      ]) {
        expect(entry.detail, isNot(contains(private)));
      }
    },
  );

  test(
    'Network guidance distinguishes DNS, timeout, certificate and proxy failures',
    () {
      final errors = <(Object, String)>[
        (
          const DownloadNetworkException(
            'connectionError',
            cause: SocketException(
              'Failed host lookup: fixture',
              osError: OSError('fixture DNS', 11001),
            ),
          ),
          'DNS',
        ),
        (const DownloadNetworkException('receiveTimeout'), '连接超时'),
        (
          const DownloadNetworkException('badCertificate', retryable: false),
          '证书校验失败',
        ),
        (
          const DownloadNetworkException(
            'unknown',
            retryable: false,
            cause: HandshakeException(
              'Handshake error',
              OSError('CERTIFICATE_VERIFY_FAILED'),
            ),
          ),
          '证书校验失败',
        ),
        (
          const DownloadNetworkException(
            'connectionError',
            cause: WindowsProxyException.connection(
              SocketException(
                'fixture reset',
                osError: OSError('reset', 10054),
              ),
            ),
          ),
          'Windows 系统代理',
        ),
      ];
      for (final (error, guidance) in errors) {
        final message = onlineSubtitleErrorMessage(error, searching: true);
        expect(message, contains('在线字幕搜索'));
        expect(message, contains(guidance));
        expect(message, isNot(contains('下载连接')));
      }
      final proxy = onlineSubtitleFailureFields(errors.last.$1);
      expect(proxy['proxyReason'], 'connection');
      expect(proxy['errno'], 10054);
      expect(
        onlineSubtitleErrorMessage(
          DownloadHttpException(403),
          searching: false,
        ),
        '字幕下载地址已失效，请重新搜索',
      );
    },
  );

  test(
    'A truncated subtitle is retried as a fresh file with no duplicate cues or partial files',
    () async {
      const caption = '1\n00:00:01,000 --> 00:00:02,000\n完整中文字幕\n';
      var attempts = 0;
      Stream<Uint8List> truncated() async* {
        yield Uint8List.fromList(utf8.encode(caption.substring(0, 24)));
        throw const HttpException('Connection closed while receiving data');
      }

      final adapter = _Adapter(
        (_) => ++attempts == 1
            ? ResponseBody(truncated(), 200)
            : ResponseBody.fromString(caption, 200),
      );
      final directory = await subtitleDirectory();
      final file = await create(adapter, wait: (_) async {}).download(
        OnlineSubtitle.fromJson(_caption())!,
        directory,
        RequestScope(),
      );
      expect(await file.readAsString(), caption);
      expect(await directory.list().toList(), hasLength(1));
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'The default subtitle client uses Windows proxy routing for HTTPS search',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final requests = <HttpRequest>[];
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => proxy.close(force: true));
        proxy.listen((request) async {
          requests.add(request);
          request.response.statusCode = 407;
          await request.response.close();
        });
        final service = XunleiOnlineSubtitleService(
          systemProxy: WindowsSystemProxy(
            readConfig: () async =>
                WindowsProxyConfig(proxy: '127.0.0.1:${proxy.port}'),
          ),
        );
        addTearDown(service.close);
        await expectLater(
          service.search('Fixture S01E02', RequestScope()),
          throwsA(isA<DownloadNetworkException>()),
        );
        expect(requests, hasLength(1));
        expect(requests.single.method, 'CONNECT');
        expect(
          requests.single.uri.toString(),
          contains('api-shoulei-ssl.xunlei.com:443'),
        );
        expect(requests.single.uri.toString(), isNot(contains('Fixture')));
        expect(requests.single.headers.value('authorization'), isNull);
      }, _LocalIo());
    },
  );

  test(
    'Subtitle CDN downloads follow current Windows proxy settings while local files stay direct',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        const caption = '1\n00:00:01,000 --> 00:00:02,000\n代理字幕\n';
        final proxied = <HttpRequest>[], direct = <HttpRequest>[];
        Future<HttpServer> server(List<HttpRequest> requests) async {
          final endpoint = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          addTearDown(() => endpoint.close(force: true));
          endpoint.listen((request) async {
            requests.add(request);
            request.response.headers.contentType = ContentType.text;
            request.response.write(caption);
            await request.response.close();
          });
          return endpoint;
        }

        final proxy = await server(proxied), local = await server(direct);
        var reads = 0;
        final service = XunleiOnlineSubtitleService(
          systemProxy: WindowsSystemProxy(
            readConfig: () async {
              reads++;
              return WindowsProxyConfig(proxy: '127.0.0.1:${proxy.port}');
            },
          ),
        );
        addTearDown(service.close);
        final directory = await subtitleDirectory();
        final subtitle = OnlineSubtitle.fromJson(
          _caption(url: 'http://subtitles.invalid/fixture.srt'),
        )!;
        final file = await service.download(
          subtitle,
          directory,
          RequestScope(),
        );
        expect(await file.readAsString(), caption);
        expect(proxied.single.uri.toString(), subtitle.url);
        expect(proxied.single.headers.value('cookie'), isNull);
        expect(reads, 1);
        final localSubtitle = OnlineSubtitle.fromJson(
          _caption(url: 'http://127.0.0.1:${local.port}/fixture.srt'),
        )!;
        expect(
          await (await service.download(
            localSubtitle,
            directory,
            RequestScope(),
          )).readAsString(),
          caption,
        );
        expect(direct, hasLength(1));
        expect(proxied, hasLength(1));
        expect(reads, 1);
      }, _LocalIo());
    },
  );

  test(
    'Cancelling during system proxy resolution prevents a late subtitle search request',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final entered = Completer<void>(),
            resolving = Completer<WindowsProxyConfig>();
        final service = XunleiOnlineSubtitleService(
          systemProxy: WindowsSystemProxy(
            readConfig: () {
              entered.complete();
              return resolving.future;
            },
          ),
        );
        addTearDown(service.close);
        final scope = RequestScope();
        final rejected = expectLater(
          service.search('Fixture', scope),
          throwsA(anything),
        );
        await entered.future;
        scope.cancel();
        await rejected;
        final requests = <HttpRequest>[];
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => proxy.close(force: true));
        proxy.listen((request) async {
          requests.add(request);
          request.response.statusCode = 407;
          await request.response.close();
        });
        resolving.complete(
          WindowsProxyConfig(proxy: '127.0.0.1:${proxy.port}'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(requests, isEmpty);
      }, _LocalIo());
    },
  );

  test(
    'An environment HTTPS proxy remains usable when Windows has no system proxy',
    () async {
      final requests = <HttpRequest>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      proxy.listen((request) async {
        requests.add(request);
        request.response.statusCode = 407;
        await request.response.close();
      });
      final previous = DiagnosticLog.active;
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        log.dispose();
        DiagnosticLog.active = previous;
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        final service = XunleiOnlineSubtitleService(
          systemProxy: WindowsSystemProxy(
            readConfig: () async => const WindowsProxyConfig(),
          ),
        );
        addTearDown(service.close);
        await expectLater(
          service.search('Fixture', RequestScope()),
          throwsA(isA<DownloadNetworkException>()),
        );
        expect(requests, hasLength(1));
        expect(requests.single.method, 'CONNECT');
        final fields = asJson(
          log
              .entries()
              .singleWhere((e) => e.event == 'network.windows_proxy')
              .data['fields'],
        );
        expect(fields['source'], 'environment');
        expect(fields['usesProxy'], isTrue);
      }, _EnvironmentIo({'https_proxy': '127.0.0.1:${proxy.port}'}));
    },
  );

  test(
    'Explicit Windows bypass is respected even with an environment proxy',
    () async {
      const caption = '1\n00:00:01,000 --> 00:00:02,000\n本地字幕\n';
      final direct = <HttpRequest>[], proxied = <HttpRequest>[];
      Future<HttpServer> server(List<HttpRequest> requests) async {
        final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => endpoint.close(force: true));
        endpoint.listen((request) async {
          requests.add(request);
          request.response.write(caption);
          await request.response.close();
        });
        return endpoint;
      }

      final local = await server(direct), proxy = await server(proxied);
      await HttpOverrides.runWithHttpOverrides(() async {
        final service = XunleiOnlineSubtitleService(
          systemProxy: WindowsSystemProxy(
            readConfig: () async =>
                const WindowsProxyConfig(bypass: 'localhost'),
          ),
        );
        addTearDown(service.close);
        final directory = await subtitleDirectory();
        final subtitle = OnlineSubtitle.fromJson(
          _caption(url: 'http://localhost:${local.port}/fixture.srt'),
        )!;
        expect(
          await (await service.download(
            subtitle,
            directory,
            RequestScope(),
          )).readAsString(),
          caption,
        );
        expect(direct, hasLength(1));
        expect(proxied, isEmpty);
      }, _EnvironmentIo({'http_proxy': '127.0.0.1:${proxy.port}'}));
    },
  );

  test(
    'Search encodes the filename without leaking paths or stream tokens',
    () async {
      final adapter = _Adapter((_) => _response([])), service = create(adapter);
      await service.search(r'D:\private\连续剧 & 花絮.S01E02.mkv', RequestScope());
      final request = adapter.requests.single;
      expect(request.uri.scheme, 'https');
      expect(request.uri.host, 'api-shoulei-ssl.xunlei.com');
      expect(request.uri.queryParameters, {'name': '连续剧 & 花絮.S01E02.mkv'});
      expect(request.method, 'GET');
      expect(
        request.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(
        request.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(request.uri.toString(), isNot(contains('private')));

      await service.search(
        'https://video.example.com/private/Show.S01E03.mkv?token=private-token',
        RequestScope(),
      );
      expect(adapter.requests.last.uri.queryParameters, {
        'name': 'Show.S01E03.mkv',
      });
      expect(
        adapter.requests.last.uri.toString(),
        isNot(contains('private-token')),
      );
    },
  );

  test(
    'Results retain upstream order and show decoded language, format and duration',
    () async {
      final adapter = _Adapter(
        (_) => _response([
          _caption(),
          _caption(
            name: 'Show.S01E02.ass',
            url: 'https://subtitle.example.com/show.ass',
            format: '.ASS',
          ),
          {
            'name': 'Show.S01E02.vtt',
            'url': 'https://subtitle.example.com/show.vtt',
            'simple_name': '中英&amp;双语',
            'duration': 0,
          },
        ]),
      );
      final results = await create(
        adapter,
      ).search('Show.S01E02.mkv', RequestScope());
      expect(results.map((s) => s.format), ['srt', 'ass', 'vtt']);
      expect(results.first.name, 'Show.S01E02.srt');
      expect(results.first.title, '简体[SRT]Show.S01E02.srt');
      expect(results.first.languages, ['简体 / 英语']);
      expect(results.first.duration, const Duration(milliseconds: 2858420));
      expect(results.last.title, '中英&双语');
      expect(results.last.duration, isNull);
    },
  );

  test(
    'Search removes duplicate URLs, compressed formats and invalid sources',
    () async {
      final adapter = _Adapter(
        (_) => _response([
          _caption(),
          _caption(name: 'duplicate.srt'),
          _caption(
            name: 'archive.zip',
            url: 'https://subtitle.example.com/archive.zip',
            format: 'zip',
          ),
          _caption(url: 'file:///private/file.srt'),
          _caption(url: 'https://user:secret@subtitle.example.com/other.srt'),
          _caption(url: ''),
        ]),
      );
      final results = await create(adapter).search('Show', RequestScope());
      expect(results, hasLength(1));
      expect(results.single.name, 'Show.S01E02.srt');
    },
  );

  for (final value in ['  ', 'x' * 513]) {
    test(
      'Invalid search words do not contact the service: ${value.length}',
      () async {
        final adapter = _Adapter((_) => _response([]));
        await expectLater(
          create(adapter).search(value, RequestScope()),
          throwsA(isA<AppException>()),
        );
        expect(adapter.requests, isEmpty);
      },
    );
  }

  for (final entry in <String, String>{
    'no results': '{"code":0,"data":[]}',
    'no data': '{"code":0,"data":null}',
  }.entries) {
    test(
      'A successful empty response is not a service error: ${entry.key}',
      () async {
        final adapter = _Adapter(
          (_) => ResponseBody.fromString(entry.value, 200),
        );
        expect(
          await create(adapter).search('nothing', RequestScope()),
          isEmpty,
        );
      },
    );
  }

  for (final body in [
    '<html>error</html>',
    '[]',
    '{"code":1,"data":[]}',
    '{"code":0,"data":{}}',
  ]) {
    test(
      'Malformed or failed search response is not presented as empty: $body',
      () async {
        final adapter = _Adapter((_) => ResponseBody.fromString(body, 200));
        await expectLater(
          create(adapter).search('Show', RequestScope()),
          throwsA(isA<AppException>()),
        );
      },
    );
  }

  test(
    'Oversized search responses stop reading at the configured limit',
    () async {
      final adapter = _Adapter(
        (_) => ResponseBody(
          Stream.value(
            Uint8List(XunleiOnlineSubtitleService.maximumSearchBytes + 1),
          ),
          200,
        ),
      );
      await expectLater(
        create(adapter).search('Show', RequestScope()),
        throwsA(isA<AppException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(adapter.cancelled, isTrue);
    },
  );

  test(
    'A selected subtitle is downloaded as a bounded private file with no video credentials',
    () async {
      const caption = '1\n00:00:01,000 --> 00:00:02,000\n中文字幕\n';
      final adapter = _Adapter(
        (_) => ResponseBody.fromString(
          caption,
          200,
          headers: {
            'content-type': ['text/plain; charset=utf-8'],
          },
        ),
      );
      final directory = await subtitleDirectory();
      final subtitle = OnlineSubtitle.fromJson(_caption())!;
      final file = await create(
        adapter,
      ).download(subtitle, directory, RequestScope());
      expect(file.parent.path, directory.path);
      expect(file.path, endsWith('.srt'));
      expect(file.uri.scheme, 'file');
      expect(await file.readAsString(), caption);
      expect(adapter.requests.single.uri.toString(), subtitle.url);
      expect(
        adapter.requests.single.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(
        adapter.requests.single.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('referer')),
      );
    },
  );

  for (final scenario in [
    'http failure',
    'html',
    'empty',
    'declared size',
    'actual size',
  ]) {
    test(
      'Rejected subtitle downloads leave no private files: $scenario',
      () async {
        final directory = await subtitleDirectory();
        final response = switch (scenario) {
          'http failure' => ResponseBody.fromString('expired', 403),
          'html' => ResponseBody.fromString(
            '<html>expired</html>',
            200,
            headers: {
              'content-type': ['text/html'],
            },
          ),
          'empty' => ResponseBody.fromString('', 200),
          'declared size' => ResponseBody.fromString(
            'too large',
            200,
            headers: {
              'content-length': ['${SubtitleFiles.maximumBytes + 1}'],
            },
          ),
          _ => ResponseBody(
            Stream.value(Uint8List(SubtitleFiles.maximumBytes + 1)),
            200,
          ),
        };
        final adapter = _Adapter((_) => response);
        await expectLater(
          create(adapter).download(
            OnlineSubtitle.fromJson(_caption())!,
            directory,
            RequestScope(),
          ),
          throwsA(anything),
        );
        expect(await directory.list().toList(), isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(adapter.cancelled, isTrue);
      },
    );
  }

  for (final encoding in ['GBK', 'UTF-16 LE', 'UTF-16 BE']) {
    test(
      'Online $encoding Chinese subtitles are normalized to UTF-8 without changing cues',
      () async {
        const text = '1\n00:00:01,000 --> 00:00:02,000\n中文与英语\n';
        final encoded = encoding == 'GBK'
            ? gbk.encode(text)
            : <int>[
                if (encoding == 'UTF-16 LE') ...[
                  0xff,
                  0xfe,
                ] else ...[
                  0xfe,
                  0xff,
                ],
                for (final code in text.codeUnits)
                  if (encoding == 'UTF-16 LE') ...[
                    code & 255,
                    code >> 8,
                  ] else ...[
                    code >> 8,
                    code & 255,
                  ],
              ];
        final adapter = _Adapter(
          (_) => ResponseBody(Stream.value(Uint8List.fromList(encoded)), 200),
        );
        final directory = await subtitleDirectory();
        final file = await create(adapter).download(
          OnlineSubtitle.fromJson(_caption())!,
          directory,
          RequestScope(),
        );
        expect(await file.readAsString(), text);
      },
    );
  }

  for (final text in [
    '<html>upstream failure</html>',
    '{"error":"expired"}',
    'not a subtitle',
    '\x00binary content',
  ]) {
    test(
      'Invalid downloaded content is rejected even without a MIME header: $text',
      () async {
        final adapter = _Adapter((_) => ResponseBody.fromString(text, 200));
        final directory = await subtitleDirectory();
        await expectLater(
          create(adapter).download(
            OnlineSubtitle.fromJson(_caption())!,
            directory,
            RequestScope(),
          ),
          throwsA(isA<AppException>()),
        );
        expect(await directory.list().toList(), isEmpty);
      },
    );
  }

  test(
    'Cancelling a pending search aborts it and a new query can still succeed',
    () async {
      final response = Completer<ResponseBody>();
      final adapter = _Adapter((_) => response.future),
          service = create(adapter);
      final scope = RequestScope();
      final search = service.search('Show', scope);
      final expectation = expectLater(search, throwsA(anything));
      while (adapter.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      scope.cancel();
      await expectation;
      expect(adapter.cancelled, isTrue);
      response.complete(_response([]));
      expect(await service.search('new query', RequestScope()), isEmpty);
    },
  );

  test(
    'Closing the service cancels active requests and blocks new queries',
    () async {
      final response = Completer<ResponseBody>();
      final adapter = _Adapter((_) => response.future),
          service = create(adapter);
      final scope = RequestScope();
      final expectation = expectLater(
        service.search('Show', scope),
        throwsA(anything),
      );
      while (adapter.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      service.close();
      await expectation;
      expect(scope.token.isCancelled, isTrue);
      await expectLater(
        service.search('new', RequestScope()),
        throwsA(isA<AppException>()),
      );
      response.complete(_response([]));
    },
  );

  test(
    'A cancelled download never writes or returns an abandoned subtitle file',
    () async {
      final response = Completer<ResponseBody>(),
          directory = await subtitleDirectory();
      final adapter = _Adapter((_) => response.future),
          service = create(adapter);
      final scope = RequestScope();
      final expectation = expectLater(
        service.download(
          OnlineSubtitle.fromJson(_caption())!,
          directory,
          scope,
        ),
        throwsA(anything),
      );
      while (adapter.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      scope.cancel();
      response.complete(ResponseBody.fromString('late subtitle', 200));
      await expectation;
      expect(await directory.list().toList(), isEmpty);
    },
  );
}
