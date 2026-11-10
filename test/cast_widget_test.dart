import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/playback/cast/cast_discovery.dart';
import 'package:asterlink/playback/cast/cast_session.dart';
import 'package:asterlink/playback/cast/dlna.dart';
import 'package:asterlink/ui/player_page.dart';
import 'player_support.dart';

final _tv = CastDevice(
  id: 'test-tv',
  name: '客厅电视',
  model: 'DLNA Renderer',
  description: Uri.parse('http://192.168.1.8/description.xml'),
  transport: CastService(
    'urn:schemas-upnp-org:service:AVTransport:1',
    Uri.parse('http://192.168.1.8/control'),
  ),
);

class _Discovery extends CastDiscovery {
  int scans = 0;
  bool cleaned = false;
  final manualAddresses = <String>[];
  final found = <CastDevice>[_tv];
  @override
  Future<CastDevice> addAddress(String value) async {
    manualAddresses.add(value);
    return _tv;
  }

  @override
  List<CastDevice> get devices => found;
  @override
  Future<void> scan() async {
    scans++;
  }

  @override
  void dispose() {
    cleaned = true;
    super.dispose();
  }
}

class _Session extends CastSession {
  _Session(super.device, super.source);
  PlayerState value = const PlayerState();
  bool cleaned = false;
  Future<void>? barrier;
  final commands = <String>[];
  void disableSeek() {
    seekSupported = false;
    notifyListeners();
  }

  @override
  PlayerState get state => value;
  @override
  bool get playWhenReady => value.playing;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> start({
    required String title,
    required Duration position,
    required Duration duration,
    bool playWhenReady = true,
  }) async {
    value = PlayerState(
      position: position,
      duration: duration,
      buffering: true,
    );
    notifyListeners();
    await barrier;
    require(!cleaned, '投屏已取消');
    commands.add('Play');
    connected = volumeSupported = true;
    value = value.copyWith(
      playing: playWhenReady,
      buffering: false,
      volume: 35,
    );
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    commands.add('Pause');
    value = value.copyWith(playing: false);
    notifyListeners();
  }

  @override
  Future<void> play() async {
    commands.add('Play');
    value = value.copyWith(playing: true);
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    value = value.copyWith(position: position);
    notifyListeners();
  }

