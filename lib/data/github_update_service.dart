import 'dart:ffi';
import '../domain/github_update.dart';
import '../domain/remote_control.dart';
import 'remote_control_http.dart';

class GitHubUpdateService {
  GitHubUpdateService({
    required this.platform,
    String? architecture,
    this.repository = buildRepository,
    RemoteControlFetcher? fetcher,
    this.clock = DateTime.now,
  }) : architecture = architecture ?? runtimeArchitecture,
       _fetcher =
           fetcher ??
           DioRemoteControlFetcher(
             timeout: const Duration(seconds: 8),
             headers: const {
               'Accept': 'application/vnd.github+json',
               'User-Agent': 'AsterLink',
               'Cache-Control': 'no-cache',
             },
           );

  static const buildRepository = String.fromEnvironment(
    'ASTERLINK_GITHUB_REPO',
    defaultValue: '',
  );
  static const refreshInterval = Duration(minutes: 15);
  static const failureInterval = Duration(minutes: 5);
  final String platform, architecture, repository;
  final DateTime Function() clock;
  final RemoteControlFetcher _fetcher;
  Future<RemoteUpdate?>? _pending;
  DateTime? _lastAttempt, _nextAttempt;
  RemoteUpdate? _latest;
  Object? _failure;
  bool _closed = false;

  static String get runtimeArchitecture => switch (Abi.current()) {
    Abi.androidArm64 || Abi.windowsArm64 || Abi.macosArm64 => 'arm64',
    Abi.androidX64 || Abi.windowsX64 || Abi.macosX64 => 'x64',
    Abi.androidArm => 'arm',
    Abi.androidIA32 || Abi.windowsIA32 => 'x86',
    _ => 'unsupported',
  };

  bool get configured =>
      {'android', 'windows', 'macos'}.contains(platform) &&
      {'arm64', 'x64', 'arm', 'x86'}.contains(architecture) &&
      RegExp(
        r'^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$',
      ).hasMatch(repository);

  Future<RemoteUpdate?> check({bool force = false}) {
    if (_closed) return Future.error(StateError('GitHub 更新检查已关闭'));
    if (!configured) return Future.error(StateError('GitHub 更新来源未配置'));
    if (_pending case final pending?) return pending;
    final now = clock();
    if (!force &&
        _lastAttempt != null &&
        !now.isBefore(_lastAttempt!) &&
        _nextAttempt != null &&
        now.isBefore(_nextAttempt!)) {
      return _failure == null ? Future.value(_latest) : Future.error(_failure!);
    }
    _lastAttempt = now;
    return _pending = _check().whenComplete(() => _pending = null);
  }

  Future<RemoteUpdate?> _check() async {
    try {
      String? text;
      try {
        text = await _fetcher.fetch(
          Uri.https('api.github.com', '/repos/$repository/releases/latest'),
        );
      } on ControlAccessException catch (error) {
        if (error.statusCode != 404) rethrow;
      }
      if (_closed) throw StateError('GitHub 更新检查已关闭');
      _latest = text == null
          ? null
          : GitHubReleaseParser.parse(
              text,
              repository: repository,
              platform: platform,
              architecture: architecture,
            );
      _failure = null;
      _nextAttempt = clock().add(refreshInterval);
      return _latest;
    } catch (error) {
      if (!_closed) {
        _failure = error;
        _nextAttempt = clock().add(failureInterval);
      }
      rethrow;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _fetcher.close();
  }
}
