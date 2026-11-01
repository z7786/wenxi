import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
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
  @override
  List<CastDevice> get devices => [_tv];
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
  @override
  PlayerState get state => value;
  @override
  Future<void> start({
    required String title,
    required Duration position,
    required Duration duration,
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
    value = value.copyWith(playing: true, buffering: false, volume: 35);
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
              device: FakePlaybackDevice(),
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

  Future<void> connect(WidgetTester tester) async {
    final tile = find.byKey(const ValueKey('cast-device-test-tv'));
    await tester.ensureVisible(tile);
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
