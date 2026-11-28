import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:asterlink/playback/playback_state.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../diagnostics/app_log.dart';
import '../playback_failure.dart';
import '../external_stream.dart';
import 'cast_network.dart';
import 'cast_platform.dart';
import 'cast_subtitles.dart';
import 'dlna.dart';

enum _CommandObservation { unverified, pending, completed, failed, replaced }

/// Owns the TV commands and the LAN relay for exactly one playback source.
/// Closing joins outstanding commands before Stop, so a late Play cannot
/// restart a cancelled handoff after its source lease has been released.
class CastSession extends ChangeNotifier {
  CastSession(
    this.device,
    this.source, {
    DlnaClient? client,
    DlnaClient? pollClient,
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
       _pollClient =
           pollClient ??
           (client == null || client.runtimeType == DlnaClient
               ? DlnaClient(
                   timeout: client?.timeout ?? const Duration(seconds: 8),
                 )
               : client),
       platform = platform ?? CastPlatform(),
       localAddress = localAddress ?? CastNetworkRoute().localAddress,
       streamFactory =
           streamFactory ??
           ((source, address) =>
               ExternalPlaybackStream.lan(source, lanAddress: address));
  final CastDevice device;
  final DownloadSpec source;
  final DlnaClient client;
  final DlnaClient _pollClient;
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
  String _connectionStage = 'route';
  String get connectionStage => _connectionStage;
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
  bool muteSupported = false;
  bool? muted;
  bool _muteQueryAvailable = true;
  Tracks _tracks = const Tracks();
  Track _track = const Track();
  String subtitleWarning = '';
  String get subtitleUrl => _stream?.subtitleUrl ?? '';
  bool get subtitleDelivered => subtitleUrl.isNotEmpty;

  AudioTrack? get _sourceAudio {
    final tracks = _tracks.audio.where(
      (t) => !t.uri && !{'auto', 'no'}.contains(t.id),
    );
    // Passing the original container does not change its default audio track.
    // DIDL must describe the source, not falsely claim a local selection was
    // remuxed into it. The selected codec is logged separately below.
    return tracks.where((t) => t.isDefault == true).firstOrNull ??
        tracks.firstOrNull;
  }

  String get audioDescription {
    final audio = _sourceAudio;
    if (audio == null) return '';
    final codec = _codec(audio.codec);
    final channels = audio.channelscount ?? audio.audiochannels;
    return [
      if (codec.isNotEmpty) codec.toUpperCase(),
      if (channels != null && channels > 0) '$channels 声道',
    ].join(' · ');
  }

  static String _codec(String? value) =>
      value != null && RegExp(r'^[a-zA-Z0-9_+-]{1,64}$').hasMatch(value)
      ? value.toLowerCase()
      : '';

  /// Called before start so a replacement owns its own immutable subtitle
  /// snapshot. No decoder, subtitle file or account URL is held by the TV.
  void configureMedia({
    required Tracks tracks,
    required Track track,
    CastSubtitle? subtitle,
    String subtitleWarning = '',
  }) {
    require(!_closed && _stream == null, '投屏会话已开始');
    _tracks = tracks;
    _track = track;
    _subtitle = subtitle;
    this.subtitleWarning = subtitleWarning;
  }

  CastSubtitle? _subtitle;
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

  Future<T> _connectionStep<T>(
    String stage,
    Future<T> Function() action,
  ) async {
    _connectionStage = stage;
    try {
      return await action();
    } on SocketException catch (error) {
      throw CastNetworkException(stage, error);
    } on HttpException catch (error) {
      throw CastNetworkException(stage, error);
    } on TimeoutException catch (error) {
      throw CastNetworkException(stage, error);
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
    final address = await _connectionStep('route', () => localAddress(device));
    _event('route_selected', {
      'local': DiagnosticLog.reference(address.address),
      'family': address.type == InternetAddressType.IPv4 ? 'ipv4' : 'ipv6',
    });
    _check();
    if (_ownsPlatform) {
      await _connectionStep('platform', () => platform.active(true));
    }
    _check();
    _connectionStage = 'relay_start';
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
    await _connectionStep('relay_start', stream.start);
    if (_subtitle case final subtitle?) stream.attachSubtitle(subtitle);
    if (prepareSource) {
      await _connectionStep(
        'source_prepare',
        () => stream.prepareMedia(connections: streamConnections),
      );
    }
    _check();
    await _connectionStep('handoff', () async => await beforeSetMedia?.call());
    _check();
    // Even a lost SetAVTransportURI response can have changed the TV.
    _ownsTransport = true;
    await _connectionStep(
      'set_media',
      () => client.setMedia(
        device,
        stream.url,
        title,
        stream.mimeType,
        duration,
        size: stream.mediaSize,
        subtitleUrl: stream.subtitleUrl,
        audioChannels:
            _sourceAudio?.channelscount ?? _sourceAudio?.audiochannels,
        audioSampleRate: _sourceAudio?.samplerate,
      ),
    );
    _event('media_tracks', {
      'audio_codec': _codec(_sourceAudio?.codec),
      'audio_channels':
          _sourceAudio?.channelscount ?? _sourceAudio?.audiochannels,
      'audio_sample_rate': _sourceAudio?.samplerate,
      'selected_audio_codec': _codec(_track.audio.codec),
      'audio_tracks': _tracks.audio
          .where((t) => !{'auto', 'no'}.contains(t.id))
          .length,
      'subtitle_tracks': _tracks.subtitle
          .where((t) => !{'auto', 'no'}.contains(t.id))
          .length,
      'selected_subtitle_codec': _codec(_track.subtitle.codec),
      'subtitle_external': _track.subtitle.uri || _track.subtitle.data,
      'subtitle_delivered': stream.subtitleUrl != null,
      'subtitle_cues': _subtitle?.cues,
    });
    _check();
    await _connectionStep(
      'play',
      () => _readyCommand(
        'Play',
        () => client.transport(device, 'Play', {'Speed': '1'}),
      ),
    );
    _check();
    _state = _state.copyWith(playing: true, buffering: false, rate: 1);
    if (position > Duration.zero) {
      _resumeBookmark = position;
      try {
        await _connectionStep('seek', () => _seek(position));
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
      } on CastControlException catch (e) {
        _check();
        // Play has already succeeded. An unavailable progress control must not
        // tear down a working stream or discard the local resume bookmark.
        if (transportReplaced) rethrow;
        warning = '电视未确认恢复进度，原进度已保留，可稍后拖动进度条';
        _seekTarget = null;
        _state = _state.copyWith(position: Duration.zero);
        _event('seek_failed', castFailureFields(e, stage: 'seek'));
      }
    }
    _check();
    // DLNA receivers often need Play before Seek. Pause after preparation when
    // the handoff came from paused playback, rather than losing that intent.
    if (!playWhenReady) {
      await _connectionStep(
        'pause',
        () => _readyCommand('Pause', () => client.transport(device, 'Pause')),
      );
      _check();
      _state = _state.copyWith(playing: false);
    }
    connected = true;
    _connectionStage = 'connected';
    _elapsed.start();
    _changed();
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    unawaited(refresh());
  });

  Future<void> _seek(Duration position) async {
    await _readyCommand(
      'Seek',
      () => client.transport(device, 'Seek', {
        'Unit': 'REL_TIME',
        'Target': castTime(position),
      }),
      position: position,
    );
    _check();
    _seekTarget = position;
    _seekSent = DateTime.now();
    _seekRetried = false;
    _state = _state.copyWith(position: position, completed: false);
  }

  Future<void> _readyCommand(
    String action,
    Future<void> Function() command, {
    Duration? position,
  }) async {
    // These absolute controls may be repeated once, but only while the TV
    // still reports this relay. Never replay SetAVTransportURI or unknown
    // writes after an ambiguous response.
    assert({'Play', 'Pause', 'Seek'}.contains(action));
    for (var attempt = 0; attempt < 2; attempt++) {
      _check();
      try {
        await command();
        return;
      } on CastSoapException catch (error) {
        if (error.code != 701 || attempt != 0) rethrow;
        _event('command_retry', {'action': action, 'code': error.code});
        await Future<void>.delayed(const Duration(milliseconds: 500));
        _check();
      } on CastControlException catch (failure) {
        _check();
        _event('control_failed', {
          ...castFailureFields(failure, stage: _connectionStage),
          'attempt': attempt + 1,
        });
        if (!failure.uncertain) rethrow;
        // Let a receiver finish the command before observing its current URI;
        // do not leave an extra retry delay after the ownership check.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        _check();
        final observed = await _observeCommand(action, position: position);
        _check();
        if (observed == _CommandObservation.completed) {
          _event('command_confirmed', {
            'action': action,
            'attempt': attempt + 1,
          });
          return;
        }
        if (observed == _CommandObservation.replaced) {
          throw AppException(error);
        }
        if (attempt != 0 || observed != _CommandObservation.pending) rethrow;
        _event('command_retry', {
          'action': action,
          'reason': 'response_interrupted',
        });
      }
    }
  }

  Future<_CommandObservation> _observeCommand(
    String action, {
    Duration? position,
  }) async {
    final watch = Stopwatch()..start();
    const budget = Duration(seconds: 3);
    Future<Map<String, String>?> query(String name) async {
      _check();
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) return null;
      try {
        final response = await client.action(device.transport, name, {
          'InstanceID': '0',
        }, remaining);
        _check();
        return response;
      } catch (failure) {
        _check();
        _event('control_probe_failed', {
          ...castFailureFields(failure, stage: _connectionStage),
          'action': name,
        });
        return null;
      }
    }

    final progress = await query('GetPositionInfo');
    var track = Uri.tryParse(progress?['TrackURI'] ?? '');
    if (track == null || !track.hasScheme) {
      final media = await query('GetMediaInfo');
      track = Uri.tryParse(media?['CurrentURI'] ?? '');
    }
    if (track == null || !track.hasScheme) {
      return _CommandObservation.unverified;
    }
    if (!_sameTrack(track)) {
      _markTransportReplaced();
      return _CommandObservation.replaced;
    }
    if (!_ownsTransport) return _CommandObservation.unverified;
    final transport = await query('GetTransportInfo');
    if (transport?['CurrentTransportStatus'] == 'ERROR_OCCURRED') {
      return _CommandObservation.failed;
    }
    final state = transport?['CurrentTransportState'];
    final elapsed = parseCastTime(progress?['RelTime']);
    final confirmed = switch (action) {
      'Play' => state == 'PLAYING',
      'Pause' => state == 'PAUSED_PLAYBACK',
      'Seek' =>
        position != null &&
            elapsed != null &&
            elapsed >= position - const Duration(seconds: 3) &&
            elapsed <= position + const Duration(seconds: 10),
      _ => false,
    };
    return confirmed
        ? _CommandObservation.completed
        : _CommandObservation.pending;
  }

  void _markTransportReplaced() {
    _ownsTransport = false;
    transportReplaced = true;
    error = '电视已切换到其他内容，投屏已结束';
    _state = _state.copyWith(playing: false, buffering: false);
    _changed();
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
      subtitleUrl: _stream!.subtitleUrl,
      audioChannels: _sourceAudio?.channelscount ?? _sourceAudio?.audiochannels,
      audioSampleRate: _sourceAudio?.samplerate,
    );
    _check();
    await _readyCommand(
      'Play',
      () => client.transport(device, 'Play', {'Speed': '1'}),
    );
    if (bookmarkState.position > Duration.zero) {
      await _seek(bookmarkState.position);
    }
    if (!_playWhenReady) {
      await _readyCommand('Pause', () => client.transport(device, 'Pause'));
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
    await _readyCommand(
      'Play',
      () => client.transport(device, 'Play', {'Speed': '1'}),
    );
    _check();
    _state = _state.copyWith(playing: true, completed: false);
    _playWhenReady = true;
    error = '';
    _changed();
  });
  Future<void> pause() => _commands.run(() async {
    _check();
    await _readyCommand('Pause', () => client.transport(device, 'Pause'));
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
      await _seek(position);
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
    require(value.isFinite, '音量无效');
    final volume = value.round().clamp(0, 100);
    final raised = volume > _state.volume;
    await client.action(device.rendering!, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': volume.toString(),
    });
    _check();
    _state = _state.copyWith(volume: volume.toDouble());
    // Raising a muted TV's volume should also make that intentional change
    // audible. Starting a cast never changes the user's TV volume or mute.
    try {
      if (raised && muteSupported && muted == true) {
        await _setMuted(false);
      }
    } finally {
      _changed();
    }
  });

  Future<void> setMuted(bool value) => _commands.run(() async {
    _check();
    require(device.rendering != null && muteSupported, '电视不支持远程静音，请使用电视遥控器');
    await _setMuted(value);
    _changed();
  });

  Future<void> _setMuted(bool value) async {
    try {
      await client.action(device.rendering!, 'SetMute', {
        'InstanceID': '0',
        'Channel': 'Master',
        'DesiredMute': value ? '1' : '0',
      });
    } on CastSoapException catch (error) {
      if (error.unsupported) {
        muteSupported = false;
        _muteQueryAvailable = false;
        _changed();
      }
      rethrow;
    }
    _check();
    muted = value;
    _event('mute_changed', {'muted': value});
  }

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
            transport = await _pollClient.transport(device, 'GetTransportInfo');
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
            position = await _pollClient.transport(device, 'GetPositionInfo');
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
          await _pollClient.describe(device.description);
          _check();
        }
        final trackUri = Uri.tryParse(track ?? '');
        if (trackUri != null && trackUri.hasScheme && !_sameTrack(trackUri)) {
          _markTransportReplaced();
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
                _event('seek_unconfirmed', castFailureFields(e, stage: 'seek'));
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
          bool volumeAvailable;
          try {
            final volume = await _pollClient.action(
              device.rendering!,
              'GetVolume',
              {'InstanceID': '0', 'Channel': 'Master'},
            );
            _check();
            final value = double.tryParse(volume['CurrentVolume'] ?? '');
            volumeAvailable = value != null && value.isFinite;
            if (volumeAvailable) {
              _state = _state.copyWith(volume: value.clamp(0, 100));
            }
          } catch (_) {
            volumeAvailable = false;
          }
          if (_muteQueryAvailable) {
            try {
              final result = await _pollClient.action(
                device.rendering!,
                'GetMute',
                {'InstanceID': '0', 'Channel': 'Master'},
                const Duration(seconds: 2),
              );
              _check();
              final value = switch (result['CurrentMute']?.toLowerCase()) {
                '1' || 'true' || 'yes' => true,
                '0' || 'false' || 'no' => false,
                _ => null,
              };
              if (value != muted || muteSupported != (value != null)) {
                _event('mute_state', {'muted': value});
              }
              muteSupported = value != null;
              muted = value;
              if (value == null) _muteQueryAvailable = false;
            } on CastSoapException catch (error) {
              muteSupported = false;
              muted = null;
              if (error.unsupported || error.code == 501) {
                _muteQueryAvailable = false;
              }
            } on TimeoutException {
              // Some renderers advertise RenderingControl but never answer
              // GetMute. Do not delay every future pause or seek with it.
              muteSupported = false;
              muted = null;
              _muteQueryAvailable = false;
            } on CastControlException catch (failure) {
              muteSupported = false;
              muted = null;
              if (failure.cause is TimeoutException) {
                _muteQueryAvailable = false;
              }
            } catch (_) {
              muteSupported = false;
              muted = null;
            }
          }
          // Publish controls together after optional rendering queries settle;
          // an initial volume result must not expose a half-finished poll.
          volumeSupported = volumeAvailable;
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
          ...castFailureFields(e, stage: 'poll'),
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
    if (!identical(_pollClient, client)) {
      _pollClient.close();
    }
    _event('closed', {
      'position_s': bookmarkState.position.inSeconds,
      'poll_failures': _failures,
    });
    await _commands.run(() async {
      if (_ownsTransport) {
        try {
          await client
              .transport(device, 'Stop')
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    });
    client.close();
    _subtitle = null;
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
