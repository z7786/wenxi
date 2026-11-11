import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:asterlink/playback/playback_state.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../diagnostics/app_log.dart';
import '../playback_failure.dart';
import '../external_stream.dart';
import 'cast_platform.dart';
import 'dlna.dart';

/// Owns the TV commands and the LAN relay for exactly one playback source.
/// Closing joins outstanding commands before Stop, so a late Play cannot
/// restart a cancelled handoff after its source lease has been released.
class CastSession extends ChangeNotifier {
  CastSession(
    this.device,
    this.source, {
    DlnaClient? client,
    CastPlatform? platform,
    Future<InternetAddress> Function(CastDevice)? localAddress,
    ExternalPlaybackStream Function(DownloadSpec, InternetAddress)?
    streamFactory,
    this.pollInterval = const Duration(seconds: 2),
    this.managePlatform = true,
    this.connectionGrace = const Duration(seconds: 45),
    this.seekConfirmationTimeout = const Duration(seconds: 4),
    this.prepareSource = true,
  }) : client = client ?? DlnaClient(),
       platform = platform ?? CastPlatform(),
       localAddress = localAddress ?? _route,
       streamFactory =
           streamFactory ??
           ((source, address) =>
               ExternalPlaybackStream.lan(source, lanAddress: address));
  final CastDevice device;
  final DownloadSpec source;
  final DlnaClient client;
  final CastPlatform platform;
  final Future<InternetAddress> Function(CastDevice) localAddress;
  final ExternalPlaybackStream Function(DownloadSpec, InternetAddress)
  streamFactory;
  final Duration pollInterval;
  final bool managePlatform;
  final bool prepareSource;
  int streamConnections = 8;
  final Duration connectionGrace, seekConfirmationTimeout;
  final _commands = AsyncGate();
  ExternalPlaybackStream? _stream;
  Timer? _timer;
  Future<void>? _closing;
  bool _closed = false, _ownsTransport = false;
  Future<void>? _refreshing;
  bool _playWhenReady = true;
  bool get playWhenReady => _playWhenReady;
  bool get connectionLost => _failures >= 3;
  bool connectionAbandoned = false;
  PlaybackFailure? get sourceFailure => _stream?.failure;
  PlayerState get bookmarkState => _state.copyWith(
    position: _resumeBookmark != null && _resumeBookmark! > _state.position
        ? _resumeBookmark
        : _state.position,
  );
  Duration? _resumeBookmark, _seekTarget;
  DateTime? _seekSent, _failureSince;
  bool _seekRetried = false, _suspended = false;
  String _title = '';
  int _transportFaults = 0, _positionFaults = 0;
  void _event(String name, [Map<String, Object?> fields = const {}]) =>
      DiagnosticLog.event(
        'cast.$name',
        fields: {'device': DiagnosticLog.reference(device.id), ...fields},
      );
  bool _controllerPlatform = false;
  bool get _ownsPlatform => managePlatform && !_controllerPlatform;
  void useControllerPlatform() {
    require(!_closed && !connected && _stream == null, '投屏会话已开始');
    _controllerPlatform = true;
  }

  bool connected = false, seekSupported = true, volumeSupported = false;
  bool transportReplaced = false,
      _positionSupported = true,
      _transportSupported = true;
  int _failures = 0, _polls = 0;
  final _elapsed = Stopwatch();
  String warning = '', error = '';
  PlayerState _state = const PlayerState();
  PlayerState get state => _state;
  void _changed() {
    if (!_closed) notifyListeners();
  }

  void _check() => require(!_closed, '投屏已取消');

  static Future<InternetAddress> _route(CastDevice device) async {
    final socket = await Socket.connect(
      device.transport.control.host,
      device.transport.control.port,
      timeout: const Duration(seconds: 5),
    );
    try {
      return socket.address;
    } finally {
      socket.destroy();
    }
  }

