import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:media_kit/media_kit.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/player_page.dart';
import 'package:asterlink/ui/loading_indicator.dart';
import 'package:asterlink/ui/player_theme.dart';
import 'package:asterlink/platform/player_screenshot.dart';
import 'package:asterlink/platform/windows_external_player.dart';
import 'package:asterlink/playback/playback_sleep_timer.dart';
import 'package:asterlink/ui/subtitle_appearance.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'player_support.dart';

class _FixtureExternalStream extends ExternalPlaybackStream {
  _FixtureExternalStream(super.source);
  @override
  Future<void> start() async {}
  @override
  String get url => 'http://127.0.0.1:12345/fixture/video';
}

class _WindowsPlayerDevice extends FakePlaybackDevice {
  _WindowsPlayerDevice() {
    supportsExternalPlayer = true;
  }
  @override
  final windowsExternalPlayer = WindowsExternalPlayer();
}

class _ScreenshotActions extends PlayerScreenshotActions {
  final calls = <String>[];
  @override
  bool get canCopy => true;
  @override
  bool get canShare => true;
  @override
  Future<String?> save(Uint8List bytes, String name) async {
    calls.add('save:$name');
    return '测试目录';
  }

  @override
  Future<void> copy(Uint8List bytes) async {
    calls.add('copy');
  }

