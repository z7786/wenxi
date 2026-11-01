import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/platform/playback_device.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'package:asterlink/playback/subtitle_matching.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'package:asterlink/playback/cast/cast_session.dart';
import 'package:asterlink/playback/cast/dlna.dart';
import 'package:asterlink/playback/cast/cast_platform.dart';

class FakePlaybackBackend extends PlaybackBackend {
  FakePlaybackBackend(this.name, this.events);
  final String name;
  final List<String> events;
  PlayerState _state = const PlayerState(
    duration: Duration(minutes: 10),
    tracks: Tracks(
      audio: [
        AudioTrack('auto', null, null),
        AudioTrack('no', null, null),
        AudioTrack('1', '普通话', 'zho'),
        AudioTrack('2', 'English', 'eng'),
      ],
      subtitle: [
        SubtitleTrack('auto', null, null),
        SubtitleTrack('no', null, null),
        SubtitleTrack('1', '简体中文', 'zho'),
      ],
    ),
    track: Track(audio: AudioTrack('1', '普通话', 'zho')),
    width: 1920,
    height: 1080,
  );
  @override
  PlayerState get state => _state;
  @override
  int errorRevision = 0;
  @override
  PlaybackFailure? failure;
  DownloadSpec? openedSource;
  Duration? openedStart;
  bool closed = false, failClose = false;
  int plays = 0, pauses = 0, closes = 0;
  int connections = 8, segmentSizeMiB = 4;
  bool hardwareAcceleration = true, failHardwareOpen = false, failOpen = false;
  bool sourceFailure = false;
  bool screenshotSupported = false, nativeSubtitles = false;
  Uint8List? screenshotBytes;
  final captures = <bool>[];
  Future<void>? screenshotBarrier;
  @override
  bool get supportsScreenshot => screenshotSupported;
  @override
  bool get rendersSubtitlesNatively => nativeSubtitles;
  @override
  Future<Uint8List?> screenshot({bool includeSubtitles = false}) async {
    captures.add(includeSubtitles);
    await screenshotBarrier;
    return screenshotBytes;
  }

  bool failAtPlay = false;
  bool throwOnPlay = false;
  @override
  bool get canRetryWithSoftware =>
      !sourceFailure && failure?.sourceFailure != true;
  @override
  Future<void> setConnections(int value) async {
    connections = value;
  }

  @override
  Future<void> setSegmentSizeMiB(int value) async {
    segmentSizeMiB = value;
  }

  final rates = <double>[], volumes = <double>[], seeks = <Duration>[];
  double subtitleDelay = 0, audioDelay = 0;
  int subtitleChanges = 0;
  @override
  String subtitleFontMessage = '';
  @override
  bool subtitleFontLoading = false;
  int subtitleFontRetries = 0;
  @override
  Future<void> retrySubtitleFont() async {
    subtitleFontRetries++;
    subtitleFontMessage = '';
    if (!closed) notifyListeners();
  }

  bool failSubtitle = false;
  Future<void>? subtitleBarrier;
  Future<void>? openBarrier, closeBarrier, initializeBarrier;
  @override
  Future<void> initialize() async {
    events.add('initialize:$name');
    await initializeBarrier;
  }

  void emit(PlayerState state) {
    _state = state;
    if (!closed) notifyListeners();
  }

  void fail() {
    errorRevision++;
    if (!closed) notifyListeners();
  }

  @override
  Future<void> open(DownloadSpec source, Duration start) async {
    openedSource = source;
    openedStart = start;
    events.add('open:$name');
    await openBarrier;
    if (failOpen || (hardwareAcceleration && failHardwareOpen)) {
      throw failure ?? StateError('fixture decoder initialization failed');
    }
    if (closed) throw StateError('closed during open');
    emit(_state.copyWith(position: start, completed: false, playing: false));
  }

  @override
  Future<void> play() async {
    if (throwOnPlay) throw StateError('fixture play command failed');
    plays++;
    emit(_state.copyWith(playing: true, completed: false));
    if (failAtPlay) fail();
  }

  @override
  Future<void> pause() async {
    pauses++;
    if (!closed) emit(_state.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    emit(_state.copyWith(position: position, completed: false));
  }

  @override
  Future<void> setRate(double value) async {
    rates.add(value);
    emit(_state.copyWith(rate: value));
  }

  @override
  Future<void> setVolume(double value) async {
    volumes.add(value);
    emit(_state.copyWith(volume: value));
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    emit(_state.copyWith(track: _state.track.copyWith(audio: track)));
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    subtitleChanges++;
    await subtitleBarrier;
    if (failSubtitle) throw StateError('fixture subtitle loading failed');
    emit(_state.copyWith(track: _state.track.copyWith(subtitle: track)));
  }

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    subtitleDelay = seconds;
  }

  @override
  Future<void> setAudioDelay(double seconds) async {
    audioDelay = seconds;
  }

  @override
  Future<void> close() async {
    closes++;
    events.add('closing:$name');
    await closeBarrier;
    if (failClose) throw StateError('native close failed');
    if (!closed) {
      closed = true;
      events.add('closed:$name');
      super.dispose();
    }
  }
}