  Future<void> start({
    required String title,
    required Duration position,
    required Duration duration,
    bool playWhenReady = true,
    Future<void> Function()? beforeSetMedia,
  }) => _commands.run(() async {
    _check();
    _title = title;
    _event('start', {'position_s': position.inSeconds, 'play': playWhenReady});
    _playWhenReady = playWhenReady;
    _state = PlayerState(
      position: position,
      duration: duration,
      buffering: true,
    );
    final address = await localAddress(device);
    _check();
    if (_ownsPlatform) await platform.active(true);
    _check();
    final stream = _stream = streamFactory(source, address);
    final priorFailure = stream.onFailure;
    stream.onFailure = (failure) {
      priorFailure?.call(failure);
      _event('source_failed', {
        'kind': failure.kind.name,
        'status': failure.status,
      });
      _changed();
    };
    await stream.start();
    if (prepareSource) {
      await stream.prepareMedia(connections: streamConnections);
    }
    _check();
    await beforeSetMedia?.call();
    _check();
    // Even a lost SetAVTransportURI response can have changed the TV.
    _ownsTransport = true;
    await client.setMedia(
      device,
      stream.url,
      title,
      stream.mimeType,
      duration,
      size: stream.mediaSize,
    );
    _check();
    await _readyCommand(() => client.transport(device, 'Play', {'Speed': '1'}));
    _check();
    _state = _state.copyWith(playing: true, buffering: false, rate: 1);
    if (position > Duration.zero) {
      _resumeBookmark = position;
      try {
        await _readyCommand(() => _seek(position));
      } on CastSoapException catch (e) {
        if (e.unsupported) {
          seekSupported = false;
          warning = '电视不支持拖动进度，将从头播放；原进度已保留';
        } else {
          warning = '电视未能恢复进度，原进度已保留，可稍后拖动进度条或使用遥控器';
        }
        _seekTarget = null;
        _state = _state.copyWith(position: Duration.zero);
        _event('seek_failed', {
          'code': e.code,
          'position_s': position.inSeconds,
        });
      }
    }
    _check();
    // DLNA receivers often need Play before Seek. Pause after preparation when
    // the handoff came from paused playback, rather than losing that intent.
    if (!playWhenReady) {
      await _readyCommand(() => client.transport(device, 'Pause'));
      _check();
      _state = _state.copyWith(playing: false);
    }
    connected = true;
    _elapsed.start();
    _changed();
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    unawaited(refresh());
  });

  Future<void> _seek(Duration position) async {
    await client.transport(device, 'Seek', {
      'Unit': 'REL_TIME',
      'Target': castTime(position),
    });
    _check();
    _seekTarget = position;
    _seekSent = DateTime.now();
    _seekRetried = false;
    _state = _state.copyWith(position: position, completed: false);
  }

  Future<T> _readyCommand<T>(Future<T> Function() command) async {
    try {
      return await command();
    } on CastSoapException catch (e) {
      if (e.code != 701) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _check();
      return command();
    }
  }

  // A replacement first prepares its relay while this session remains alive.
  // Hold polling during SetMedia so the old session cannot mistake it for a
  // different user's takeover or issue Stop after the new session starts.
  Future<void> suspend() async {
    _suspended = true;
    await _refreshing;
  }

  void relinquishTransport() {
    _ownsTransport = false;
  }

  Future<void> restore() => _commands.run(() async {
    _check();
    _ownsTransport = true;
    await client.setMedia(
      device,
      _stream!.url,
      _title,
      _stream!.mimeType,
      _state.duration,
      size: _stream!.mediaSize,
    );
    _check();
    await _readyCommand(() => client.transport(device, 'Play', {'Speed': '1'}));
    if (bookmarkState.position > Duration.zero) {
      await _readyCommand(() => _seek(bookmarkState.position));
    }
    if (!_playWhenReady) {
      await _readyCommand(() => client.transport(device, 'Pause'));
    }
    _check();
    _suspended = false;
    _event('restored');
  });
  void resumePolling() {
    _suspended = false;
  }

  bool get changedTransport => _ownsTransport;