  @override
  Future<void> share(Uint8List bytes, String name, Rect origin) async {
    calls.add('share');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var systemFont = false;
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
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('FixtureUI')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });

  Future<
    ({PlaybackFixture fixture, FakePlaybackDevice device, Directory directory})
  >
  render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    bool dark = false,
    Future<XFile?> Function()? chooseSubtitle,
    Future<XFile?> Function()? chooseExternalPlayer,
    PlaybackFixture? suppliedFixture,
    FakePlaybackDevice? suppliedDevice,
    bool downloadAvailable = false,
    Future<bool> Function()? confirmDownload,
    VoidCallback? onDownload,
    bool settle = true,
    PlayerScreenshotActions screenshotActions = const PlayerScreenshotActions(),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final fixture =
            suppliedFixture ??
            PlaybackFixture(externalStreamFactory: _FixtureExternalStream.new),
        device =
            suppliedDevice ??
            (FakePlaybackDevice()..supportsExternalPlayer = size.width < 1000);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('asterlink-player-widget-'),
    ))!;
    // The test binding unmounts the player and drains its fake clock before tearDown.
    // Real filesystem cleanup runs here, outside that fake clock.
    addTearDown(() => removePlayerFixture(directory));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('player-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            dark ? Brightness.dark : Brightness.light,
            fontFamily: systemFont ? 'FixtureUI' : null,
          ),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          initialRoute: '/player',
          routes: {
            '/': (_) => const Scaffold(body: Center(child: Text('播放器已关闭'))),
            '/player': (_) => PlayerPage(
              fixture.controller,
              subtitleDirectory: directory,
              device: device,
              chooseSubtitle: chooseSubtitle,
              chooseExternalPlayer: chooseExternalPlayer,
              screenshotActions: screenshotActions,
              confirmDownload: confirmDownload,
              onDownload: downloadAvailable
                  ? (_) async {
                      onDownload?.call();
                    }
                  : null,
            ),
          },
        ),
      ),
    );
    if (!settle) {
      await tester.pump();
      return (fixture: fixture, device: device, directory: directory);
    }
    await tester.pumpAndSettle();
    expect(fixture.controller.ready, isTrue);
    fixture.current.emit(
      fixture.current.state.copyWith(
        position: const Duration(seconds: 120),
        buffer: const Duration(seconds: 180),
        subtitle: ['每一段旅途，都值得被记住。', 'Every journey is worth remembering.'],
      ),
    );
    await tester.pump();
    return (fixture: fixture, device: device, directory: directory);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'player waits for download confirmation and cancellation creates no task',
    (tester) async {
      var decision = Completer<bool>();
      var downloads = 0;
      await render(
        tester,
        downloadAvailable: true,
        confirmDownload: () => decision.future,
        onDownload: () => downloads++,
      );
      await tap(tester, find.byTooltip('下载文件'));
      expect(downloads, 0);
      decision.complete(false);
      await tester.pumpAndSettle();
      expect(downloads, 0);
      expect(find.text('已添加到下载队列'), findsNothing);
      decision = Completer<bool>();
      await tap(tester, find.byTooltip('下载文件'));
      expect(downloads, 0);
      decision.complete(true);
      await tester.pumpAndSettle();
      expect(downloads, 1);
    },
  );

  Future<void> openSetting(WidgetTester tester, String label) async {
    if (label == '选集') {
      await tap(tester, find.byKey(const Key('player-playlist')));
      return;
    }
    await tap(tester, find.byTooltip('播放设置'));
    await tester.ensureVisible(find.text(label));
    await tap(tester, find.text(label));
  }

  Future<void> scrollPanelTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      140,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('player-panel')),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Phone exposes the external player button and cancellation restores playback',
    (tester) async {
      final device = FakePlaybackDevice()..supportsExternalPlayer = true;
      final page = await render(
        tester,
        suppliedDevice: device,
        downloadAvailable: true,
      );
      device.externalPlayer = (url, title, position) async {
        expect(url, 'http://127.0.0.1:12345/fixture/video');
        expect(title, page.fixture.controller.current.name);
        expect(position, const Duration(seconds: 120));
        expect(page.fixture.current.state.playing, isFalse);
        return false;
      };
      expect(
        find.byKey(const Key('player-external-player')).hitTestable(),
        findsOneWidget,
      );
      await tap(tester, find.byTooltip('第三方播放器'));
      expect(device.calls, contains('externalPlayer'));
      expect(page.fixture.current.state.playing, isTrue);
      expect(page.fixture.leases.values.single, 1);
    },
  );

  testWidgets(
    'External player failure is visible and leaves internal playback usable',
    (tester) async {
      final device = FakePlaybackDevice()..supportsExternalPlayer = true;
      final page = await render(tester, suppliedDevice: device);
      device.externalPlayer = (_, _, _) async =>
          throw const AppException('未找到可播放此视频的第三方播放器');
      await tap(tester, find.byTooltip('第三方播放器'));
      expect(find.text('未找到可播放此视频的第三方播放器'), findsOneWidget);
      expect(page.fixture.current.state.playing, isTrue);
    },
  );

  testWidgets(
    'External player is also reachable by name in playback settings',
    (tester) async {
      final device = FakePlaybackDevice()..supportsExternalPlayer = true;
      final page = await render(tester, suppliedDevice: device);
      device.externalPlayer = (_, _, _) async => true;
      await tap(tester, find.byTooltip('播放设置'));
      await tester.ensureVisible(find.text('第三方播放器'));
      await tap(tester, find.text('第三方播放器'));
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(page.fixture.controller.playingExternally, isTrue);
      expect(page.fixture.current.state.playing, isFalse);
    },
  );

  testWidgets('Windows selects, remembers and changes external players', (
    tester,
  ) async {
    final device = _WindowsPlayerDevice();
    var choices = 0;
    final page = await render(
      tester,
      size: const Size(1200, 760),
      suppliedDevice: device,
      chooseExternalPlayer: () async =>
          XFile('C:/Players/player${++choices}.exe'),
    );
    device.externalPlayer = (url, _, _) async {
      expect(url, startsWith('http://127.0.0.1:'));
      return true;
    };
    await tap(tester, find.byTooltip('第三方播放器'));
    expect(device.windowsExternalPlayer!.executable, 'C:/Players/player1.exe');
    expect(
      page.fixture.store.data['windowsExternalPlayer'],
      'C:/Players/player1.exe',
    );
    expect(page.fixture.current.state.playing, isFalse);
    await page.fixture.controller.play();
    await tap(tester, find.byTooltip('第三方播放器'));
    expect(find.text('选择其他播放器'), findsOneWidget);
    await tap(tester, find.text('取消'));
    expect(page.fixture.current.state.playing, isTrue);
    expect(choices, 1);
    await tap(tester, find.byTooltip('第三方播放器'));
    await tap(tester, find.text('player1.exe'));
    expect(choices, 1);
    await page.fixture.controller.play();
    await tap(tester, find.byTooltip('第三方播放器'));
    await tap(tester, find.text('选择其他播放器'));
    expect(choices, 2);
    expect(
      page.fixture.store.data['windowsExternalPlayer'],
      'C:/Players/player2.exe',
    );
  });

  testWidgets('Windows file chooser cancellation keeps internal playback', (
    tester,
  ) async {
    final device = _WindowsPlayerDevice();
    final page = await render(
      tester,
      size: const Size(1200, 760),
      suppliedDevice: device,
      chooseExternalPlayer: () async => null,
    );
    await tap(tester, find.byTooltip('第三方播放器'));
    expect(device.calls, isNot(contains('externalPlayer')));
    expect(page.fixture.current.state.playing, isTrue);
    expect(page.fixture.leases.values.single, 1);
  });

  testWidgets('A device without external playback hides the action', (
    tester,
  ) async {
    await render(
      tester,
      size: const Size(320, 700),
      suppliedDevice: FakePlaybackDevice(),
    );
    expect(find.byTooltip('第三方播放器'), findsNothing);
    await tap(tester, find.byTooltip('播放设置'));
    expect(find.text('第三方播放器'), findsNothing);
  });

  for (final size in [const Size(393, 864), const Size(700, 320)]) {
    testWidgets('Player shows only a centered loading icon at $size', (
      tester,
    ) async {
      final fixture = PlaybackFixture();
      final pending = Completer<void>();
      fixture.prepareBarrier = (_, _) async {
        await OperationProgress.step(
          OperationStage.createTemporary,
          () async {},
        );
        await OperationProgress.step(OperationStage.transfer, () async {});
        await OperationProgress.step(
          OperationStage.playbackLink,
          () => pending.future,
        );
      };
      try {
        await render(
          tester,
          suppliedFixture: fixture,
          size: size,
          scale: 1.8,
          settle: false,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AppLoadingIndicator), findsOneWidget);
        expect(
          tester.getCenter(find.byType(AppLoadingIndicator)),
          Offset(size.width / 2, size.height / 2),
        );
        expect(find.text('正在准备播放…'), findsNothing);
        expect(find.text('正在获取播放链接…'), findsNothing);
        expect(fixture.controller.ready, isFalse);
        expect(tester.takeException(), isNull);
        pending.complete();
        await tester.pumpAndSettle();
        expect(fixture.controller.ready, isTrue);
        expect(find.byType(AppLoadingIndicator), findsNothing);
        expect(find.text('正在获取播放链接…'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets(
    'Windows PiP controls play, seek, drag and restore without reopening media',
    (tester) async {
      final device = FakePlaybackDevice()..supportsDesktopPip = true;
      final result = await render(
        tester,
        size: const Size(1100, 780),
        suppliedDevice: device,
      );
      final backend = result.fixture.current;
      await tap(tester, find.byTooltip('画中画'));
      tester.view.physicalSize = const Size(480, 270);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-desktop-pip')), findsOneWidget);
      expect(find.byTooltip('播放设置'), findsNothing);
      await tap(tester, find.byKey(const Key('player-pip-toggle')));
      expect(result.fixture.current.state.playing, isFalse);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('player-pip-seek')),
      );
      slider.onChanged!(180000);
      slider.onChangeEnd!(180000);
      await tester.pumpAndSettle();
      expect(result.fixture.current.state.position, const Duration(minutes: 3));
      await tester.drag(
        find.byKey(const Key('player-pip-drag')),
        const Offset(30, 20),
      );
      await tester.pumpAndSettle();
      expect(device.calls, contains('dragPip'));
      await tester.drag(
        find.byKey(const Key('pip-resize-bottomRight')),
        const Offset(40, 30),
      );
      await tester.pumpAndSettle();
      expect(device.calls, contains('resizePip:bottomRight'));
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile('goldens/player-windows-pip.png'),
      );
      await tap(tester, find.byTooltip('还原窗口'));
      tester.view.physicalSize = const Size(1100, 780);
      await tester.pumpAndSettle();
      expect(device.inPip, isFalse);
      expect(identical(backend, result.fixture.current), isTrue);
      expect(result.fixture.current.state.position, const Duration(minutes: 3));
      expect(find.byTooltip('播放设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows PiP close stops playback and returns to the previous page',
    (tester) async {
      final device = FakePlaybackDevice()..supportsDesktopPip = true;
      final result = await render(tester, suppliedDevice: device);
      await tap(tester, find.byTooltip('画中画'));
      tester.view.physicalSize = const Size(270, 480);
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('关闭画中画'));
      expect(
        result.fixture.current.state.playing,
        isFalse,
        reason: 'Close first pauses the media',
      );
      expect(
        device.inPip,
        isFalse,
        reason: 'Closing restores the window first',
      );
      expect(result.fixture.current.state.playing, isFalse);
      expect(find.text('播放器已关闭'), findsOneWidget);
      expect(result.fixture.current.closed, isTrue);
      expect(device.inPip, isFalse);
      expect(device.finished, isTrue);
    },
  );

  testWidgets(
    'Resolution waits for video metadata and updates with decoded dimensions',
    (tester) async {
      final fixture = PlaybackFixture()
        ..configureBackend = (backend) =>
            backend.emit(backend.state.copyWith(width: 0, height: 0));
      await render(tester, suppliedFixture: fixture);
      final badge = find.byKey(const Key('player-resolution'));
      expect(badge, findsNothing);

      for (final (width, height, rotation, label) in [
        (1280, 720, 0, '1280 × 720'),
        (1920, 1080, 0, '1920 × 1080'),
        (1920, 800, 0, '1920 × 800'),
        (3840, 2160, 0, '3840 × 2160'),
        (1920, 1080, 90, '1080 × 1920'),
      ]) {
        fixture.current.emit(
          fixture.current.state.copyWith(
            videoParams: VideoParams(dw: width, dh: height, rotate: rotation),
          ),
        );
        await tester.pump();
        expect(
          find.descendant(of: badge, matching: find.text(label)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }

      await tester.tapAt(const Offset(196, 300));
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      await tester.tapAt(const Offset(196, 300));
      await tester.pumpAndSettle();
      expect(badge, findsOneWidget);
    },
  );

  testWidgets('Audio playback does not display a video resolution', (
    tester,
  ) async {
    await render(
      tester,
      suppliedFixture: PlaybackFixture(
        suppliedEntries: [
          PlaybackEntry(
            id: 'audio',
            key: 'audio',
            name: '音乐.mp3',
            video: false,
          ),
        ],
      ),
    );
    expect(find.byKey(const Key('player-resolution')), findsNothing);
  });

  for (final (name, size, scale, dark) in [
    ('player-phone', const Size(393, 864), 1.0, false),
    ('player-landscape', const Size(844, 390), 1.0, false),
    ('player-desktop', const Size(1100, 780), 1.0, false),
    ('player-large-text', const Size(320, 700), 1.8, false),
    ('player-dark', const Size(393, 864), 1.0, true),
  ]) {
    testWidgets('$name controls remain reachable without overflow', (
      tester,
    ) async {
      await render(tester, size: size, scale: scale, dark: dark);
      expect(
        find.byKey(const Key('player-lock')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsOneWidget,
      );
      final resolution = find.byKey(const Key('player-resolution'));
      final title = find.text('AsterLink 演示 · 第 1 集.mkv');
      expect(
        find.descendant(of: resolution, matching: find.text('1920 × 1080')),
        findsOneWidget,
      );
      expect(
        tester.getRect(resolution).top,
        greaterThan(tester.getRect(title).bottom),
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }

  for (final dark in [false, true]) {
    testWidgets(
      'Player controls stay legible in the ${dark ? 'dark' : 'light'} application theme',
      (tester) async {
        await render(tester, dark: dark);
        final slider = tester.widget<Slider>(
          find.byKey(const Key('player-seek')),
        );
        expect(
          slider.activeColor,
          playerAccent(tester.element(find.byKey(const Key('player-seek')))),
        );
        await tap(tester, find.byTooltip('播放设置'));
        final panel = tester.widget<Material>(
          find.byKey(const Key('player-panel')),
        );
        expect(panel.color, playerPanelColor);
        expect(
          Theme.of(tester.element(find.text('自动适配视频方向'))).brightness,
          Brightness.dark,
        );
        expect(find.text('自动适配视频方向'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(const Key('player-capture')),
          matchesGoldenFile(
            'goldens/player-settings-${dark ? 'dark' : 'light'}.png',
          ),
        );
      },
    );
  }

  testWidgets(
    'A right-side settings panel adapts to portrait without restarting playback',
    (tester) async {
      final page = await render(tester, size: const Size(844, 390));
      final backend = page.fixture.current;
      await tap(tester, find.byTooltip('播放设置'));
      final side = tester.getRect(find.byKey(const Key('player-panel')));
      expect(side.right, 844);
      expect(side.width, lessThan(422));
      expect(side.top, 0);
      expect(side.height, 390);
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile('goldens/player-settings-landscape.png'),
      );
      await scrollPanelTo(tester, find.text('记住播放进度'));
      await tester.pumpAndSettle();
      await tap(tester, find.text('记住播放进度'));
      expect(page.fixture.history.preferences.resume, isFalse);
      tester.view.physicalSize = const Size(393, 864);
      await tester.pumpAndSettle();
      final bottom = tester.getRect(find.byKey(const Key('player-panel')));
      expect(bottom.left, 0);
      expect(bottom.width, 393);
      expect(bottom.top, greaterThan(0));
      expect(bottom.bottom, 864);
      expect(page.fixture.current, same(backend));
      expect(backend.state.playing, isTrue);
      expect(page.fixture.history.preferences.resume, isFalse);
      await tester.scrollUntilVisible(
        find.text('字幕'),
        -180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('player-panel')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tap(tester, find.text('字幕'));
      expect(find.text('关闭字幕'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PiP dismisses panels and a selected submenu cannot reappear over it',
    (tester) async {
      final page = await render(tester);
      await tap(tester, find.byTooltip('播放设置'));
      await page.device.enterPip();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(page.fixture.current.state.playing, isTrue);
      page.device.leavePip();
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('播放设置'));
      await tester.tap(find.text('字幕'));
      await page.device.enterPip();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(find.text('关闭字幕'), findsNothing);
      expect(page.fixture.current.state.playing, isTrue);
      page.device.leavePip();
      await tester.pumpAndSettle();
      await openSetting(tester, '音轨');
      expect(find.text('音轨与同步'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Progress updates do not prevent controls and system bars from hiding',
    (tester) async {
      final page = await render(tester);
      final backend = page.fixture.current;
      for (var i = 1; i <= 5; i++) {
        backend.emit(
          backend.state.copyWith(position: Duration(seconds: 120 + i)),
        );
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-seek')), findsNothing);
      expect(find.byKey(const Key('player-collapsed-progress')), findsNothing);
      expect(find.byKey(const Key('player-bottom-controls')), findsNothing);
      expect(page.device.barsVisible, isFalse);
      final seeks = backend.seeks.length;
      await tester.tapAt(const Offset(196, 432));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('player-seek')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const Key('player-collapsed-progress')), findsNothing);
      expect(page.device.barsVisible, isTrue);
      expect(backend.seeks.length, seeks);
      expect(backend.state.position, const Duration(seconds: 125));
      expect(backend.state.playing, isTrue);
    },
  );

  testWidgets(
    'Speed controls and all toolbar actions fit large text and safe areas',
    (tester) async {
      final page = await render(
        tester,
        size: const Size(320, 700),
        scale: 2,
        downloadAvailable: true,
      );
      for (final label in ['返回', '下载文件', '画中画', '播放设置']) {
        expect(find.byTooltip(label).hitTestable(), findsOneWidget);
      }
      await tap(tester, find.byKey(const Key('player-speed')));
      await tester.ensureVisible(find.byKey(const ValueKey('player-rate-3.0')));
      await tap(tester, find.byKey(const ValueKey('player-rate-3.0')));
      expect(page.fixture.current.state.rate, 3);
      expect(page.fixture.history.preferences.rate, 3);
      tester.view.physicalSize = const Size(640, 320);
      tester.view.padding = FakeViewPadding(left: 44, right: 24, bottom: 20);
      addTearDown(tester.view.resetPadding);
      await tester.pumpAndSettle();
      final lock = tester.getRect(find.byKey(const Key('player-lock')));
      expect(lock.left, greaterThanOrEqualTo(44));
      final fullscreen = tester.getRect(
        find.byKey(const Key('player-fullscreen')),
      );
      expect(fullscreen.right, lessThanOrEqualTo(616));
      expect(fullscreen.bottom, lessThanOrEqualTo(300));
      await tap(tester, find.byKey(const Key('player-playlist')));
      await scrollPanelTo(tester, find.byKey(const Key('episode-1')));
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('episode-1')));
      expect(page.fixture.controller.index, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Desktop subtitle minimum reaches the bottom after controls hide',
    (tester) async {
      final page = await render(tester, size: const Size(1280, 800));
      await page.fixture.controller.updatePreferences(
        page.fixture.controller.preferences.copyWith(subtitleBottom: 0),
      );
      await tester.pump();
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      final caption = tester.getRect(find.byKey(const Key('player-captions')));
      expect(caption.bottom, closeTo(800, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Desktop subtitle size reaches 120 and is persisted', (
    tester,
  ) async {
    final page = await render(tester, size: const Size(1920, 1080));
    await openSetting(tester, '字幕');
    final slider = find.byKey(const Key('player-subtitle-size'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final track = tester.widget<Slider>(slider);
    expect(track.max, 120);
    track.onChanged!(120);
    await tester.pumpAndSettle();
    tester.widget<Slider>(slider).onChangeEnd!(120);
    await tester.pumpAndSettle();
    expect(page.fixture.controller.preferences.subtitleSize, 120);
    expect(page.fixture.history.preferences.subtitleSize, 120);
    expect(find.text('字幕字号  120'), findsOneWidget);
    await tap(tester, find.byTooltip('关闭面板'));
    final captions = tester.widgetList<SubtitleCaption>(
      find.byType(SubtitleCaption),
    );
    expect(captions.any((caption) => caption.size == 120), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Desktop subtitle panel previews the real lowest position', (
    tester,
  ) async {
    final page = await render(tester, size: const Size(1280, 800));
    await openSetting(tester, '字幕');
    final slider = find.byKey(const Key('player-subtitle-position'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final track = tester.widget<Slider>(slider);
    track.onChanged!(0);
    track.onChangeEnd!(0);
    await tester.pumpAndSettle();
    expect(page.fixture.controller.preferences.subtitleBottom, 0);
    expect(find.text('字幕位置  距底部 0%'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('player-captions'))).bottom,
      closeTo(800, 1),
    );
    expect(
      find.byKey(const Key('player-play-pause')).hitTestable(),
      findsNothing,
    );
    await tap(tester, find.byTooltip('关闭面板'));
    expect(
      find.byKey(const Key('player-play-pause')).hitTestable(),
      findsOneWidget,
    );
  });

  for (final size in [
    const Size(393, 864),
    const Size(1280, 800),
    const Size(844, 390),
  ]) {
    testWidgets(
      'Subtitle background can be customized and remembered at $size',
      (tester) async {
        final page = await render(tester, size: size);
        await openSetting(tester, '字幕');
        final panelScroll = find
            .descendant(
              of: find.byKey(const Key('player-panel')),
              matching: find.byType(Scrollable),
            )
            .last;
        await tester.scrollUntilVisible(
          find.text('自定义'),
          150,
          scrollable: panelScroll,
        );
        await tester.pumpAndSettle();
        await tap(tester, find.text('自定义'));
        await tester.ensureVisible(find.text('选择颜色'));
        await tester.pumpAndSettle();
        await tap(tester, find.text('选择颜色'));
        final hex = find.byKey(const Key('subtitle-background-hex'));
        await tester.ensureVisible(hex);
        await tester.enterText(hex, 'invalid');
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
              .onPressed,
          isNull,
        );
        await tester.enterText(hex, '#245A80');
        await tester.pump();
        await tap(tester, find.text('确定'));
        final slider = find.byKey(
          const Key('subtitle-background-transparency'),
        );
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        final track = tester.widget<Slider>(slider);
        track.onChanged!(.25);
        await tester.pump();
        tester.widget<Slider>(slider).onChangeEnd!(.25);
        await tester.pumpAndSettle();
        expect(
          page.fixture.history.preferences.subtitleBackgroundArgb,
          0xbf245a80,
        );
        final caption = tester.widget<SubtitleCaption>(
          find.ancestor(
            of: find.byKey(const Key('player-captions')),
            matching: find.byType(SubtitleCaption),
          ),
        );
        expect(caption.backgroundColor, 0xbf245a80);
        await tap(tester, find.byTooltip('关闭面板'));
        await openSetting(tester, '字幕');
        await tester.scrollUntilVisible(
          find.text('选择颜色'),
          150,
          scrollable: panelScroll,
        );
        await tester.pumpAndSettle();
        await tap(tester, find.text('选择颜色'));
        expect(tester.widget<TextField>(hex).controller!.text, '#245A80');
        await tester.ensureVisible(hex);
        await tester.enterText(hex, '#ffffff');
        await tap(tester, find.text('取消'));
        expect(
          page.fixture.history.preferences.subtitleBackgroundArgb,
          0xbf245a80,
        );
        await tester.ensureVisible(find.text('无底色'));
        await tester.pumpAndSettle();
        await tap(tester, find.text('无底色'));
        expect(page.fixture.history.preferences.subtitleBackgroundArgb, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Confirmed single-tap fade retains controls through system-inset changes',
    (tester) async {
      tester.view.padding = FakeViewPadding(top: 24, bottom: 20);
      tester.view.viewPadding = FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final page = await render(tester);
      final top = find.byKey(
        const Key('player-top-controls'),
        skipOffstage: false,
      );
      final element = tester.element(top), topRect = tester.getRect(top);
      final caption = find.byKey(const Key('player-captions'));
      final initialCaption = tester.getRect(caption);
      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(page.device.barsVisible, isFalse);
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 16));
      double opacity() => tester
          .widget<FadeTransition>(
            find.byKey(const Key('player-controls-fade'), skipOffstage: false),
          )
          .opacity
          .value;
      expect(opacity(), allOf(greaterThan(0), lessThan(1)));
      expect(tester.element(top), same(element));
      expect(tester.getRect(caption).top, greaterThan(initialCaption.top));
      tester.view.padding = FakeViewPadding();
      tester.view.viewPadding = FakeViewPadding();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(top), topRect);
      await tester.pump(const Duration(milliseconds: 180));
      expect(opacity(), 0);
      expect(tester.element(top), same(element));
      expect(find.byKey(const Key('player-top-controls')), findsNothing);
      expect(tester.getRect(caption).top, greaterThan(initialCaption.top));
    },
  );

  testWidgets(
    'Pausing during the control fade reverses from the current opacity',
    (tester) async {
      final page = await render(tester);
      double opacity() => tester
          .widget<FadeTransition>(
            find.byKey(const Key('player-controls-fade'), skipOffstage: false),
          )
          .opacity
          .value;
      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final fading = opacity();
      expect(fading, allOf(greaterThan(0), lessThan(1)));
      await page.fixture.controller.pause();
      await tester.pump();
      expect(opacity(), closeTo(fading, .01));
      await tester.pump(const Duration(milliseconds: 32));
      expect(opacity(), greaterThan(fading));
      expect(page.fixture.current.state.playing, isFalse);
      await tester.pumpAndSettle();
      expect(opacity(), 1);
    },
  );

  testWidgets(
    'Progress events rebuild the seek bar without rebuilding top controls or syncing system bars',
    (tester) async {
      final page = await render(tester);
      final top = tester.widget(find.byKey(const Key('player-top-controls')));
      final deviceUpdates = page.device.updates;
      for (var i = 0; i < 12; i++) {
        page.fixture.current.emit(
          page.fixture.current.state.copyWith(
            position: Duration(seconds: 130 + i),
            buffer: Duration(seconds: 190 + i),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester.widget(find.byKey(const Key('player-top-controls'))),
        same(top),
      );
      expect(page.device.updates, deviceUpdates);
      expect(
        tester.widget<Slider>(find.byKey(const Key('player-seek'))).value,
        141000,
      );
    },
  );

  testWidgets('Desktop seek hover shows the target playback time', (
    tester,
  ) async {
    await render(tester, size: const Size(1100, 780));
    final slider = find.byKey(const Key('player-seek'));
    final rect = tester.getRect(slider);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(Offset(rect.left + rect.width * .5, rect.center.dy));
    await tester.pump();
    expect(find.byKey(const Key('player-seek-hover-time')), findsOneWidget);
    expect(find.text('05:00'), findsOneWidget);

    await mouse.moveTo(Offset(rect.left + rect.width * .75, rect.center.dy));
    await tester.pump();
    expect(find.text('07:30'), findsOneWidget);

    await mouse.moveTo(const Offset(10, 10));
    await tester.pump();
    expect(find.byKey(const Key('player-seek-hover-time')), findsNothing);
    await mouse.removePointer();
  });

  testWidgets(
    'Reduced-motion preferences hide controls without leaving an animated overlay',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final page = await render(tester);
      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.byKey(const Key('player-top-controls')), findsNothing);
      expect(page.device.barsVisible, isFalse);
      final fade = tester.widget<FadeTransition>(
        find.byKey(const Key('player-controls-fade'), skipOffstage: false),
      );
      expect(fade.opacity.value, 0);
    },
  );

  for (final (size, scale) in [
    (const Size(320, 700), 1.8),
    (const Size(393, 864), 1.0),
    (const Size(844, 390), 1.0),
  ]) {
    testWidgets(
      'Rotation button fits the player at $size and text scale $scale',
      (tester) async {
        await render(
          tester,
          size: size,
          scale: scale,
          suppliedDevice: FakePlaybackDevice()..supportsOrientation = true,
        );
        for (final key in [
          'player-orientation',
          'player-play-pause',
          'player-fullscreen',
        ]) {
          final button = find.byKey(Key(key));
          expect(button.hitTestable(), findsOneWidget);
          expect(tester.getRect(button).right, lessThanOrEqualTo(size.width));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Rotation button preserves playback and overrides automatic video direction',
    (tester) async {
      final page = await render(
        tester,
        size: const Size(844, 390),
        suppliedDevice: FakePlaybackDevice()..supportsOrientation = true,
      );
      final backend = page.fixture.current;
      final position = backend.state.position;
      final preparations = page.fixture.preparations;
      final rotation = find.byKey(const Key('player-orientation'));
      expect(find.byTooltip('切换竖屏'), findsOneWidget);
      await tester.tap(rotation);
      await tester.pump();
      expect(page.device.orientation, PlaybackOrientation.portrait);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      expect(find.byTooltip('切换横屏'), findsOneWidget);
      expect(backend.state.playing, isTrue);
      expect(backend.state.position, position);
      expect(page.fixture.history.preferences.autoRotate, isTrue);
      await page.fixture.controller.pause();
      await tester.pump();
      expect(page.device.orientation, PlaybackOrientation.portrait);
      await page.fixture.controller.play();
      await tester.pumpAndSettle();
      backend.emit(backend.state.copyWith(width: 1024, height: 576));
      await tester.pump();
      expect(page.device.orientation, PlaybackOrientation.portrait);
      await tap(tester, find.byKey(const Key('player-lock')));
      expect(page.device.orientationLocked, isTrue);
      expect(rotation.hitTestable(), findsNothing);
      await tap(tester, find.byKey(const Key('player-unlock')));
      expect(page.device.orientation, PlaybackOrientation.portrait);
      await tester.tap(rotation);
      await tester.pump();
      expect(page.device.orientation, PlaybackOrientation.landscape);
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      expect(find.byTooltip('切换竖屏'), findsOneWidget);
      expect(page.fixture.current, same(backend));
      expect(page.fixture.preparations, preparations);
      expect(backend.state.position, position);
      await tap(tester, find.byTooltip('播放设置'));
      final automatic = find.text('自动适配视频方向');
      await scrollPanelTo(tester, automatic);
      await tap(tester, automatic);
      expect(page.device.orientation, PlaybackOrientation.system);
      await tap(tester, automatic);
      expect(page.device.orientation, PlaybackOrientation.landscape);
      await tap(tester, find.byTooltip('关闭面板'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Video switches, screen locking and automatic direction setting reach the device',
    (tester) async {
      final page = await render(tester);
      expect(page.device.orientation, PlaybackOrientation.landscape);
      await tap(tester, find.byKey(const Key('player-lock')));
      expect(page.device.orientationLocked, isTrue);
      await tap(tester, find.byKey(const Key('player-unlock')));
      expect(page.device.orientationLocked, isFalse);
      page.fixture.configureBackend = (backend) =>
          backend.emit(backend.state.copyWith(width: 1080, height: 1920));
      await openSetting(tester, '选集');
      await tap(tester, find.byKey(const Key('episode-1')));
      expect(page.device.orientation, PlaybackOrientation.portrait);
      expect(page.fixture.controller.index, 1);
      await tap(tester, find.byTooltip('播放设置'));
      await tap(tester, find.text('自动适配视频方向'));
      expect(page.device.orientation, PlaybackOrientation.system);
      expect(page.fixture.history.preferences.autoRotate, isFalse);
      await tap(tester, find.text('自动适配视频方向'));
      expect(page.device.orientation, PlaybackOrientation.portrait);
      expect(page.fixture.history.preferences.autoRotate, isTrue);
      await tap(tester, find.byTooltip('关闭面板'));
    },
  );

  testWidgets(
    'Playback connections update immediately and persist across episodes',
    (tester) async {
      final page = await render(tester);
      expect(page.fixture.current.connections, 8);
      await tap(tester, find.byTooltip('播放设置'));
      final choice = find.byKey(const Key('player-connections-16'));
      await scrollPanelTo(tester, choice);
      await tap(tester, choice);
      expect(page.fixture.current.connections, 16);
      expect(page.fixture.history.preferences.connections, 16);
      await tap(tester, find.byTooltip('关闭面板'));
      await openSetting(tester, '选集');
      await tap(tester, find.byKey(const Key('episode-1')));
      expect(page.fixture.current.connections, 16);
      expect(page.fixture.controller.index, 1);
    },
  );

  testWidgets(
    'Quark defaults to 128 and custom playback connections validate and persist per drive',
    (tester) async {
      final page = await render(
        tester,
        suppliedFixture: PlaybackFixture(
          platforms: [
            CloudPlatform.quark,
            CloudPlatform.uc,
            CloudPlatform.quark,
          ],
        ),
      );
      expect(page.fixture.current.connections, 128);
      await tap(tester, find.byTooltip('播放设置'));
      final preset = find.byKey(const Key('player-connections-128'));
      await scrollPanelTo(tester, preset);
      expect(tester.widget<ChoiceChip>(preset).selected, isTrue);
      final custom = find.byKey(const Key('player-connections-custom'));
      await scrollPanelTo(tester, custom);
      await tap(tester, custom);
      final input = find.byKey(const Key('player-custom-connections'));
      final apply = find.byKey(const Key('player-apply-custom-connections'));
      expect(tester.widget<TextField>(input).controller!.text, '128');
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile('goldens/player-custom-connections.png'),
      );
      for (final invalid in ['0', '513', '1.5', 'abc', '']) {
        await tester.enterText(input, invalid);
        await tap(tester, apply);
        expect(find.text('请输入 1 至 512 之间的整数'), findsOneWidget);
        expect(page.fixture.current.connections, 128);
      }
      await tester.enterText(input, '96');
      await tap(tester, apply);
      expect(page.fixture.current.connections, 96);
      expect(
        page.fixture.history.preferences.connectionsFor(CloudPlatform.quark),
        96,
      );
      await openSetting(tester, '选集');
      await tap(tester, find.byKey(const Key('episode-1')));
      expect(page.fixture.current.connections, 8);
      await openSetting(tester, '选集');
      await tap(tester, find.byKey(const Key('episode-2')));
      expect(page.fixture.current.connections, 96);
      await tap(tester, find.byTooltip('播放设置'));
      await scrollPanelTo(tester, custom);
      expect(find.text('自定义 · 96'), findsOneWidget);
      await tap(tester, custom);
      expect(tester.widget<TextField>(input).controller!.text, '96');
    },
  );

  for (final (size, scale) in [
    (const Size(320, 700), 1.8),
    (const Size(844, 390), 1.0),
    (const Size(1100, 780), 1.0),
  ]) {
    testWidgets('Custom connections fit $size at text scale $scale', (
      tester,
    ) async {
      await render(tester, size: size, scale: scale);
      await tap(tester, find.byTooltip('播放设置'));
      final custom = find.byKey(const Key('player-connections-custom'));
      await scrollPanelTo(tester, custom);
      await tap(tester, custom);
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('player-custom-connections'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '256');
      final apply = find.byKey(const Key('player-apply-custom-connections'));
      await tester.ensureVisible(apply);
      await tap(tester, apply);
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Secondary controls live in settings and landscape overlays leave the center clear',
    (tester) async {
      await render(tester, size: const Size(844, 390));
      for (final label in ['音轨', '字幕', '画面']) {
        expect(find.text(label), findsNothing);
      }
      final top = tester.getRect(find.byKey(const Key('player-top-controls')));
      final bottom = tester.getRect(
        find.byKey(const Key('player-bottom-controls')),
      );
      expect(top.bottom, lessThan(150));
      expect(bottom.top, greaterThan(240));
      expect(bottom.height, lessThan(140));
      expect(
        find.byKey(const Key('player-playlist')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.getCenter(find.byKey(const Key('player-playlist'))).dy,
        greaterThan(bottom.top),
      );
      await openSetting(tester, '画面');
      expect(find.text('适应画面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Track headers rotate before autoplay and the cover waits for stable layout',
    (tester) async {
      final fixture = PlaybackFixture(),
          device = FakePlaybackDevice()..supportsOrientation = true;
      fixture.configureBackend = (backend) => backend.emit(
        const PlayerState(
          tracks: Tracks(
            video: [VideoTrack('1', null, null, w: 1920, h: 1080)],
          ),
        ),
      );
      await render(
        tester,
        suppliedFixture: fixture,
        suppliedDevice: device,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(device.orientation, PlaybackOrientation.landscape);
      expect(fixture.current.state.width, isNull);
      expect(fixture.current.plays, 0);
      expect(find.byKey(const Key('player-layout-cover')), findsOneWidget);
      tester.view.physicalSize = const Size(864, 393);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      expect(fixture.current.plays, 1);
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      expect(tester.takeException(), isNull);
      fixture.current.emit(
        const PlayerState(
          playing: true,
          videoParams: VideoParams(dw: 1920, dh: 1080, rotate: 90),
        ),
      );
      await tester.pump();
      expect(device.orientation, PlaybackOrientation.portrait);
      expect(find.byKey(const Key('player-layout-cover')), findsOneWidget);
      tester.view.physicalSize = const Size(393, 864);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A platform refusing rotation cannot hold playback behind a permanent cover',
    (tester) async {
      final device = FakePlaybackDevice()..supportsOrientation = true;
      final page = await render(tester, suppliedDevice: device, settle: false);
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      expect(page.fixture.current.plays, 1);
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      page.fixture.current.emit(
        page.fixture.current.state.copyWith(
          position: const Duration(seconds: 3),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Closing while Android is rotating cancels pending presentation work',
    (tester) async {
      final device = FakePlaybackDevice()..supportsOrientation = true;
      final page = await render(tester, suppliedDevice: device, settle: false);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(page.fixture.controller.closed, isTrue);
      expect(device.finished, isTrue);
      expect(page.fixture.current.plays, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Single taps toggle controls and double taps pause and resume without overlays',
    (tester) async {
      final page = await render(tester), backend = page.fixture.current;
      final initialVolumeWrites = backend.volumes.length;
      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-play-pause')), findsNothing);
      expect(backend.volumes.length, initialVolumeWrites);
      expect(backend.state.volume, 100);
      final position = backend.state.position;
      await tester.tapAt(const Offset(320, 300));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(320, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(backend.state.position, position);
      expect(backend.state.playing, isFalse);
      expect(backend.volumes.length, initialVolumeWrites);
      expect(find.byKey(const Key('player-top-controls')), findsNothing);
      expect(find.byKey(const Key('player-bottom-controls')), findsNothing);
      expect(find.byTooltip('播放设置'), findsNothing);
      expect(page.device.barsVisible, isFalse);
      await tester.tapAt(const Offset(320, 300));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(320, 300));
      await tester.pumpAndSettle();
      expect(backend.state.playing, isTrue);
      expect(backend.state.position, position);
      expect(find.byKey(const Key('player-top-controls')), findsNothing);
      expect(find.byKey(const Key('player-bottom-controls')), findsNothing);
      expect(page.device.barsVisible, isFalse);
      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-play-pause')), findsOneWidget);
      expect(find.byTooltip('播放设置'), findsOneWidget);
      expect(page.device.barsVisible, isTrue);
    },
  );

  testWidgets(
    'Double tapping with visible controls hides them while preserving the paused frame',
    (tester) async {
      final page = await render(tester);
      final backend = page.fixture.current;
      final position = backend.state.position;
      final preparations = page.fixture.preparations;
      expect(find.byKey(const Key('player-play-pause')), findsOneWidget);
      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(196, 300));
      await tester.pump();
      expect(backend.state.playing, isFalse);
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsNothing,
      );
      expect(page.device.barsVisible, isFalse);
      await tester.pumpAndSettle();
      final captions = tester.getRect(find.byKey(const Key('player-captions')));
      backend.emit(backend.state.copyWith(buffer: const Duration(minutes: 3)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const Key('player-top-controls')), findsNothing);
      expect(find.byKey(const Key('player-bottom-controls')), findsNothing);
      expect(find.byTooltip('播放设置'), findsNothing);
      expect(page.device.barsVisible, isFalse);
      expect(
        tester.getRect(find.byKey(const Key('player-captions'))),
        captions,
      );
      expect(backend.state.position, position);
      expect(page.fixture.current, same(backend));
      expect(page.fixture.preparations, preparations);
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> openSkipSettings(WidgetTester tester) async {
    await tap(tester, find.byTooltip('播放设置'));
    await scrollPanelTo(tester, find.byKey(const Key('player-skip-settings')));
    await tap(tester, find.text('跳过片头片尾'));
  }

  for (final (size, scale, playing) in [
    (const Size(393, 864), 1.0, true),
    (const Size(844, 390), 1.0, true),
    (const Size(320, 700), 1.8, false),
  ]) {
    testWidgets(
      'Skip capture uses the latest timeline and remembers the folder at $size',
      (tester) async {
        final fixture = PlaybackFixture(
          suppliedEntries: [
            for (var index = 0; index < 2; index++)
              PlaybackEntry(
                id: '$index',
                key: 'skip-capture-$index',
                name: '第 ${index + 1} 集.mkv',
                video: true,
                settingsFolder: 'skip-capture-show',
              ),
          ],
        );
        final page = await render(
          tester,
          size: size,
          scale: scale,
          suppliedFixture: fixture,
        );
        final backend = fixture.current;
        if (!playing) {
          await fixture.controller.pause();
          await tester.pump();
        }
        final preparations = fixture.preparations;
        final seeks = backend.seeks.length;
        final plays = backend.plays;
        final pauses = backend.pauses;
        await openSkipSettings(tester);
        backend.emit(
          backend.state.copyWith(position: const Duration(milliseconds: 83945)),
        );
        await tester.pump();
        final captureIntro = find.byKey(const Key('player-capture-skip-intro'));
        await scrollPanelTo(tester, captureIntro);
        expect(captureIntro.hitTestable(), findsOneWidget);
        await tap(tester, captureIntro);
        expect(fixture.controller.preferences.skipIntroSeconds, 83);
        expect(fixture.controller.preferences.skipOutroSeconds, 0);
        expect(
          fixture.history.preferencesFor('skip-capture-show').skipIntroSeconds,
          83,
        );
        expect(fixture.history.preferences.skipIntroSeconds, 0);
        expect(
          tester
              .widget<Slider>(find.byKey(const Key('player-skip-intro')))
              .value,
          83,
        );
        backend.emit(
          backend.state.copyWith(position: const Duration(seconds: 503)),
        );
        await tester.pump();
        final captureOutro = find.byKey(const Key('player-capture-skip-outro'));
        await scrollPanelTo(tester, captureOutro);
        expect(captureOutro.hitTestable(), findsOneWidget);
        await tap(tester, captureOutro);
        expect(fixture.controller.preferences.skipIntroSeconds, 83);
        expect(fixture.controller.preferences.skipOutroSeconds, 97);
        expect(
          fixture.history.preferencesFor('skip-capture-show').skipOutroSeconds,
          97,
        );
        expect(fixture.history.preferences.skipOutroSeconds, 0);
        expect(
          tester
              .widget<Slider>(find.byKey(const Key('player-skip-outro')))
              .value,
          97,
        );
        expect(backend.state.position, const Duration(seconds: 503));
        expect(backend.state.playing, playing);
        expect(backend.plays, plays);
        expect(backend.pauses, pauses);
        expect(backend.seeks.length, seeks);
        expect(fixture.preparations, preparations);
        expect(fixture.current, same(backend));
        expect(find.byKey(const Key('player-panel')), findsOneWidget);
        await tap(tester, find.byTooltip('关闭面板'));
        await fixture.controller.next();
        await tester.pumpAndSettle();
        expect(fixture.controller.preferences.skipIntroSeconds, 83);
        expect(fixture.controller.preferences.skipOutroSeconds, 97);
        expect(fixture.current.seeks, contains(const Duration(seconds: 83)));
        expect(page.device.started, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Skip capture is disabled without duration and clamps positions to the timeline',
    (tester) async {
      final page = await render(
        tester,
        suppliedFixture: PlaybackFixture(
          data: {
            'playbackPreferences': {
              'skipIntroSeconds': 15,
              'skipOutroSeconds': 20,
            },
          },
        ),
      );
      final controller = page.fixture.controller;
      final backend = page.fixture.current;
      await controller.pause();
      backend.emit(backend.state.copyWith(duration: Duration.zero));
      await tester.pump();
      await openSkipSettings(tester);
      final captureIntro = find.byKey(const Key('player-capture-skip-intro'));
      final captureOutro = find.byKey(const Key('player-capture-skip-outro'));
      for (final button in [captureIntro, captureOutro]) {
        await scrollPanelTo(tester, button);
        expect(tester.widget<TextButton>(button).onPressed, isNull);
      }
      expect(controller.preferences.skipIntroSeconds, 15);
      expect(controller.preferences.skipOutroSeconds, 20);
      backend.emit(
        backend.state.copyWith(
          duration: const Duration(minutes: 10),
          position: Duration.zero,
        ),
      );
      await tester.pump();
      await scrollPanelTo(tester, captureIntro);
      expect(tester.widget<TextButton>(captureIntro).onPressed, isNotNull);
      await tap(tester, captureIntro);
      expect(page.fixture.history.preferences.skipIntroSeconds, 0);
      backend.emit(
        backend.state.copyWith(position: const Duration(minutes: 12)),
      );
      await tester.pump();
      await tap(tester, captureIntro);
      expect(page.fixture.history.preferences.skipIntroSeconds, 600);
      await scrollPanelTo(tester, captureOutro);
      await tap(tester, captureOutro);
      expect(page.fixture.history.preferences.skipOutroSeconds, 0);
      backend.emit(
        backend.state.copyWith(position: const Duration(seconds: -1)),
      );
      await tester.pump();
      expect(tester.widget<TextButton>(captureIntro).onPressed, isNull);
      expect(tester.widget<TextButton>(captureOutro).onPressed, isNull);
      expect(backend.state.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Skip capture rejects values above 600 seconds and accepts the exact limit',
    (tester) async {
      final page = await render(
        tester,
        suppliedFixture: PlaybackFixture(
          data: {
            'playbackPreferences': {
              'skipIntroSeconds': 11,
              'skipOutroSeconds': 17,
            },
          },
        ),
      );
      final controller = page.fixture.controller;
      final backend = page.fixture.current;
      await controller.pause();
      backend.emit(
        backend.state.copyWith(
          duration: const Duration(minutes: 30),
          position: const Duration(seconds: 650),
        ),
      );
      await tester.pump();
      await openSkipSettings(tester);
      final captureIntro = find.byKey(const Key('player-capture-skip-intro'));
      final captureOutro = find.byKey(const Key('player-capture-skip-outro'));
      await scrollPanelTo(tester, captureIntro);
      await tap(tester, captureIntro);
      expect(find.text('片头最多支持 600 秒，请调整播放位置后再捕获'), findsOneWidget);
      expect(page.fixture.history.preferences.skipIntroSeconds, 11);
      await scrollPanelTo(tester, captureOutro);
      await tap(tester, captureOutro);
      expect(find.text('片尾最多支持 600 秒，请调整播放位置后再捕获'), findsOneWidget);
      expect(page.fixture.history.preferences.skipOutroSeconds, 17);
      backend.emit(
        backend.state.copyWith(position: const Duration(minutes: 10)),
      );
      await tester.pump();
      await scrollPanelTo(tester, captureIntro);
      await tap(tester, captureIntro);
      expect(page.fixture.history.preferences.skipIntroSeconds, 600);
      backend.emit(
        backend.state.copyWith(position: const Duration(minutes: 20)),
      );
      await tester.pump();
      await scrollPanelTo(tester, captureOutro);
      await tap(tester, captureOutro);
      expect(page.fixture.history.preferences.skipOutroSeconds, 600);
      expect(backend.state.position, const Duration(minutes: 20));
      expect(backend.state.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Progress, brightness and volume gestures act on the intended control',
    (tester) async {
      final page = await render(tester), backend = page.fixture.current;
      await tester.dragFrom(const Offset(160, 300), const Offset(110, 0));
      await tester.pumpAndSettle();
      expect(backend.state.position.inSeconds, greaterThan(120));
      expect(backend.state.position.inSeconds, lessThan(160));
      final oldVolume = backend.state.volume;
      await tester.dragFrom(const Offset(90, 400), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(page.device.brightness, greaterThan(.5));
      expect(backend.state.volume, oldVolume);
      await tester.dragFrom(const Offset(310, 350), const Offset(0, 160));
      await tester.pumpAndSettle();
      expect(backend.state.volume, lessThan(oldVolume));
      expect(page.fixture.history.preferences.volume, backend.state.volume);
    },
  );

  testWidgets(
    'Long press restores the chosen speed and locking prevents gesture actions',
    (tester) async {
      final page = await render(tester), backend = page.fixture.current;
      await tap(tester, find.byKey(const Key('player-speed')));
      await tap(tester, find.byKey(const ValueKey('player-rate-1.5')));
      expect(backend.state.rate, 1.5);
      final gesture = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      expect(backend.state.rate, 2);
      await gesture.up();
      await tester.pump();
      expect(backend.state.rate, 1.5);
      await tap(tester, find.byKey(const Key('player-lock')));
      expect(find.byKey(const Key('player-play-pause')), findsNothing);
      final position = backend.state.position;
      await tester.tapAt(const Offset(320, 300));
      await tester.dragFrom(const Offset(160, 300), const Offset(110, 0));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(backend.state.position, position);
      expect(backend.state.playing, isTrue);
      await tap(tester, find.byKey(const Key('player-unlock')));
      expect(find.byKey(const Key('player-play-pause')), findsOneWidget);
    },
  );

  testWidgets('Custom fractional rate is validated, applied and remembered', (
    tester,
  ) async {
    final page = await render(tester);
    await tap(tester, find.byKey(const Key('player-speed')));
    final input = find.byKey(const Key('player-custom-rate'));
    await expectLater(
      find.byKey(const Key('player-capture')),
      matchesGoldenFile('goldens/player-custom-rate.png'),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(input);
    await tester.enterText(input, '0');
    await tester.ensureVisible(
      find.byKey(const Key('player-apply-custom-rate')),
    );
    await tap(tester, find.byKey(const Key('player-apply-custom-rate')));
    expect(find.text('请输入 0.25 至 4 之间的倍速'), findsOneWidget);
    expect(page.fixture.current.state.rate, 1);
    await tester.enterText(input, '2.37');
    await tester.ensureVisible(
      find.byKey(const Key('player-apply-custom-rate')),
    );
    await tap(tester, find.byKey(const Key('player-apply-custom-rate')));
    expect(page.fixture.current.state.rate, 2.37);
    expect(page.fixture.history.preferences.rate, 2.37);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('player-speed')));
    expect(tester.widget<TextField>(input).controller!.text, '2.37');
    await tap(tester, find.byTooltip('关闭面板'));
  });

  testWidgets('Locked screen tap briefly reveals the icon without a text HUD', (
    tester,
  ) async {
    final page = await render(tester);
    await tap(tester, find.byKey(const Key('player-lock')));
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-unlock')).hitTestable(), findsNothing);
    await tester.tapAt(const Offset(196, 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('player-unlock')).hitTestable(),
      findsOneWidget,
    );
    expect(find.textContaining('解锁'), findsNothing);
    expect(find.textContaining('解除屏幕锁定'), findsNothing);
    expect(page.fixture.current.state.playing, isTrue);
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.tapAt(const Offset(196, 300));
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      find.byKey(const Key('player-unlock')).hitTestable(),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-unlock')).hitTestable(), findsNothing);
  });

  testWidgets('Holding boost keeps the speed without persistent text', (
    tester,
  ) async {
    final page = await render(tester);
    final gesture = await tester.startGesture(const Offset(196, 300));
    await tester.pump(const Duration(milliseconds: 700));
    expect(page.fixture.current.state.rate, 2);
    expect(find.textContaining('倍速播放中'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(page.fixture.current.state.rate, 2);
    expect(find.textContaining('倍速播放中'), findsNothing);
    expect(find.textContaining('松手恢复'), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(page.fixture.current.state.rate, 1);
  });

  testWidgets(
    'A missing subtitle font can be retried without interrupting playback',
    (tester) async {
      final page = await render(tester);
      page.fixture.current.subtitleFontMessage = '中文字幕字体未就绪，请在字幕设置中重试';
      page.fixture.current.emit(page.fixture.current.state);
      await tester.pump();
      expect(page.fixture.controller.ready, isTrue);
      expect(page.fixture.current.state.playing, isTrue);
      await openSetting(tester, '字幕');
      await tester.ensureVisible(find.text('点此重试下载中文字幕字体'));
      await tap(tester, find.text('点此重试下载中文字幕字体'));
      expect(page.fixture.current.subtitleFontRetries, 1);
      expect(page.fixture.current.subtitleFontMessage, isEmpty);
      expect(page.fixture.controller.error, isEmpty);
      expect(page.fixture.current.state.playing, isTrue);
    },
  );

  testWidgets('Track, caption and episode panels use the selected ids', (
    tester,
  ) async {
    final page = await render(tester);
    await openSetting(tester, '音轨');
    await tap(tester, find.text('English · 英语'));
    expect(page.fixture.current.state.track.audio.id, '2');
    await tap(tester, find.text('延后 0.5 秒'));
    expect(page.fixture.current.audioDelay, .5);
    await tap(tester, find.byTooltip('关闭面板'));
    await openSetting(tester, '字幕');
    await tap(tester, find.text('关闭字幕'));
    expect(page.fixture.current.state.track.subtitle.id, 'no');
    await tap(tester, find.text('简体中文 · 中文'));
    expect(page.fixture.current.state.track.subtitle.id, '1');
    await tap(tester, find.byTooltip('关闭面板'));
    await openSetting(tester, '选集');
    await tap(tester, find.byKey(const Key('episode-2')));
    expect(page.fixture.controller.index, 2);
    expect(page.fixture.backends.first.closed, isTrue);
    expect(page.fixture.leases.values.where((n) => n == 0).length, 1);
  });

  testWidgets(
    'Subtitle import reads a private copy and exit preserves the original',
    (tester) async {
      final original = File('test/fixtures/player-external.srt').absolute;
      final page = await render(
        tester,
        chooseSubtitle: () async => XFile(original.path),
      );
      // File I/O uses the real clock; the serialized subtitle commands and
      // widget frames also need the test clock to drain their microtasks.
      Future<void> drainFileWork(bool Function() complete) async {
        for (var attempt = 0; attempt < 100 && !complete(); attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(complete(), isTrue);
      }

      await openSetting(tester, '字幕');
      await tester.tap(find.text('加载字幕文件'));
      await drainFileWork(() => page.fixture.current.state.track.subtitle.uri);
      await tester.pumpAndSettle();
      final staged = File.fromUri(
        Uri.parse(page.fixture.current.state.track.subtitle.id),
      );
      expect(staged.parent.path, page.directory.path);
      await tester.runAsync(() async {
        expect(await staged.readAsBytes(), await original.readAsBytes());
      });
      await tap(tester, find.byTooltip('返回'));
      var closed = false;
      unawaited(page.fixture.controller.close().then((_) => closed = true));
      await drainFileWork(() => closed);
      await tester.pumpAndSettle();
      expect(find.text('播放器已关闭'), findsOneWidget);
      expect(page.device.finished, isTrue);
      expect(await tester.runAsync(staged.exists), isFalse);
      expect(await tester.runAsync(original.exists), isTrue);
    },
  );

  testWidgets(
    'PiP hides Flutter controls, forwards actions and pauses when hidden',
    (tester) async {
      final page = await render(tester), backend = page.fixture.current;
      await tap(tester, find.byTooltip('画中画'));
      expect(find.byKey(const Key('player-gesture-surface')), findsNothing);
      expect(find.byKey(const Key('player-play-pause')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(backend.state.playing, isTrue);
      page.device.events.add('forward');
      await tester.pump();
      expect(backend.state.position, const Duration(seconds: 135));
      page.device.events.add('toggle');
      await tester.pump();
      expect(backend.state.playing, isFalse);
      page.device.events.add('toggle');
      await tester.pump();
      expect(backend.state.playing, isTrue);
      page.device.events.add('hidden');
      await tester.pump();
      expect(backend.state.playing, isFalse);
      page.device.leavePip();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-play-pause')), findsOneWidget);
    },
  );

  testWidgets(
    'Escape restores fullscreen before leaving and closes the native session',
    (tester) async {
      final page = await render(tester);
      await tap(tester, find.byKey(const Key('player-fullscreen')));
      expect(page.device.full, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(page.device.full, isFalse);
      expect(find.byType(PlayerPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.runAsync(page.fixture.controller.close);
      expect(find.text('播放器已关闭'), findsOneWidget);
      expect(
        page.device.calls,
        containsAllInOrder(['fullscreen:true', 'fullscreen:false']),
      );
      expect(page.device.finished, isTrue);
      expect(page.fixture.leases.values, everyElement(0));
    },
  );

  testWidgets(
    'Narrow large-text panels and short landscape errors remain usable',
    (tester) async {
      final page = await render(tester, size: const Size(320, 640), scale: 1.8);
      for (final panel in ['音轨', '字幕', '选集', '画面']) {
        await openSetting(tester, panel);
        final scrolling = find
            .descendant(
              of: find.byKey(const Key('player-panel')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.drag(scrolling, const Offset(0, -450));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tap(tester, find.byTooltip('关闭面板'));
      }
      await tap(tester, find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tap(tester, find.byTooltip('关闭面板'));
      tester.view.physicalSize = const Size(640, 320);
      page.fixture.current.fail();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('刷新重试'));
      expect(find.text('刷新重试').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester, find.text('刷新重试'));
      expect(page.fixture.preparations, 2);
      expect(page.fixture.controller.error, isEmpty);
    },
  );

  testWidgets(
    'Playlist lazily renders a thousand entries, centers current and searches watched progress',
    (tester) async {
      final f = PlaybackFixture(
        initialIndex: 700,
        suppliedEntries: List.generate(
          1000,
          (i) => PlaybackEntry(
            id: '$i',
            key: '$i',
            name: '演示 第${i + 1}集.mp4',
            video: true,
            settingsFolder: 'show',
          ),
        ),
      );
      await f.history.save(
        '10',
        const PlaybackBookmark(
          position: Duration(minutes: 5),
          duration: Duration(minutes: 10),
          updatedAt: 1,
        ),
      );
      await render(tester, suppliedFixture: f);
      await openSetting(tester, '选集');
      expect(
        find.byKey(const Key('episode-700')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const Key('episode-0')), findsNothing);
      expect(find.byType(InkWell).evaluate().length, lessThan(80));
      await tester.enterText(
        find.byKey(const Key('player-episode-search')),
        '第11集',
      );
      await tester.pumpAndSettle();
      expect(find.text('已看 05:00 / 10:00'), findsOneWidget);
      await tap(tester, find.byKey(const Key('episode-10')));
      expect(f.controller.index, 10);
      expect(f.controller.entries.length, 1000);
      await openSetting(tester, '选集');
      await tap(tester, find.byKey(const Key('player-episode-order')));
      await tap(tester, find.text('集数倒序').last);
      expect(f.controller.index, 10);
      expect(f.controller.playlistIndices.first, 999);
      expect(find.byKey(const Key('episode-10')).hitTestable(), findsOneWidget);
      expect(f.history.orderFor('show'), PlaybackPlaylistOrder.descending);
    },
  );

  testWidgets(
    'Aspect presets and custom width-height validation work in a narrow player',
    (tester) async {
      final page = await render(tester, size: const Size(320, 700), scale: 1.4);
      await openSetting(tester, '画面');
      await tap(tester, find.byKey(const Key('player-aspect-4:3')));
      expect(page.fixture.controller.preferences.aspectRatio, 4 / 3);
      await tester.ensureVisible(find.byKey(const Key('player-aspect-width')));
      await tester.enterText(find.byKey(const Key('player-aspect-width')), '2');
      await tester.enterText(
        find.byKey(const Key('player-aspect-height')),
        '0',
      );
      await tester.ensureVisible(find.byKey(const Key('player-aspect-apply')));
      await tap(tester, find.byKey(const Key('player-aspect-apply')));
      expect(find.textContaining('请输入有效宽高'), findsOneWidget);
      expect(page.fixture.controller.preferences.aspectRatio, 4 / 3);
      await tester.enterText(
        find.byKey(const Key('player-aspect-height')),
        '1',
      );
      await tester.pumpAndSettle();
      await scrollPanelTo(tester, find.byKey(const Key('player-aspect-apply')));
      await tap(tester, find.byKey(const Key('player-aspect-apply')));
      expect(page.fixture.controller.preferences.aspectRatio, 2);
      expect(page.fixture.controller.preferences.fit, PlaybackFit.contain);
      expect(page.fixture.history.preferences.aspectRatio, 2);
      expect(page.fixture.controller.videoGeometry?.aspectRatio, 1920 / 1080);
    },
  );

  testWidgets(
    'Sleep panel supports preset, custom validation and cancellation on landscape',
    (tester) async {
      final page = await render(tester, size: const Size(844, 390));
      await openSetting(tester, '定时停止');
      await tap(tester, find.byKey(const Key('player-sleep-30')));
      expect(
        page.fixture.controller.sleepTimer.mode,
        PlaybackSleepMode.duration,
      );
      await tester.ensureVisible(find.byKey(const Key('player-sleep-minutes')));
      await tester.enterText(
        find.byKey(const Key('player-sleep-minutes')),
        '0',
      );
      await tester.ensureVisible(find.byKey(const Key('player-sleep-apply')));
      await tap(tester, find.byKey(const Key('player-sleep-apply')));
      expect(find.text('请输入 1 至 720 分钟'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('player-sleep-minutes')),
        '20',
      );
      await tester.ensureVisible(find.byKey(const Key('player-sleep-apply')));
      await tap(tester, find.byKey(const Key('player-sleep-apply')));
      expect(
        page.fixture.controller.sleepTimer.remaining!.inMinutes,
        inInclusiveRange(19, 20),
      );
      await tester.ensureVisible(find.byKey(const Key('player-sleep-cancel')));
      await tap(tester, find.byKey(const Key('player-sleep-cancel')));
      expect(page.fixture.controller.sleepTimer.mode, PlaybackSleepMode.off);
      expect(page.fixture.current.state.playing, isTrue);
    },
  );

  for (final (initiallyPlaying, stopDuringCapture) in [
    (true, false),
    (true, true),
    (false, false),
  ]) {
    testWidgets(
      'Screenshot exports the video frame with playing=$initiallyPlaying and timer stop=$stopDuringCapture',
      (tester) async {
        final f = PlaybackFixture();
        f.configureBackend = (backend) {
          backend.screenshotSupported = true;
          backend.nativeSubtitles = true;
          backend.screenshotBytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAFElEQVR4nGNwaDhAEmIY1TAoNAAA0JDYAfmWJooAAAAASUVORK5CYII=',
          );
        };
        final actions = _ScreenshotActions();
        await render(tester, suppliedFixture: f, screenshotActions: actions);
        if (!initiallyPlaying) {
          await f.controller.pause();
          await tester.pumpAndSettle();
        }
        await tap(tester, find.byKey(const Key('player-screenshot')));
        expect(f.current.state.playing, isFalse);
        expect(f.current.captures, [false]);
        await tap(tester, find.byKey(const Key('player-screenshot-subtitles')));
        expect(f.current.captures, [false, true]);
        await tap(tester, find.byKey(const Key('player-screenshot-save')));
        expect(actions.calls.single, startsWith('save:'));
        expect(actions.calls.single, endsWith('.png'));
        expect(find.text('已保存到 测试目录'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('player-screenshot-copy')),
        );
        await tap(tester, find.byKey(const Key('player-screenshot-copy')));
        expect(actions.calls, contains('copy'));
        await tester.ensureVisible(
          find.byKey(const Key('player-screenshot-share')),
        );
        await tap(tester, find.byKey(const Key('player-screenshot-share')));
        expect(actions.calls, contains('share'));
        if (stopDuringCapture) {
          f.controller.sleepTimer.schedule(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 2));
        }
        await tap(tester, find.byTooltip('关闭面板'));
        expect(f.current.state.playing, initiallyPlaying && !stopDuringCapture);
        expect(f.controller.sleepTimer.stopped, stopDuringCapture);
        if (!initiallyPlaying) {
          await tap(tester, find.byKey(const Key('player-screenshot')));
          expect(f.current.captures, [false, true, false]);
          await tap(tester, find.byTooltip('关闭面板'));
          expect(f.current.state.playing, isFalse);
        }
      },
    );
  }
}