class PlaybackFixture {
  PlaybackFixture({
    int count = 3,
    Json? data,
    List<CloudPlatform>? platforms,
    bool renewable = false,
    bool prepareAhead = false,
    List<PlaybackEntry>? suppliedEntries,
    int initialIndex = 0,
    DateTime Function()? now,
    ExternalPlaybackStream Function(DownloadSpec)? externalStreamFactory,
    CastSession Function(CastDevice, DownloadSpec)? castSessionFactory,
    CastPlatform? castPlatform,
    List<PlaybackSubtitle> Function(PlaybackEntry)? subtitlesFor,
    Future<File> Function(PlaybackEntry, PlaybackSubtitle, RequestScope)?
    readSubtitle,
  }) : store = StateStore.memory(data) {
    history = PlaybackStore(store);
    entries =
        suppliedEntries ??
        List.generate(
          count,
          (index) => PlaybackEntry(
            id: '$index',
            key: playbackKey(['test', index]),
            name: 'AsterLink 演示 · 第 ${index + 1} 集.mkv',
            video: true,
            platform: platforms?[index],
          ),
        );
    Future<DownloadSpec> prepare(
      PlaybackEntry entry,
      RequestScope scope,
    ) async {
      final number = ++preparations;
      events.add('prepare:${entry.id}:$number');
      await prepareBarrier?.call(entry.id, number);
      final source = DownloadSpec(
        url: 'https://example.invalid/${entry.id}?token=fixture-secret-$number',
        fileName: entry.name,
        headers: const {
          'Cookie': 'test-cookie=fixture',
          'Referer': 'https://example.invalid/',
        },
      );
      leases[source.url] = 1;
      return source;
    }

    controller = PlaybackController(
      castSessionFactory:
          castSessionFactory ??
          ((device, source) =>
              CastSession(device, source, managePlatform: false)),
      castPlatform: castPlatform,
      externalStreamFactory:
          externalStreamFactory ?? ExternalPlaybackStream.new,
      entries: entries,
      initialIndex: initialIndex,
      now: now,
      history: history,
      checkSource: () {
        require(accountValid, '账号已变化，请重新打开文件列表');
      },
      prepare: prepare,
      prepareAhead: prepareAhead ? prepare : null,
      subtitlesFor: subtitlesFor,
      readSubtitle: readSubtitle,
      refresh: renewable ? prepare : null,
      retain: (source) {
        leases[source.url] = (leases[source.url] ?? 0) + 1;
      },
      release: (source) async {
        events.add('release:${source.fileName}');
        leases[source.url] = (leases[source.url] ?? 0) - 1;
      },
      backendFactory: (entry, hardware) {
        final backend = FakePlaybackBackend(
          '${entry.id}:${backends.length}',
          events,
        );
        backend.hardwareAcceleration = hardware;
        configureBackend?.call(backend);
        backends.add(backend);
        return backend;
      },
    );
  }
  final StateStore store;
  late final PlaybackStore history;
  late final List<PlaybackEntry> entries;
  late final PlaybackController controller;
  final events = <String>[], backends = <FakePlaybackBackend>[];
  final leases = <String, int>{};
  Future<void> Function(String entry, int request)? prepareBarrier;
  void Function(FakePlaybackBackend backend)? configureBackend;
  bool accountValid = true;
  int preparations = 0;
  FakePlaybackBackend get current => backends.last;
}

class FakePlaybackDevice extends PlaybackDevice {
  @override
  bool supportsExternalPlayer = false;
  Future<bool> Function(String, String, Duration)? externalPlayer;
  @override
  Future<bool> openExternalPlayer({
    required String url,
    required String title,
    required Duration position,
  }) async {
    calls.add('externalPlayer');
    return await externalPlayer?.call(url, title, position) ?? false;
  }

  @override
  bool supportsDesktopPip = false;
  @override
  bool supportsOrientation = false;
  @override
  bool supportsPip = true;
  @override
  bool supportsBrightness = true;
  @override
  bool inPip = false;
  @override
  double brightness = .5;
  bool started = false, finished = false, full = false;
  int updates = 0;
  bool _video = false;
  final calls = <String>[];
  final events = StreamController<String>.broadcast();
  @override
  Stream<String> get actions => events.stream;
  @override
  Future<void> start({required bool video}) async {
    started = true;
    _video = video;
  }

  @override
  Future<void> update({
    required bool playing,
    int? width,
    int? height,
    bool autoRotate = true,
    PlaybackOrientation? orientation,
    bool locked = false,
    bool controlsVisible = true,
  }) async {
    updates++;
    this.orientation = _video && orientation != null
        ? orientation
        : playbackOrientation(
            video: _video,
            automatic: autoRotate,
            width: width,
            height: height,
          );
    orientationLocked = locked;
    barsVisible = controlsVisible && !full;
  }

  PlaybackOrientation? orientation;
  bool orientationLocked = false;
  bool barsVisible = true;
  @override
  Future<void> setBrightness(double value) async {
    brightness = value;
    notifyListeners();
  }

  @override
  Future<void> fullscreen(bool enabled) async {
    full = enabled;
    calls.add('fullscreen:$enabled');
  }

  @override
  Future<bool> enterPip() async {
    inPip = true;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> queryPip() async => inPip;
  @override
  Future<void> exitPip() async => leavePip();
  @override
  Future<void> dragPip() async => calls.add('dragPip');

  @override
  Future<void> resizePip(ResizeEdge edge) async =>
      calls.add('resizePip:${edge.name}');
  void leavePip() {
    inPip = false;
    notifyListeners();
  }

  @override
  Future<void> finish() async {
    if (finished) return;
    finished = true;
    full = false;
    await events.close();
    super.dispose();
  }
}

Future<void> removePlayerFixture(Directory directory) async {
  final parent = await Directory.systemTemp.resolveSymbolicLinks();
  final actual = await directory.resolveSymbolicLinks();
  if (!actual.startsWith('$parent${Platform.pathSeparator}asterlink-player-')) {
    throw StateError('Unexpected player fixture directory');
  }
  await directory.delete(recursive: true);
}
