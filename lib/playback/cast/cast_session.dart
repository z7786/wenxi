import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
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
  final _commands = AsyncGate();
  ExternalPlaybackStream? _stream;
  Timer? _timer;
  Future<void>? _closing;
  bool _closed = false, _polling = false, _ownsTransport = false;
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
  }) => _commands.run(() async {
    _check();
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
    await stream.start();
    _check();
    // Even a lost SetAVTransportURI response can have changed the TV.
    _ownsTransport = true;
    await client.setMedia(device, stream.url, title, stream.mimeType, duration);
    _check();
    await client.transport(device, 'Play', {'Speed': '1'});
    _check();
    _state = _state.copyWith(playing: true, buffering: false, rate: 1);
    if (position > Duration.zero) {
      try {
        await _seek(position);
      } on CastSoapException catch (e) {
        if (e.code == 701) {
          // A number of TVs accept Seek only after leaving TRANSITIONING.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          _check();
          try {
            await _seek(position);
          } on CastSoapException catch (retry) {
            if (!retry.unsupported && retry.code != 701) rethrow;
            warning = '电视未能恢复进度，可稍后拖动进度条或使用遥控器';
            _state = _state.copyWith(position: Duration.zero);
          }
        } else if (e.unsupported) {
          seekSupported = false;
          warning = '电视不支持拖动进度，将从头播放';
          _state = _state.copyWith(position: Duration.zero);
        } else {
          rethrow;
        }
      }
    }
    _check();
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
    _state = _state.copyWith(position: position, completed: false);
  }

  Future<void> play() => _commands.run(() async {
    _check();
    await client.transport(device, 'Play', {'Speed': '1'});
    _check();
    _state = _state.copyWith(playing: true, completed: false);
    error = '';
    _changed();
  });
  Future<void> pause() => _commands.run(() async {
    _check();
    await client.transport(device, 'Pause');
    _check();
    _state = _state.copyWith(playing: false);
    _changed();
  });
  Future<void> seek(Duration position) => _commands.run(() async {
    _check();
    require(seekSupported, '电视不支持拖动进度，请使用电视遥控器');
    try {
      await _seek(position);
    } on CastSoapException catch (e) {
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

  Future<void> refresh() async {
    if (_closed || _polling || !connected || transportReplaced) return;
    _polling = true;
    try {
      await _commands.run(() async {
        _check();
        Map<String, String> transport = const {};
        if (_transportSupported) {
          try {
            transport = await client.transport(device, 'GetTransportInfo');
          } on CastSoapException catch (e) {
            if (!e.unsupported) rethrow;
            _transportSupported = false;
            warning = '电视不支持回传播放状态，请使用遥控器确认';
          }
        }
        _check();
        Map<String, String> position = const {};
        if (_positionSupported) {
          try {
            position = await client.transport(device, 'GetPositionInfo');
          } on CastSoapException catch (e) {
            if (!e.unsupported) rethrow;
            _positionSupported = false;
            warning = '电视不支持回传播放进度';
          }
        }
        _check();
        final track = position['TrackURI'];
        final trackUri = Uri.tryParse(track ?? '');
        if (trackUri != null && trackUri.hasScheme && track != _stream?.url) {
          _ownsTransport = false;
          transportReplaced = true;
          error = '电视已切换到其他内容，投屏已结束';
          _state = _state.copyWith(playing: false, buffering: false);
          _changed();
          return;
        }
        final status = transport['CurrentTransportState'];
        final duration = parseCastTime(position['TrackDuration']);
        final elapsed = parseCastTime(position['RelTime']);
        final total = duration != null && duration > Duration.zero
            ? duration
            : _state.duration;
        final resetAtEnd =
            status == 'STOPPED' &&
            elapsed == Duration.zero &&
            total > Duration.zero &&
            _state.playing &&
            _state.position >= total - const Duration(seconds: 3);
        final progress = resetAtEnd ? total : elapsed ?? _state.position;
        final completed =
            status == 'STOPPED' &&
            total > Duration.zero &&
            progress > Duration.zero &&
            progress >= total - const Duration(seconds: 3);
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
    } catch (_) {
      if (!_closed && ++_failures >= 3) {
        error = '与电视连接中断，请检查 Wi-Fi，或断开后重新连接';
        _state = _state.copyWith(playing: false, buffering: false);
        _changed();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    _timer?.cancel();
    _elapsed.stop();
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
