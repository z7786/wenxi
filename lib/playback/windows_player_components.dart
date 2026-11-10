import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../diagnostics/app_log.dart';
import '../domain/github_acceleration.dart';

enum WindowsPlayerVariant { compact, full }

enum PlayerComponentStage { idle, downloading, verifying, extracting }

class PlayerComponentArtifact {
  const PlayerComponentArtifact({
    required this.id,
    required this.url,
    required this.archiveBytes,
    required this.archiveHash,
    required this.libraryBytes,
    required this.libraryHash,
  });
  final String id, url, archiveHash, libraryHash;
  final int archiveBytes, libraryBytes;

  static const full = PlayerComponentArtifact(
    id: 'windows-x64-20261108-8bc468896e',
    // Immutable source archive survives the upstream rolling-release expiry.
    url:
        'https://raw.githubusercontent.com/z7786/wenxi/'
        '49b43da008f287049acfd21e684b28c7950ebd15/native/third_party/'
        'mpv-dev-x86_64-20261108-git-8bc468896e.7z',
    archiveBytes: 32959262,
    archiveHash:
        'a36392a8fbd989ae274a37c63d01ef6c51b6070a5ebd2ee26d2715ae88f90ceb',
    libraryBytes: 122517504,
    libraryHash:
        '7eb6d202bb3aa5d311aef32d6f56543fc160d1d3e976667ab99e2503e3ca5b57',
  );
}

typedef PlayerComponentExtractor =
    Future<void> Function(
      File archive,
      Directory destination,
      CancelToken cancel,
    );

/// Installs one pinned runtime outside the application bundle. No DLL is
/// replaced in a running process: selection is applied at the next startup.
class WindowsPlayerComponents extends ChangeNotifier {
  WindowsPlayerComponents({
    Future<Directory> Function()? directory,
    this.artifact = PlayerComponentArtifact.full,
    Dio Function()? http,
    PlayerComponentExtractor? extract,
    bool? supported,
  }) : _directory = directory ?? defaultDirectory,
       _http = http ?? (() => DioJsonHttp().dio),
       _extract = extract,
       supported = supported ?? isSupported;

