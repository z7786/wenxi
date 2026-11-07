import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import 'playback_controller.dart';

const independentPlayerArgument = '--asterlink-player-window';

/// A separate process owns the desktop window and decoder. The main process
/// retains the cloud lease and local media transport until that window closes.
class IndependentPlayerWindow {
  IndependentPlayerWindow(this.controller, {required this.onClosed});
  final PlaybackController controller;
  final Future<void> Function() onClosed;
  final _ready = Completer<void>();
  final _token = newId();
  HttpServer? _server;
  Process? _process;
  bool _closed = false;
  Timer? _watchdog;
  DateTime _lastContact = DateTime.now();
  Future<void>? _closing;

  Future<void> open() async {
    require(Platform.isWindows || Platform.isMacOS, '当前平台不支持独立桌面播放窗口');
    final server = _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final address = 'http://127.0.0.1:${server.port}/$_token';
    // Observe an early process failure even when launching throws first.
    unawaited(_ready.future.catchError((Object _) {}));
    await controller.openExternalPlayer((url, title, position) async {
      final metadata = {
        'url': url,
        'title': title,
        'positionMs': position.inMilliseconds,
        'preferences': controller.preferences.toJson(),
        'videoGeometry': controller.videoGeometry?.toJson(),
      };
      server.listen((request) => unawaited(_serve(request, metadata)));
      final process = _process = await Process.start(
        Platform.resolvedExecutable,
        [independentPlayerArgument, address],
        runInShell: false,
      );
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      await process.stdin.close();
      unawaited(
        process.exitCode.then((_) async {
          if (!_ready.isCompleted) {
            _ready.completeError(const AppException('独立播放窗口启动失败'));
          }
          if (!_closed) await onClosed();
        }),
      );
      await _ready.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw const AppException('播放窗口未能启动，请重试'),
      );
      _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
        if (DateTime.now().difference(_lastContact).inSeconds > 45) {
          unawaited(onClosed());
        }
      });
      return true;
    });
  }

  Future<void> _serve(HttpRequest request, Json metadata) async {
    try {
      if (_closed || request.uri.path != '/$_token' || request.uri.hasQuery) {
        request.response.statusCode = 404;
        return;
      }
      _lastContact = DateTime.now();
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        request.response.write(jsonEncode(metadata));
      } else if (request.method == 'POST') {
        final bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
          require(bytes.length <= 16384, '播放窗口状态过大');
        }
        final value = asJson(jsonDecode(utf8.decode(bytes)));
        if (value.boolean('ready') && !_ready.isCompleted) {
          _ready.complete();
        }
        if (value.containsKey('positionMs') &&
            value.containsKey('durationMs')) {
          final durationMs = value.integer('durationMs');
          if (durationMs > 0) {
            await controller.saveIndependentProgress(
              PlaybackBookmark(
                name: controller.current.name,
                source: controller.current.source,
                position: Duration(
                  milliseconds: value
                      .integer('positionMs')
                      .clamp(0, 31536000000),
                ),
                duration: Duration(
                  milliseconds: durationMs.clamp(0, 31536000000),
                ),
                completed: value.boolean('completed'),
                updatedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            );
          }
        }
        request.response.write('{}');
      } else {
        request.response.statusCode = 405;
      }
    } catch (_) {
      request.response.statusCode = 400;
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    _watchdog?.cancel();
    final process = _process;
    if (process != null) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
    }
    await _server?.close(force: true);
  }();
}
