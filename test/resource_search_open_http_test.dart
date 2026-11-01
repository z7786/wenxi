import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'support.dart' show FakeHttp, jsonResponse;

ResourceSearchHit hit({bool ticket = true}) => ResourceSearchHit.fromRaw({
  'title': 'Python 教程',
  'url': 'https://pan.quark.cn/s/original',
  'password': 'old1',
  if (ticket) 'open_ticket': 'signed-search-grant',
});
const selection = ResourceSearchFileSelection(
  fileId: 'picked-file',
  parentId: 'source-folder',
  name: 'lesson.mp4',
  size: 123,
);

void main() {
  for (final reason in ['insufficient_space', 'no_account']) {
    test(
      'HTTP $reason keeps original password without activating outage bypass',
      () async {
        final original = hit(ticket: false);
        final http = FakeHttp(
          (_) => jsonResponse({
            'success': true,
            'data': {
              'mode': 'original',
              'url': original.url,
              'password': original.password,
              'reason': reason,
              'message': '使用原链接预览',
            },
          }),
        );
        final api = HttpResourceSearchApi(http, endpoint: 'http://127.0.0.1:1');
        for (var attempt = 0; attempt < 2; attempt++) {
          final result = await api.open(
            original,
            CancelToken(),
            selection: selection,
          );
          expect(result.mode, 'original');
          expect(result.reason, reason);
          expect(result.transferred, false);
          expect(result.hit, same(original));
          expect(result.hit.password, 'old1');
        }
        expect(http.calls, hasLength(2));
      },
    );
  }

  test(
    'native open submits public link and selection without account credentials',
    () async {
      final http = FakeHttp((call) {
        expect(call.url, 'http://127.0.0.1:1/api/v1/search/client/open/file');
        expect(jsonDecode(call.body as String), {
          'url': hit(ticket: false).url,
          'title': hit().title,
          'password': hit().password,
          'selection': selection.toJson(),
        });
        return jsonResponse({
          'success': true,
          'data': {'mode': 'original', 'reason': 'pool_disabled'},
        });
      });
      final api = HttpResourceSearchApi(http, endpoint: 'http://127.0.0.1:1');
      expect(
        (await api.open(
          hit(ticket: false),
          CancelToken(),
          selection: selection,
        )).reason,
        'pool_disabled',
      );
      expect(http.calls, hasLength(1));
    },
  );
  test('policy denial and throttling do not activate outage bypass', () async {
    for (final status in [403, 429]) {
      final http = FakeHttp(
        (call) => HttpResult(
          status,
          jsonEncode({'success': false, 'message': 'request denied'}),
        ),
      );
      final api = HttpResourceSearchApi(http, endpoint: 'http://127.0.0.1:1');
      for (var i = 0; i < 2; i++) {
        await expectLater(
          api.open(hit(), CancelToken(), selection: selection),
          throwsA(isA<AppException>()),
        );
      }
      expect(http.calls, hasLength(2));
    }
  });
  test(
    'backend outage circuit avoids repeated requests during preview',
    () async {
      final http = FakeHttp((call) => const HttpResult(503, 'unavailable'));
      final api = HttpResourceSearchApi(http, endpoint: 'http://127.0.0.1:1');
      for (var i = 0; i < 3; i++) {
        expect(
          (await api.open(hit(), CancelToken(), selection: selection)).reason,
          'backend_unavailable',
        );
      }
      expect(http.calls, hasLength(1));
    },
  );
  test(
    'the plain transport also sends one file mutation without account tokens',
    () async {
      final http = FakeHttp((call) {
        expect(JsonHttp.isReadRequest(call.method, call.url), isFalse);
        expect(call.method, 'POST');
        expect(call.url, 'http://127.0.0.1:1/api/v1/search/open/file');
        expect(jsonDecode(call.body as String), {
          'ticket': 'signed-search-grant',
          'selection': selection.toJson(),
        });
        expect(call.headers.keys, ['X-Resource-Client']);
        expect(call.headers['X-Resource-Client'], matches(r'^[a-f0-9]{32}$'));
        return jsonResponse({
          'success': true,
          'data': {
            'mode': 'temp_share',
            'url': 'https://pan.quark.cn/s/new',
            'transfer_scope': 'file',
            'source_file_id': selection.fileId,
          },
        });
      });
      final api = HttpResourceSearchApi(http, endpoint: 'http://127.0.0.1:1');
      expect(
        (await api.open(
          hit(),
          CancelToken(),
          selection: selection,
        )).transferred,
        isTrue,
      );
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'an old server never receives a fallback whole-share mutation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        await request.drain<void>();
        request.response.statusCode = 404;
        await request.response.close();
      });
      final http = DioJsonHttp(
        client: Dio(BaseOptions(validateStatus: (_) => true)),
      );
      final api = HttpResourceSearchApi(
        http,
        endpoint: 'http://127.0.0.1:${server.port}',
      );
      try {
        await expectLater(
          api.open(hit(), CancelToken(), selection: selection),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('更新服务端'),
            ),
          ),
        );
        expect(paths, ['/api/v1/search/open/file']);
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'a successful response must explicitly acknowledge this selected file',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'success': true,
            'data': {
              'mode': 'temp_share',
              'url': 'https://pan.quark.cn/s/new',
              if (calls == 2) 'transfer_scope': 'file',
              if (calls == 2) 'source_file_id': 'another-file',
            },
          }),
        );
        await request.response.close();
      });
      final http = DioJsonHttp(
        client: Dio(BaseOptions(validateStatus: (_) => true)),
      );
      final api = HttpResourceSearchApi(
        http,
        endpoint: 'http://127.0.0.1:${server.port}',
      );
      try {
        for (var i = 0; i < 2; i++) {
          await expectLater(
            api.open(hit(), CancelToken(), selection: selection),
            throwsA(
              isA<AppException>().having(
                (e) => e.message,
                'message',
                contains('单文件范围'),
              ),
            ),
          );
        }
        expect(calls, 2);
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'open sends its ticket and selected file once on the file-only route',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <(String, String, Map<String, dynamic>)>[];
      server.listen((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        requests.add((request.method, request.uri.path, body));
        expect(request.headers.value('X-API-Key'), isNull);
        expect(request.headers.value('Authorization'), isNull);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'success': true,
            'data': {
              'mode': 'temp_share',
              'transfer_scope': 'file',
              'source_file_id': selection.fileId,
              'url': 'https://pan.quark.cn/s/new',
              'password': 'nEw2',
            },
          }),
        );
        await request.response.close();
      });
      final http = DioJsonHttp(
        client: Dio(BaseOptions(validateStatus: (_) => true)),
      );
      final api = HttpResourceSearchApi(
        http,
        endpoint: 'http://127.0.0.1:${server.port}',
      );
      try {
        final result = await api.open(
          hit(),
          CancelToken(),
          selection: selection,
        );
        expect(result.transferred, isTrue);
        expect(result.hit.url, endsWith('/new'));
        expect(result.hit.password, 'nEw2');
        expect(requests, hasLength(1));
        expect(requests.single.$1, 'POST');
        expect(requests.single.$2, '/api/v1/search/open/file');
        expect(requests.single.$3, {
          'ticket': 'signed-search-grant',
          'selection': selection.toJson(),
        });
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test('failed transfer POST is never automatically retried', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.statusCode = 502;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'success': false, 'message': '转存暂时未完成'}),
      );
      await request.response.close();
    });
    final http = DioJsonHttp(
      client: Dio(BaseOptions(validateStatus: (_) => true)),
    );
    final api = HttpResourceSearchApi(
      http,
      endpoint: 'http://127.0.0.1:${server.port}',
    );
    try {
      final result = await api.open(hit(), CancelToken(), selection: selection);
      expect(result.reason, 'backend_unavailable');
      expect(result.hit.url, hit().url);
      expect(requests, 1);
    } finally {
      http.dio.close(force: true);
      await server.close(force: true);
    }
  });

  test('cancelling an in-flight transfer cancels its HTTP request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>(), finish = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      received.complete();
      await finish.future;
      await request.response.close();
    });
    final http = DioJsonHttp(
      client: Dio(BaseOptions(validateStatus: (_) => true)),
    );
    final api = HttpResourceSearchApi(
      http,
      endpoint: 'http://127.0.0.1:${server.port}',
    );
    final token = CancelToken();
    try {
      final checked = expectLater(
        api.open(hit(), token, selection: selection),
        throwsA(isA<DioException>()),
      );
      await received.future.timeout(const Duration(seconds: 5));
      token.cancel();
      await checked.timeout(const Duration(seconds: 3));
    } finally {
      finish.complete();
      http.dio.close(force: true);
      await server.close(force: true);
    }
  });

  test(
    'native search result silently previews original when backend is unreachable',
    () async {
      final http = DioJsonHttp();
      final api = HttpResourceSearchApi(http, endpoint: 'http://127.0.0.1:1');
      try {
        final result = await api.open(
          hit(ticket: false),
          CancelToken(),
          selection: selection,
        );
        expect(result.reason, 'backend_unavailable');
        expect(result.hit.url, hit(ticket: false).url);
      } finally {
        http.dio.close(force: true);
      }
    },
  );
}
