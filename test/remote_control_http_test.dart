import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/remote_control_http.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'remote_control_support.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  RequestOptions? request;
  final requests = <RequestOptions>[];
  bool closed = false, cancelled = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    requests.add(options);
    unawaited(cancelFuture?.then((_) => cancelled = true));
    return await respond(options);
  }

  @override
  void close({bool force = false}) => closed = true;
}

void main() {
  final endpoint = Uri.parse(controlEndpoint);
  DioRemoteControlFetcher create(_Adapter adapter, {Duration? timeout}) {
    final dio = Dio()..httpClientAdapter = adapter;
    final fetcher = DioRemoteControlFetcher(
      client: dio,
      timeout: timeout ?? const Duration(seconds: 5),
    );
    addTearDown(fetcher.close);
    return fetcher;
  }

  test(
    'Reads UTF-8 JSON with isolated headers and automatic redirects disabled',
    () async {
      final body = jsonEncode(controlJson(noticeId: 'notice'));
      final bytes = Uint8List.fromList(utf8.encode(body));
      final adapter = _Adapter(
        (_) => ResponseBody(
          Stream.fromIterable([
            Uint8List.sublistView(bytes, 0, 10),
            Uint8List.sublistView(bytes, 10),
          ]),
          200,
        ),
      );
      expect(await create(adapter).fetch(endpoint), body);
      expect(adapter.request!.followRedirects, isFalse);
      expect(adapter.request!.responseType, ResponseType.stream);
      expect(
        adapter.request!.headers.keys.map((s) => s.toLowerCase()),
        isNot(anyElement(anyOf('cookie', 'authorization'))),
      );
      expect(adapter.request!.headers['Cache-Control'], 'no-cache');
    },
  );

  test(
    'Rejects partial responses and server errors instead of caching them',
    () async {
      for (final status in [206, 300, 304, 404, 500]) {
        final adapter = _Adapter(
          (_) => ResponseBody.fromString(
            '{}',
            status,
            headers: {
              'location': ['https://other.example.test/control.json'],
            },
          ),
        );
        await expectLater(
          create(adapter).fetch(endpoint),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'Follows fresh signed CDN redirects from the stable URL and closes redirect bodies',
    () async {
      final body = jsonEncode(controlJson(help: true));
      var visits = 0, closed = 0;
      final streams = <StreamController<Uint8List>>[];
      final adapter = _Adapter((request) {
        if (request.uri == endpoint) {
          final stream = StreamController<Uint8List>(onCancel: () => closed++);
          streams.add(stream);
          return ResponseBody(
            stream.stream,
            302,
            headers: {
              'location': [
                'https://raw.giteeusercontent.com/repo/config.json?signature=${++visits}',
              ],
              'set-cookie': ['server-session=fixture; Secure'],
            },
          );
        }
        return ResponseBody.fromString(body, 200);
      });
      final fetcher = create(adapter);
      expect(await fetcher.fetch(endpoint), body);
      expect(await fetcher.fetch(endpoint), body);
      await Future<void>.delayed(Duration.zero);
      expect(closed, 2);
      expect(adapter.requests.map((request) => request.uri.toString()), [
        endpoint.toString(),
        'https://raw.giteeusercontent.com/repo/config.json?signature=1',
        endpoint.toString(),
        'https://raw.giteeusercontent.com/repo/config.json?signature=2',
      ]);
      for (final request in adapter.requests) {
        expect(request.followRedirects, isFalse);
        expect(
          request.headers.keys.map((s) => s.toLowerCase()),
          isNot(anyElement(anyOf('cookie', 'authorization'))),
        );
      }
      for (final stream in streams) {
        await stream.close();
      }
    },
  );

  test(
    'Resolves relative HTTPS destinations for supported redirect statuses',
    () async {
      for (final status in [301, 302, 303, 307, 308]) {
        final adapter = _Adapter(
          (request) => request.uri == endpoint
              ? ResponseBody.fromString(
                  '',
                  status,
                  headers: {
                    'location': ['../latest/config.json#ignored'],
                  },
                )
              : ResponseBody.fromString('{}', 200),
        );
        expect(await create(adapter).fetch(endpoint), '{}');
        expect(
          adapter.requests.last.uri.toString(),
          'https://config.example.test/latest/config.json',
        );
        expect(adapter.requests, hasLength(2));
      }
    },
  );

  test(
    'Rejects missing or unsafe redirect destinations before requesting them',
    () async {
      for (final location in [
        null,
        '',
        'http://example.test/config.json',
        'file:///config.json',
        'javascript:alert(1)',
        'https://user:secret@example.test/config.json',
        'https://example.test:99999/config.json',
        'https://example.test/a b',
        'https://example.test\\@other.test/config.json',
      ]) {
        final adapter = _Adapter(
          (_) => ResponseBody.fromString(
            '',
            302,
            headers: {
              if (location != null) 'location': [location],
            },
          ),
        );
        await expectLater(
          create(adapter).fetch(endpoint),
          throwsFormatException,
        );
        expect(adapter.requests, hasLength(1));
      }
    },
  );

  test('Stops redirect cycles and caps changing redirect chains', () async {
    final loop = _Adapter(
      (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [endpoint.toString()],
        },
      ),
    );
    await expectLater(create(loop).fetch(endpoint), throwsFormatException);
    expect(loop.requests, hasLength(1));
    var hop = 0;
    final chain = _Adapter(
      (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://config.example.test/hop-${++hop}'],
        },
      ),
    );
    await expectLater(create(chain).fetch(endpoint), throwsFormatException);
    expect(chain.requests, hasLength(DioRemoteControlFetcher.maxRedirects + 1));
  });

  test('All redirect requests share a single total timeout', () {
    fakeAsync((time) {
      var hop = 0;
      final adapter = _Adapter((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://config.example.test/hop-${++hop}'],
          },
        );
      });
      final fetcher = create(
        adapter,
        timeout: const Duration(milliseconds: 120),
      );
      var completed = false;
      Object? failure;
      unawaited(
        fetcher
            .fetch(endpoint)
            .then<void>(
              (_) => completed = true,
              onError: (Object error) => failure = error,
            ),
      );
      time.elapse(const Duration(milliseconds: 80));
      expect(adapter.requests, hasLength(2));
      expect(completed, isFalse);
      expect(failure, isNull);
      time.elapse(const Duration(milliseconds: 40));
      expect(failure, anyOf(isA<TimeoutException>(), isA<DioException>()));
      expect(adapter.cancelled, isTrue);
      time.elapse(const Duration(milliseconds: 180));
      expect(adapter.requests, hasLength(2));
      expect(completed, isFalse);
      fetcher.close();
      time.flushMicrotasks();
      expect(time.pendingTimers, isEmpty);
    });
  });

  test(
    'Enforces size limit on both content length and unbounded chunked bodies',
    () async {
      final declared = _Adapter(
        (_) => ResponseBody.fromString(
          '{}',
          200,
          headers: {
            'content-length': ['${RemoteControlConfig.maxBytes + 1}'],
          },
        ),
      );
      await expectLater(
        create(declared).fetch(endpoint),
        throwsFormatException,
      );
      var cancelled = false;
      final chunks = StreamController<Uint8List>(
        onCancel: () => cancelled = true,
      );
      chunks.add(Uint8List(RemoteControlConfig.maxBytes));
      chunks.add(Uint8List(1));
      final chunked = _Adapter((_) => ResponseBody(chunks.stream, 200));
      await expectLater(create(chunked).fetch(endpoint), throwsFormatException);
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
      await chunks.close();
    },
  );

  test(
    'Rejects invalid UTF-8 rather than repairing configuration bytes',
    () async {
      final adapter = _Adapter(
        (_) => ResponseBody(Stream.value(Uint8List.fromList([0xff])), 200),
      );
      await expectLater(create(adapter).fetch(endpoint), throwsFormatException);
    },
  );

  test('Total timeout aborts a body that never completes', () async {
    final stream = StreamController<Uint8List>();
    final adapter = _Adapter((_) => ResponseBody(stream.stream, 200));
    final fetcher = create(adapter, timeout: const Duration(milliseconds: 60));
    await expectLater(
      fetcher.fetch(endpoint),
      throwsA(anyOf(isA<TimeoutException>(), isA<DioException>())),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(adapter.cancelled, isTrue);
    fetcher.close();
    await stream.close();
  });

  test(
    'Closing a fetcher aborts in-flight requests and refuses new requests',
    () async {
      final response = Completer<ResponseBody>();
      final adapter = _Adapter((_) => response.future);
      final fetcher = create(adapter);
      final pending = fetcher.fetch(endpoint);
      final rejected = expectLater(pending, throwsA(isA<DioException>()));
      await Future<void>.delayed(Duration.zero);
      fetcher.close();
      response.complete(ResponseBody.fromString('{}', 200));
      await rejected;
      expect(adapter.closed, isTrue);
      await expectLater(fetcher.fetch(endpoint), throwsStateError);
    },
  );
}
