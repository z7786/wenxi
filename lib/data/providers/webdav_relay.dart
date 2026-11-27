import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../domain/webdav.dart';

class _WebDavAccess {
  _WebDavAccess(this.session, this.location, this.authorization);
  final String session;
  final WebDavLocation location;
  final Map<String, String> authorization;
  final requests = <CancelToken>{};
  void close() {
    for (final request in requests.toList()) {
      request.cancel();
    }
    requests.clear();
  }
}

/// Downloads retain a local capability URL, never the WebDAV login password.
/// Access expires with its remembered account or the running application.
class WebDavRelay {
  WebDavRelay(this.dio);
  final Dio dio;
  final _access = <String, _WebDavAccess>{};
  HttpServer? _server;
  Future<HttpServer>? _opening;
  bool _closed = false;

  Future<Uri> file({
    required Credential credential,
    required WebDavLocation location,
    required String id,
    required Map<String, String> authorization,
  }) async {
    location.uri(id);
    if (_closed) throw const AppException('WebDAV 连接已关闭');
    final server = _server ?? await (_opening ??= _open());
    if (_closed) throw const AppException('WebDAV 连接已关闭');
    final session = credential.field('sessionId');
    final entry = _access.entries
        .where((e) => e.value.session == session)
        .firstOrNull;
    final key = entry?.key ?? newId();
    _access.putIfAbsent(
      key,
      () => _WebDavAccess(session, location, authorization),
    );
    return Uri.parse('http://127.0.0.1:${server.port}/$key$id');
  }

  Future<HttpServer> _open() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw const AppException('WebDAV 连接已关闭');
    }
    _server = server;
    server.listen((request) => unawaited(_serve(request)));
    return server;
  }

  void retainSessions(Set<String> sessions) {
    _access.removeWhere((_, access) {
      if (sessions.contains(access.session)) return false;
      access.close();
      return true;
    });
  }

  Future<void> _serve(HttpRequest request) async {
    CancelToken? cancel;
    _WebDavAccess? access;
    try {
      final path = request.uri.pathSegments;
      access = path.isEmpty ? null : _access[path.first];
      if (access == null ||
          _closed ||
          !{'GET', 'HEAD'}.contains(request.method) ||
          request.uri.hasQuery ||
          request.uri.hasFragment) {
        request.response.statusCode = 404;
        return;
      }
      final id = '/${path.skip(1).map(Uri.encodeComponent).join('/')}';
      final uri = access.location.uri(id);
      cancel = CancelToken();
      final token = cancel;
      access.requests.add(token);
      unawaited(
        request.response.done.then<void>(
          (_) => token.cancel(),
          onError: (Object _) => token.cancel(),
        ),
      );
      final upstream = await dio.request<ResponseBody>(
        uri.toString(),
        cancelToken: token,
        options: Options(
          method: request.method,
          followRedirects: false,
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          headers: {
            ...access.authorization,
            for (final name in const [
              'range',
              'if-range',
              'if-none-match',
              'if-modified-since',
            ])
              name: ?request.headers.value(name),
          },
        ),
      );
      final code = upstream.statusCode ?? 502;
      request.response.statusCode = code >= 300 && code < 400 && code != 304
          ? 502
          : code;
      if ({200, 206, 304, 416}.contains(code)) {
        for (final name in const [
          'content-type',
          'content-length',
          'content-range',
          'accept-ranges',
          'etag',
          'last-modified',
        ]) {
          final value = upstream.headers.value(name);
          if (value != null) request.response.headers.set(name, value);
        }
        if (request.method == 'GET' && upstream.data != null && code != 304) {
          await request.response.addStream(upstream.data!.stream);
        }
      }
    } catch (_) {
      // Do not expose URLs, credentials or raw server response bodies.
      try {
        request.response.statusCode = 502;
      } catch (_) {
        /* Headers may have been sent. */
      }
    } finally {
      if (cancel != null) {
        cancel.cancel();
        access?.requests.remove(cancel);
      }
      try {
        await request.response.close();
      } catch (_) {
        /* The downloader disconnected. */
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final access in _access.values) {
      access.close();
    }
    _access.clear();
    await _server?.close(force: true);
    try {
      await _opening;
    } catch (_) {
      /* A closing bind owns no server. */
    }
  }
}