  @override
  Future<void> close() async {
    cleaned = true;
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      await (FontLoader('CastFixture')..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          ))
          .load();
    }
  });

  Future<
    ({PlaybackFixture fixture, _Discovery discovery, List<_Session> sessions})
  >
  render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    Future<void>? barrier,
    bool television = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final discovery = _Discovery(), sessions = <_Session>[];
    final fixture = PlaybackFixture(
      castSessionFactory: (device, source) {
        final session = _Session(device, source)..barrier = barrier;
        sessions.add(session);
        return session;
      },
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('cast-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'CastFixture',
            ),
          ),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh', 'CN')],
          locale: const Locale('zh', 'CN'),
          initialRoute: '/player',
          routes: {
            '/': (_) => const Scaffold(body: Text('已关闭播放器')),
            '/player': (_) => PlayerPage(
              fixture.controller,
              subtitleDirectory: Directory.systemTemp,
              device: FakePlaybackDevice()..isTelevision = television,
              castDiscoveryFactory: () => discovery,
            ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (fixture: fixture, discovery: discovery, sessions: sessions);
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('player-cast')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-cast-panel')), findsOneWidget);
  }

  testWidgets(
    'manual address dialog can be closed and reopened without stale text controllers',
    (tester) async {
      final result = await render(tester);
      await open(tester);
      await tester.tap(find.byKey(const Key('cast-add-address')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('cast-address-input')),
        '192.168.1.8',
      );
      await tester.tap(find.byKey(const Key('cast-address-confirm')));
      await tester.pumpAndSettle();
      expect(result.discovery.manualAddresses, ['192.168.1.8']);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('cast-add-address')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(result.discovery.manualAddresses, ['192.168.1.8']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      result.fixture.store.dispose();
    },
  );

  Future<void> connect(WidgetTester tester) async {
    final tile = find.byKey(const ValueKey('cast-device-test-tv'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (Platform.environment['ASTERLINK_CAST_CAPTURE'] != '1') return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('cast-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final directory = Directory('.local/cast-audit-20261025');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  for (final sample in <(String, Size, double)>[
    ('phone', const Size(393, 864), 1),
    ('small-large-text', const Size(320, 640), 2),
    ('landscape', const Size(844, 390), 1.5),
    ('desktop', const Size(1280, 800), 1),
  ]) {
    testWidgets('TV selection and connected controls fit ${sample.$1}', (
      tester,
    ) async {
      final page = await render(tester, size: sample.$2, scale: sample.$3);
      await open(tester);
      expect(page.discovery.scans, 1);
      await capture(tester, '${sample.$1}-devices');
      await connect(tester);
      expect(page.fixture.controller.casting, isTrue);
      expect(page.fixture.current.state.playing, isFalse);
      await capture(tester, '${sample.$1}-connected');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      expect(page.discovery.cleaned, isTrue);
      await capture(tester, '${sample.$1}-player');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(page.sessions.single.cleaned, isTrue);
      expect(page.fixture.leases.values.single, 0);
    });
  }

  testWidgets('unsupported TV seeking disables progress and skip controls', (
    tester,
  ) async {
    final page = await render(tester);
    await open(tester);
    await connect(tester);
    page.sessions.single.disableSeek();
    await tester.pumpAndSettle();
    final panel = find.byKey(const Key('player-cast-panel'));
    final progress = tester.widget<Slider>(
      find.descendant(of: panel, matching: find.byType(Slider)),
    );
    expect(progress.onChanged, isNull);
    expect(progress.onChangeEnd, isNull);
    for (final label in ['后退 15 秒', '前进 15 秒']) {
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed,
        isNull,
      );
    }
    final pause = find.widgetWithText(TextButton, '暂停');
    expect(tester.widget<TextButton>(pause).onPressed, isNotNull);
    await tester.ensureVisible(pause);
    await tester.tap(pause);
    await tester.pumpAndSettle();
    expect(page.sessions.single.commands.last, 'Pause');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('return to local keeps TV progress and closes remote transport', (
    tester,
  ) async {
    final page = await render(tester);
    await open(tester);
    await connect(tester);
    await page.fixture.controller.seek(const Duration(minutes: 4));
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('cast-resume-local'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(page.fixture.controller.casting, isFalse);
    expect(page.fixture.current.state.position, const Duration(minutes: 4));
    expect(page.fixture.current.state.playing, isTrue);
    expect(page.sessions.single.cleaned, isTrue);
    expect(page.fixture.leases.values.single, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Android TV remote navigates visible controls and seeks only when hidden',
    (tester) async {
      final page = await render(
        tester,
        size: const Size(960, 540),
        television: true,
      );
      await capture(tester, 'television-controls');
      expect(find.byKey(const Key('player-tv-controls')), findsOneWidget);
      final play = tester.widget<IconButton>(
        find.byKey(const Key('player-tv-play')),
      );
      expect(play.focusNode!.hasFocus, isTrue);
      final initial = page.fixture.controller.state.position;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(play.focusNode!.hasFocus, isFalse);
      expect(page.fixture.controller.state.position, initial);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(play.focusNode!.hasFocus, isFalse);
      expect(
        FocusManager.instance.primaryFocus!.debugLabel,
        'AsterLink player',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        page.fixture.controller.state.position,
        initial + const Duration(seconds: 15),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(play.focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(page.fixture.controller.state.playing, isFalse);
      final plays = page.fixture.current.plays;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pumpAndSettle();
      expect(page.fixture.current.plays, plays + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('已关闭播放器'), findsOneWidget);
    },
  );

  testWidgets('Android TV timeline and settings remain reachable by remote', (
    tester,
  ) async {
    final page = await render(
      tester,
      size: const Size(960, 540),
      television: true,
    );
    final slider = tester.widget<Slider>(
      find.byKey(const Key('player-tv-timeline')),
    );
    slider.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(page.fixture.controller.state.position, greaterThan(Duration.zero));
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-panel')), findsOneWidget);
    expect(find.byKey(const Key('player-layout')), findsNothing);
    expect(find.text('自动适配视频方向'), findsNothing);
    final close = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '关闭面板',
      ),
    );
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(close.autofocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final beforeMenuNavigation = page.fixture.controller.state.position;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(page.fixture.controller.state.position, beforeMenuNavigation);
    await capture(tester, 'television-settings');
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPause);
    await tester.pumpAndSettle();
    expect(page.fixture.controller.state.playing, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final sample in [
    (const Size(960, 540), 1.0),
    (const Size(640, 360), 1.5),
  ]) {
    testWidgets(
      'television controls fit ${sample.$1} with scale ${sample.$2}',
      (tester) async {
        await render(
          tester,
          size: sample.$1,
          scale: sample.$2,
          television: true,
        );
        expect(find.byKey(const Key('player-tv-controls')), findsOneWidget);
        expect(
          find.byKey(const Key('player-tv-play')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'connected TV stays listed after a search and reconnect preserves pause',
    (tester) async {
      final page = await render(tester);
      await open(tester);
      await connect(tester);
      final first = page.sessions.single;
      await page.fixture.controller.pause();
      first.value = first.value.copyWith(position: const Duration(minutes: 3));
      page.discovery.found.clear();
      page.discovery.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cast-device-test-tv')), findsOneWidget);
      final button = find.byKey(const Key('cast-reconnect'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(page.sessions.length, 2);
      expect(page.sessions.last.state.playing, isFalse);
      expect(page.sessions.last.state.position, const Duration(minutes: 3));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('cancel button works while the connect request is pending', (
    tester,
  ) async {
    final barrier = Completer<void>();
    final page = await render(tester, barrier: barrier.future);
    await open(tester);
    await connect(tester);
    expect(page.fixture.controller.connectingCast, isTrue);
    final cancel = find.byKey(const Key('cast-disconnect'));
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pump();
    barrier.complete();
    await tester.pumpAndSettle();
    expect(page.fixture.controller.casting, isFalse);
    expect(page.sessions.single.commands, isEmpty);
    expect(page.sessions.single.cleaned, isTrue);
    expect(page.fixture.leases.values.single, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
