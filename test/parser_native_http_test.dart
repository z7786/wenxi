import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/native_http.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/platform/native_engine.dart';

class _Native extends NativeTransport {
  final calls = <(String, Json)>[];
  bool supported = true;
  final started = Completer<void>();
  Completer<Object?>? pending;
  Object? startError;
  Json response = {
    'status': 'done',
    'code': 403,
    'protocol': 'HTTP/2.0',
    'body': 'Sorry, you have been blocked',
    'headers': {
      'Content-Type': ['text/html'],
      'Set-Cookie': ['fixture-secret'],
    },
  };
  @override
  bool get connected => false;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    calls.add((method, args));
    switch (method) {
      case 'version':
        return {'parserHttp2': supported};
      case 'parserRequestStart':
        if (!started.isCompleted) started.complete();
        if (startError != null) throw startError!;
        return null;
      case 'parserRequestStatus':
        return pending == null ? response : pending!.future;
      case 'parserRequestStop':
        return null;
      default:
        throw StateError('unexpected download storage call: $method');
    }
  }

  @override
  Future<void> dispose() async {}
}

class _TransientVersionNative extends _Native {
  _TransientVersionNative(this.shouldFailVersion);
  final bool Function() shouldFailVersion;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'version' && shouldFailVersion()) {
      calls.add((method, args));
      throw TimeoutException('cold start timeout');
    }
    return super.call(method, args);
  }
}

class _Fallback extends JsonHttp {
  int calls = 0;
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    calls++;
    expect(followRedirects, false);
    return const HttpResult(200, '{}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native response keeps real 403 and sends a POST exactly once without opening storage',
    () async {
      final native = _Native(), fallback = _Fallback();
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        log.dispose();
        DiagnosticLog.active = null;
      });
      final http = NativeParserRuleHttp(native, fallback: fallback);
      final response = await http.request(
        'POST',
        'https://parser.example/api?secret=fixture-query',
        body: {'password': 'fixture-body'},
        headers: {
          'User-Agent': 'fixture-ua',
          'Cookie': 'fixture-cookie',
          'content-type': 'old',
        },
        contentType: 'application/json',
      );
      expect(response.status, 403);
      expect(response.body, contains('blocked'));
      expect(response.header('content-type'), 'text/html');
      expect(native.calls.map((e) => e.$1), [
        'version',
        'parserRequestStart',
        'parserRequestStatus',
        'parserRequestStop',
      ]);
      final sent = native.calls[1].$2;
      expect(sent.str('body'), jsonEncode({'password': 'fixture-body'}));
      expect(sent.obj('headers')['content-type'], isNull);
      expect(sent.obj('headers')['Content-Type'], 'application/json');
      expect(fallback.calls, 0);
      final logs = log.exportFiles().values.join('\n');
      expect(logs, contains('HTTP/2.0'));
      for (final secret in [
        'fixture-query',
        'fixture-body',
        'fixture-cookie',
        'fixture-secret',
      ]) {
        expect(logs, isNot(contains(secret)));
      }
    },
  );

  test(
    'an old native component falls back before sending any site request',
    () async {
      final native = _Native()..supported = false, fallback = _Fallback();
      final http = NativeParserRuleHttp(native, fallback: fallback);
      await http.request('POST', 'https://parser.example/api', body: '{}');
      await http.get('https://parser.example/list');
      expect(native.calls.map((e) => e.$1), ['version']);
      expect(fallback.calls, 2);
    },
  );

  test(
    'transient version check error does not permanently disable native HTTP/2',
    () async {
      var failVersion = true;
      final native = _TransientVersionNative(() => failVersion);
      final fallback = _Fallback();
      final http = NativeParserRuleHttp(native, fallback: fallback);
      await http.get('https://parser.example/first');
      expect(fallback.calls, 1);
      failVersion = false;
      final second = await http.get('https://parser.example/second');
      expect(second.status, 403);
      expect(fallback.calls, 1);
      expect(
        native.calls.where((e) => e.$1 == 'version'),
        hasLength(2),
      );
    },
  );

  test(
    'native network and size failures never replay a POST through the fallback',
    () async {
      for (final kind in ['network', 'response_too_large']) {
        final native = _Native()
          ..response = {'status': 'error', 'errorKind': kind};
        final fallback = _Fallback();
        await expectLater(
          NativeParserRuleHttp(
            native,
            fallback: fallback,
          ).request('POST', 'https://parser.example/api', body: '{}'),
          throwsA(
            isA<ParserRuleError>().having(
              (e) => e.code,
              'code',
              kind == 'network' ? 'RULE_NETWORK' : 'RULE_RESPONSE',
            ),
          ),
        );
        expect(fallback.calls, 0);
        expect(native.calls.last.$1, 'parserRequestStop');
      }
    },
  );

  test('an ambiguous native start failure is not resubmitted', () async {
    final native = _Native()..startError = const AppException('bridge failed');
    final fallback = _Fallback();
    await expectLater(
      NativeParserRuleHttp(
        native,
        fallback: fallback,
      ).request('POST', 'https://parser.example/api'),
      throwsA(isA<ParserRuleError>()),
    );
    expect(fallback.calls, 0);
    expect(native.calls.last.$1, 'parserRequestStop');
  });

  test(
    'cancel releases a pending native request and ignores its late response',
    () async {
      final native = _Native()..pending = Completer<Object?>();
      final scope = RequestScope(), fallback = _Fallback();
      final pending = scope.run(
        () => NativeParserRuleHttp(
          native,
          fallback: fallback,
        ).request('POST', 'https://parser.example/api'),
      );
      final check = expectLater(
        pending,
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '请求已取消'),
        ),
      );
      await native.started.future;
      await Future<void>.delayed(Duration.zero);
      scope.cancel();
      await check;
      expect(native.calls.last.$1, 'parserRequestStop');
      native.pending!.complete(native.response);
      await Future<void>.delayed(Duration.zero);
      expect(fallback.calls, 0);
    },
  );

  test(
    'Android closes parser-only native work without opening download storage',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
            calls.add(asJson(call.arguments).str('method'));
            return 'null';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativeChannel, null),
      );
      final transport = AndroidGopeedTransport();
      await transport.call('parserRequestStart', {'id': 'fixture'});
      expect(transport.connected, false);
      await transport.dispose();
      expect(calls, ['parserRequestStart', 'close']);
    },
  );
}
