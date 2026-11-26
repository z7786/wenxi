import 'dart:async';
import 'dart:convert';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../platform/native_engine.dart';
import '../http.dart';
import 'http.dart';
import 'rule.dart';

/// Bounded, isolated HTTP/2-capable requests through the bundled native runtime.
/// It does not open download storage, copy browser cookies, or retry a POST.
class NativeParserRuleHttp extends JsonHttp {
  NativeParserRuleHttp(this.transport, {JsonHttp? fallback})
    : fallback = fallback ?? ParserRuleHttp();

  final NativeTransport transport;
  final JsonHttp fallback;
  Future<bool>? _capability;
  static int _sequence = 0;

  void close({bool force = false}) {
    if (fallback case final ParserRuleHttp http) {
      http.close(force: force);
    }
  }

  Future<bool> _supported() {
    final cached = _capability;
    if (cached != null) return cached;
    late final Future<bool> pending;
    pending = (() async {
      try {
        final version = asJson(
          await transport.call('version').timeout(const Duration(seconds: 5)),
        );
        return version['parserHttp2'] == true;
      } catch (_) {
        if (identical(_capability, pending)) _capability = null;
        // No site request has been sent, so the old transport is safe here.
        return false;
      }
    })();
    return _capability = pending;
  }

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    RequestScope.checkpoint();
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        !{'GET', 'POST'}.contains(method) ||
        !await RequestScope.cancellable(_supported())) {
      RequestScope.checkpoint();
      return fallback.request(
        method,
        url,
        body: body,
        headers: headers,
        followRedirects: false,
        contentType: contentType,
      );
    }
    RequestScope.checkpoint();
    final id = 'parser_${DateTime.now().microsecondsSinceEpoch}_${++_sequence}';
    final requestHeaders = {
      for (final entry in headers.entries)
        if (contentType == null || entry.key.toLowerCase() != 'content-type')
          entry.key: entry.value,
      'Content-Type': ?contentType,
    };
    final args = <String, dynamic>{
      'id': id,
      'url': url,
      'method': method,
      'headers': requestHeaders,
      if (body != null) 'body': body is String ? body : jsonEncode(body),
    };
    final scope = RequestScope(), elapsed = Stopwatch()..start();
    final cancellation = RequestScope.current?.whenCancel.asStream().listen(
      (_) => scope.cancel(),
    );
    try {
      return await scope
          .run(() async {
            RequestScope.checkpoint();
            await RequestScope.cancellable(
              transport.call('parserRequestStart', args),
            );
            while (true) {
              RequestScope.checkpoint();
              final state = asJson(
                await RequestScope.cancellable(
                  transport.call('parserRequestStatus', {'id': id}),
                ),
              );
              if (state.str('status') == 'done') {
                final status = state.integer('code');
                final responseBody = state.str('body');
                if (status < 100 || status > 599) {
                  throw const ParserRuleError('RULE_NETWORK', '解析服务响应无效');
                }
                if (utf8.encode(responseBody).length > 1048576) {
                  throw const ParserRuleError('RULE_RESPONSE', '解析服务响应过大');
                }
                final responseHeaders = <String, List<String>>{};
                for (final entry in state.obj('headers').entries) {
                  if (entry.value case final List values) {
                    responseHeaders[entry.key.toLowerCase()] = values
                        .cast<String>();
                  }
                }
                final protocol = state.str('protocol');
                DiagnosticLog.event(
                  'parser.upstream.transport',
                  fields: {
                    'host': uri.host,
                    'method': method,
                    'transport': 'native',
                    if ({'HTTP/1.1', 'HTTP/2.0'}.contains(protocol))
                      'protocol': protocol,
                    'httpStatus': status,
                    'elapsedMs': elapsed.elapsedMilliseconds,
                  },
                );
                return HttpResult(status, responseBody, responseHeaders);
              }
              if (state.str('status') != 'running') {
                RequestScope.checkpoint();
                if (state.str('errorKind') == 'response_too_large') {
                  throw const ParserRuleError('RULE_RESPONSE', '解析服务响应过大');
                }
                throw const ParserRuleError(
                  'RULE_NETWORK',
                  '解析服务连接失败，请检查网络后重试',
                );
              }
              await RequestScope.wait(const Duration(milliseconds: 180));
            }
          })
          .timeout(
            const Duration(seconds: 66),
            onTimeout: () {
              scope.cancel();
              throw const ParserRuleError('RULE_NETWORK', '解析服务响应超时，请稍后重试');
            },
          );
    } on ParserRuleError {
      rethrow;
    } catch (_) {
      RequestScope.checkpoint();
      // Once native Start was called, do not resubmit a possibly charged POST
      // through Dart merely because the native request or bridge failed.
      throw const ParserRuleError('RULE_NETWORK', '解析服务连接失败，请检查网络后重试');
    } finally {
      scope.cancel();
      await cancellation?.cancel();
      try {
        await transport
            .call('parserRequestStop', {'id': id})
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Native requests also have a deadline and bounded result retention.
      }
    }
  }
}
