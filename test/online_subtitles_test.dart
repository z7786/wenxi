import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/playback/online_subtitles.dart';
import 'package:asterlink/playback/subtitle_files.dart';

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
  XunleiOnlineSubtitleService create(_Adapter adapter) {
    final dio = Dio()..httpClientAdapter = adapter;
    final service = XunleiOnlineSubtitleService(
      http: TransferHttp(client: dio),
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