  Future<void> play() => _commands.run(() async {
    _check();
    await _readyCommand(() => client.transport(device, 'Play', {'Speed': '1'}));
    _check();
    _state = _state.copyWith(playing: true, completed: false);
    _playWhenReady = true;
    error = '';
    _changed();
  });
  Future<void> pause() => _commands.run(() async {
    _check();
    await _readyCommand(() => client.transport(device, 'Pause'));
    _check();
    _state = _state.copyWith(playing: false);
    _playWhenReady = false;
    _changed();
  });
  Future<void> seek(Duration position) => _commands.run(() async {
    _check();
    require(seekSupported, '电视不支持拖动进度，请使用电视遥控器');
    final bookmark = bookmarkState.position;
    try {
      await _readyCommand(() => _seek(position));
      _resumeBookmark = null;
    } on CastSoapException catch (e) {
      _resumeBookmark = bookmark;
      if (e.unsupported) {
        seekSupported = false;
        _changed();
      }
      rethrow;
    }
    _changed();
  });
  Future<void> setVolume(double value) => _commands.run(() async {
    _check();
    require(
      device.rendering != null && volumeSupported,
      '电视不支持远程调节音量，请使用电视遥控器',
    );
    await client.action(device.rendering!, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': value.round().clamp(0, 100).toString(),
    });
    _check();
    _state = _state.copyWith(volume: value.clamp(0, 100));
    _changed();
  });

  Future<void> refresh() {
    if (_closed ||
        !connected ||
        transportReplaced ||
        _suspended ||
        connectionAbandoned) {
      return Future.value();
    }
    // Return the pending poll so handoff/return can await its latest position.
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    try {
      await _commands.run(() async {
        _check();
        Map<String, String> transport = const {};
        if (_transportSupported) {
          try {
            transport = await client.transport(device, 'GetTransportInfo');
            _transportFaults = 0;
          } on CastSoapException catch (e) {
            if (!e.unsupported && !(e.code == 501 && ++_transportFaults >= 3)) {
              rethrow;
            }
            _transportSupported = false;
            warning = '电视不支持回传播放状态，请使用遥控器确认';
            _event('poll_degraded', {
              'action': 'GetTransportInfo',
              'code': e.code,
            });
          }
        }
        _check();
        Map<String, String> position = const {};
        if (_positionSupported) {
          try {
            position = await client.transport(device, 'GetPositionInfo');
            _positionFaults = 0;
          } on CastSoapException catch (e) {
            if (!e.unsupported && !(e.code == 501 && ++_positionFaults >= 3)) {
              rethrow;
            }
            _positionSupported = false;
            warning = '电视不支持回传播放进度';
            _event('poll_degraded', {
              'action': 'GetPositionInfo',
              'code': e.code,
            });
          }
        }
        _check();
        final track = position['TrackURI'];
        if (!_transportSupported && !_positionSupported) {
          // Missing telemetry is not evidence of a disconnected TV.
          await client.describe(device.description);
          _check();
        }
        final trackUri = Uri.tryParse(track ?? '');
        if (trackUri != null && trackUri.hasScheme && !_sameTrack(trackUri)) {
          _ownsTransport = false;
          transportReplaced = true;
          error = '电视已切换到其他内容，投屏已结束';
          _state = _state.copyWith(playing: false, buffering: false);
          _changed();
          return;
        }
        final status = transport['CurrentTransportState'];
        if (status == 'PLAYING') _playWhenReady = true;
        if (status == 'PAUSED_PLAYBACK') {
          _playWhenReady = false;
        }
        final duration = parseCastTime(position['TrackDuration']);
        final elapsed = parseCastTime(position['RelTime']);
        final total = duration != null && duration > Duration.zero
            ? duration
            : _state.duration;
        final stopped = status == 'STOPPED' || status == 'NO_MEDIA_PRESENT';
        final tolerance = Duration(
          seconds: (pollInterval.inSeconds * 2 + 2).clamp(6, 10),
        );
        final resetAtEnd =
            stopped &&
            (elapsed == null || elapsed == Duration.zero) &&
            total > Duration.zero &&
            _seekTarget == null &&
            _state.playing &&
            _state.position >= total - tolerance;
        var progress = resetAtEnd ? total : elapsed ?? _state.position;
        // A renderer's stopped/transitioning zero is not an intentional seek.
        if (!resetAtEnd &&
            (stopped || status == 'TRANSITIONING') &&
            elapsed == Duration.zero &&
            _state.position > Duration.zero &&
            _seekTarget != Duration.zero) {
          progress = _state.position;
        }
        final completed =
            stopped &&
            transport['CurrentTransportStatus'] != 'ERROR_OCCURRED' &&
            _seekTarget == null &&
            total > Duration.zero &&
            progress > Duration.zero &&
            progress >= total - tolerance;
        if (stopped && !completed) _playWhenReady = false;
        final target = _seekTarget;
        if (target != null && elapsed != null) {
          final confirmationWindow = Duration(
            seconds: (DateTime.now().difference(_seekSent!).inSeconds + 10)
                .clamp(10, 60),
          );
          if (elapsed >= target - const Duration(seconds: 3) &&
              elapsed <= target + confirmationWindow) {
            _seekTarget = null;
            _resumeBookmark = null;
            _event('seek_confirmed', {'position_s': elapsed.inSeconds});
          } else {
            _resumeBookmark = target;
            if (DateTime.now().difference(_seekSent!) >=
                    seekConfirmationTimeout &&
                !_seekRetried &&
                seekSupported &&
                status == 'PLAYING') {
              _seekRetried = true;
              try {
                await client.transport(device, 'Seek', {
                  'Unit': 'REL_TIME',
                  'Target': castTime(target),
                });
              } catch (e) {
                _event('seek_unconfirmed', {
                  'error_type': e.runtimeType.toString(),
                });
              }
              warning = '电视尚未确认定位，原进度已保留；可使用遥控器定位';
            }
            progress = _seekRetried ? elapsed : _state.position;
          }
        }
        if (_seekTarget == null &&
            _resumeBookmark != null &&
            progress >= _resumeBookmark!) {
          _resumeBookmark = null;
        }
        if (_seekRetried &&
            target != null &&
            elapsed != null &&
            elapsed >= target &&
            status == 'PLAYING') {
          _seekTarget = null;
          _resumeBookmark = null;
        }
        if (_state.playing != (status == 'PLAYING') ||
            _state.completed != completed) {
          _event('state', {
            'transport': status,
            'position_s': progress.inSeconds,
            'completed': completed,
          });
        }
        _state = _state.copyWith(
          playing: status == null ? _state.playing : status == 'PLAYING',
          buffering: status == null
              ? _state.buffering
              : status == 'TRANSITIONING',
          completed: completed,
          position: progress,
          duration: total,
        );
        if (_polls++ % 5 == 0 && device.rendering != null) {
          try {
            final volume = await client.action(device.rendering!, 'GetVolume', {
              'InstanceID': '0',
              'Channel': 'Master',
            });
            _check();
            final value = double.tryParse(volume['CurrentVolume'] ?? '');
            volumeSupported = value != null && value.isFinite;
            if (volumeSupported) {
              _state = _state.copyWith(volume: value!.clamp(0, 100));
            }
          } catch (_) {
            volumeSupported = false;
          }
        }
        _check();
        _failures = 0;
        _failureSince = null;
        error = transport['CurrentTransportStatus'] == 'ERROR_OCCURRED'
            ? '电视播放失败，可能不支持此视频格式，请更换资源'
            : '';
        if (_stream!.lastError.isNotEmpty) error = _stream!.lastError;
        if (_elapsed.elapsed > const Duration(seconds: 15) &&
            _stream!.requestsServed == 0) {
          error = '电视尚未读取到视频，请确认同一局域网并允许应用通过防火墙，然后重新连接';
        }
        _changed();
      });
    } catch (e) {
      if (!_closed) {
        _failureSince ??= DateTime.now();
        ++_failures;
        _event('poll_failed', {
          'failures': _failures,
          'code': e is CastSoapException ? e.code : null,
          'error_type': e.runtimeType.toString(),
        });
      }
      if (!_closed && _failures >= 3) {
        error = '与电视连接中断，正在自动重试；请检查 Wi-Fi，或点击重新连接';
        if (DateTime.now().difference(_failureSince!) >= connectionGrace) {
          connectionAbandoned = true;
          _ownsTransport = false;
          _timer?.cancel();
          error = '电视长时间未响应，投屏已结束，播放进度已保留';
          _event('connection_abandoned');
        }
        _changed();
        if (connectionAbandoned && _ownsPlatform) unawaited(close());
      }
    }
  }

  bool _sameTrack(Uri track) {
    final expected = Uri.parse(_stream!.url);
    return track.scheme == expected.scheme &&
        track.host == expected.host &&
        track.port == expected.port &&
        track.normalizePath().path == expected.normalizePath().path;
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    _timer?.cancel();
    _elapsed.stop();
    _event('closed', {
      'position_s': bookmarkState.position.inSeconds,
      'poll_failures': _failures,
    });
    await _commands.run(() async {
      if (_ownsTransport) {
        try {
          await client.transport(device, 'Stop');
        } catch (_) {}
      }
    });
    client.close();
    try {
      await _stream?.close();
    } finally {
      try {
        if (_ownsPlatform) await platform.active(false);
      } finally {
        super.dispose();
      }
    }
  }();
}