  static final shared = WindowsPlayerComponents();
  static bool get isSupported =>
      Platform.isWindows && Abi.current() == Abi.windowsX64;
  static Future<Directory> defaultDirectory() async => Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'AsterLink',
      'player_components',
    ),
  );
  static const extractorHash =
      '5bea5af5215089d97749d438351d7288310d0b8a472616edbe1b34168ad1001c';

  final bool supported;
  final PlayerComponentArtifact artifact;
  final Future<Directory> Function() _directory;
  final Dio Function() _http;
  final PlayerComponentExtractor? _extract;
  Directory? _root;
  Future<void>? _refresh, _download, _edit, _runtimeInitialization;
  GitHubAcceleration Function()? acceleration;
  CancelToken? _cancel;
  bool _closed = false, _runtimeLoaded = false;
  bool ready = false, installed = false;
  WindowsPlayerVariant selected = WindowsPlayerVariant.compact;
  WindowsPlayerVariant active = WindowsPlayerVariant.compact;
  PlayerComponentStage stage = PlayerComponentStage.idle;
  int receivedBytes = 0;
  String? error, startupNotice;
  bool get busy => _download != null || _edit != null;
  bool get restartRequired => selected != active;
  double get progress =>
      (receivedBytes / artifact.archiveBytes).clamp(0.0, 1.0);
  File get _selection => File(p.join(_root!.path, 'selection.json'));
  Directory get _installed => Directory(p.join(_root!.path, artifact.id));
  File get _library => File(p.join(_installed.path, 'libmpv-2.dll'));

  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> refresh() {
    if (!supported || _closed) return Future.value();
    if (_refresh case final pending?) return pending;
    return _refresh = _read().whenComplete(() => _refresh = null);
  }

  Future<void> _read() async {
    try {
      _root ??= await _directory();
      require(RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(artifact.id), '播放器组件标识无效');
      installed = await _matches(_library, artifact.libraryBytes, null);
      var preference = WindowsPlayerVariant.compact;
      if (await _selection.exists() && await _selection.length() <= 1024) {
        try {
          final value = asJson(jsonDecode(await _selection.readAsString()));
          if (value.str('variant') == 'full') {
            preference = WindowsPlayerVariant.full;
          }
        } on FormatException {
          startupNotice = '播放器选择记录已损坏，使用精简版；已下载组件仍保留';
        }
      }
      selected = preference;
      ready = true;
      error = null;
    } catch (failure, stack) {
      selected = WindowsPlayerVariant.compact;
      installed = false;
      ready = true;
      error = '无法读取播放器组件，当前继续使用精简版';
      DiagnosticLog.error('player.component_read_failed', failure, stack);
    }
    _changed();
  }

  Future<void> _change(Future<void> Function() action) {
    require(supported && !_closed && !busy, '播放器组件正在处理，请稍后重试');
    return _edit = Future<void>.sync(action).whenComplete(() {
      _edit = null;
      _changed();
    });
  }

  Future<void> select(WindowsPlayerVariant variant) =>
      _change(() => _select(variant));

  Future<void> _select(WindowsPlayerVariant variant) async {
    await refresh();
    require(!_closed, '播放器组件已关闭');
    if (variant == WindowsPlayerVariant.full) {
      require(installed, '请先下载完整播放器组件');
      require(
        await _matches(_library, artifact.libraryBytes, artifact.libraryHash),
        '完整组件校验失败，请重新下载',
      );
    }
    await _saveSelection(variant);
    selected = variant;
    error = null;
    _changed();
  }

  Future<void> _saveSelection(WindowsPlayerVariant variant) async {
    await _root!.create(recursive: true);
    final temporary = File('${_selection.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'variant': variant.name}),
      flush: true,
    );
    await temporary.rename(_selection.path);
  }

  Future<void> initializeRuntime(
    void Function(String? path) initialize, {
    WindowsPlayerVariant? processVariant,
    String? bundledLibrary,
  }) {
    if (_runtimeInitialization case final pending?) return pending;
    return _runtimeInitialization = () async {
      if (_runtimeLoaded) return;
      if (!supported) {
        initialize(null);
        _runtimeLoaded = true;
        return;
      }
      await refresh();
      final variant = processVariant ?? selected;
      final compact =
          bundledLibrary ??
          p.join(p.dirname(Platform.resolvedExecutable), 'libmpv-2.dll');
      if (variant == WindowsPlayerVariant.full) {
        try {
          require(
            await _matches(
              _library,
              artifact.libraryBytes,
              artifact.libraryHash,
            ),
            '完整播放器组件不存在或已损坏',
          );
          initialize(_library.path);
          active = WindowsPlayerVariant.full;
          _runtimeLoaded = true;
          _changed();
          return;
        } catch (failure, stack) {
          startupNotice = '完整组件未能加载，已改用精简版；可重新下载后再启用';
          DiagnosticLog.error('player.component_fallback', failure, stack);
          // Keep failure recovery independent of application/account data.
          try {
            await _saveSelection(WindowsPlayerVariant.compact);
          } catch (_) {}
          selected = WindowsPlayerVariant.compact;
        }
      }
      initialize(compact);
      active = WindowsPlayerVariant.compact;
      _runtimeLoaded = true;
      _changed();
    }().whenComplete(() => _runtimeInitialization = null);
  }

  Future<void> download({GitHubAcceleration? acceleration}) {
    if (_download case final pending?) return pending;
    require(supported && !_closed, '完整组件目前仅支持 Windows x64');
    require(!busy, '播放器组件正在处理，请稍后重试');
    if (active == WindowsPlayerVariant.full) {
      return Future.error(const AppException('完整组件正在使用，请切换精简版并重启后再重新下载'));
    }
    final preferred =
        acceleration ?? this.acceleration?.call() ?? const GitHubAcceleration();
    final cancel = _cancel = CancelToken();
    stage = PlayerComponentStage.downloading;
    receivedBytes = 0;
    return _download = _install(preferred, cancel).whenComplete(() {
      _download = null;
      _changed();
    });
  }

  Future<void> _install(
    GitHubAcceleration acceleration,
    CancelToken cancel,
  ) async {
    Directory? temporary;
    error = null;
    try {
      await refresh();
      _checkpoint(cancel);
      require(active != WindowsPlayerVariant.full, '完整组件正在使用，请切换精简版并重启后再重新下载');
      stage = PlayerComponentStage.downloading;
      receivedBytes = 0;
      _changed();
      await _root!.create(recursive: true);
      temporary = await _root!.createTemp('install-');
      final archive = File(p.join(temporary.path, 'component.7z'));
      final client = _http();
      try {
        final urls = {
          acceleration.urlFor(artifact.url),
          artifact.url,
          if (acceleration.prefix.isNotEmpty)
            'https://gh-proxy.org/${artifact.url}',
          if (acceleration.prefix.isNotEmpty)
            for (final prefix in GitHubAcceleration.presets.values)
              '$prefix${artifact.url}',
        };
        Object? lastFailure;
        var downloaded = false;
        for (final url in urls) {
          _checkpoint(cancel);
          try {
            receivedBytes = 0;
            stage = PlayerComponentStage.downloading;
            _changed();
            await _fetch(client, url, archive, cancel);
            stage = PlayerComponentStage.verifying;
            _changed();
            require(
              await _matches(
                archive,
                artifact.archiveBytes,
                artifact.archiveHash,
              ),
              '下载内容校验失败，请重试或更换 GitHub 加速地址',
            );
            downloaded = true;
            break;
          } catch (failure) {
            _checkpoint(cancel);
            lastFailure = failure;
          }
        }
        if (!downloaded) throw lastFailure ?? const AppException('组件下载失败');
      } finally {
        client.close(force: true);
      }
      _checkpoint(cancel);
      stage = PlayerComponentStage.extracting;
      _changed();
      final extracted = Directory(p.join(temporary.path, 'runtime'));
      await extracted.create();
      await (_extract ?? _extractPinned)(archive, extracted, cancel);
      _checkpoint(cancel);
      require(
        await _matches(
          File(p.join(extracted.path, 'libmpv-2.dll')),
          artifact.libraryBytes,
          artifact.libraryHash,
        ),
        '播放器组件校验失败，原有播放器未更改',
      );
      _checkpoint(cancel);
      // Only inactive, app-owned versioned folders are replaced. Keep the old
      // installation recoverable until the new folder is published.
      Directory? previous;
      if (await _installed.exists()) {
        previous = await _installed.rename(p.join(temporary.path, 'previous'));
      }
      try {
        await extracted.rename(_installed.path);
      } catch (_) {
        if (previous != null) await previous.rename(_installed.path);
        rethrow;
      }
      installed = true;
      startupNotice = null;
      DiagnosticLog.event(
        'player.component_installed',
        fields: {'id': artifact.id},
      );
    } catch (failure, stack) {
      if (!cancel.isCancelled) {
        error = failure is AppException
            ? failure.message
            : '完整组件下载失败，请重试或更换 GitHub 加速地址';
        DiagnosticLog.error('player.component_download_failed', failure, stack);
      }
    } finally {
      _cancel = null;
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
      stage = PlayerComponentStage.idle;
      _changed();
    }
  }

  Future<void> _fetch(
    Dio client,
    String url,
    File target,
    CancelToken cancel,
  ) async {
    final response = await client.get<ResponseBody>(
      url,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        maxRedirects: 5,
        headers: {HttpHeaders.acceptEncodingHeader: 'identity'},
      ),
    );
    require(response.statusCode == 200, '组件下载返回 ${response.statusCode}，请重试');
    final body = response.data!;
    final declared = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    if (declared != null && declared != artifact.archiveBytes) {
      await body.stream.listen((_) {}).cancel();
      throw const AppException('组件大小不匹配');
    }
    final output = await target.open(mode: FileMode.write);
    final updates = Stopwatch()..start();
    try {
      await for (final bytes in body.stream.timeout(
        const Duration(seconds: 45),
      )) {
        _checkpoint(cancel);
        receivedBytes += bytes.length;
        require(receivedBytes <= artifact.archiveBytes, '组件下载内容超过预期大小');
        await output.writeFrom(bytes);
        if (updates.elapsedMilliseconds >= 100) {
          updates.reset();
          _changed();
        }
      }
      require(receivedBytes == artifact.archiveBytes, '下载中断，请重试');
      await output.flush();
    } finally {
      await output.close();
    }
    _changed();
  }

  static Future<bool> _matches(File file, int bytes, String? hash) async {
    if (!await file.exists() || await file.length() != bytes) return false;
    return hash == null ||
        (await sha256.bind(file.openRead()).first).toString() == hash;
  }

  static void _checkpoint(CancelToken cancel) {
    if (cancel.cancelError case final failure?) throw failure;
  }

  static Future<void> _extractPinned(
    File archive,
    Directory destination,
    CancelToken cancel,
  ) async {
    final executable = File(
      p.join(p.dirname(Platform.resolvedExecutable), 'tools', 'player-7za.exe'),
    );
    require(
      await _matches(executable, 1335296, extractorHash),
      '组件解压工具不存在或已损坏，请重新安装软件',
    );
    _checkpoint(cancel);
    final process = await Process.start(executable.path, [
      'e',
      archive.path,
      '-o${destination.path}',
      'libmpv-2.dll',
      '-r',
      '-y',
      '-bd',
    ], runInShell: false);
    // Drain diagnostics without retaining unbounded output or opening a console.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    var completed = false;
    unawaited(
      cancel.whenCancel.then((_) {
        if (!completed) process.kill();
      }),
    );
    try {
      final status = await process.exitCode.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          process.kill();
          throw const AppException('组件解压超时，请重试');
        },
      );
      _checkpoint(cancel);
      require(status == 0, '组件解压失败，请重试');
    } finally {
      completed = true;
    }
  }

  void cancelDownload() => _cancel?.cancel('Component download cancelled');

  Future<void> remove() => _change(() async {
    require(active != WindowsPlayerVariant.full, '完整组件正在使用，请切换精简版并重启后再删除');
    await _select(WindowsPlayerVariant.compact);
    if (await _installed.exists()) await _installed.delete(recursive: true);
    installed = false;
    error = null;
    _changed();
  });

  Future<void> close() async {
    _closed = true;
    cancelDownload();
    await _download;
    await _edit?.catchError((Object _) {});
  }
}

Future<void> initializeMediaRuntime({bool independentWindow = false}) {
  final override = independentWindow
      ? Platform.environment['ASTERLINK_PLAYER_VARIANT']
      : null;
  return WindowsPlayerComponents.shared.initializeRuntime(
    (path) => MediaKit.ensureInitialized(libmpv: path),
    processVariant: switch (override) {
      'compact' => WindowsPlayerVariant.compact,
      'full' => WindowsPlayerVariant.full,
      _ => null,
    },
  );
}
