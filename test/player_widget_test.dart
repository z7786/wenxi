import 'dart:async';
import 'dart:io';
import 'package:asterlink/data/playback_store.dart';
import 'dart:convert';
import 'package:asterlink/playback/playback_state.dart';
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

class _CappedSystemVolumeDevice extends FakePlaybackDevice {
  _CappedSystemVolumeDevice() {
    supportsSystemVolume = true;
  }
  @override
  Future<double> setSystemVolume(double value) =>
      super.setSystemVolume(value.clamp(0, 70).toDouble());
}

class _SlowProgressStore extends PlaybackStore {
  _SlowProgressStore(super.store);
  Future<void>? barrier;
  int saves = 0;
  @override
  Future<void> save(String key, PlaybackBookmark bookmark) async {
    saves++;
    await barrier;
    await super.save(key, bookmark);
  }
}

class _SystemInsetsDevice extends FakePlaybackDevice {
  _SystemInsetsDevice() {
    supportsOrientation = true;
  }
  final insets = <Size, EdgeInsets>{};
  @override
  EdgeInsets? systemInsetsFor(MediaQueryData media) => insets[media.size];
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
              confirmDownload: confirmDownload == null
                  ? null
                  : (_) => confirmDownload(),
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

  Future<void> openMenuAction(WidgetTester tester, Finder action) async {
    await tap(tester, find.byKey(const Key('player-more')));
    await tester.ensureVisible(action);
    await tap(tester, action);
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
      await openMenuAction(tester, find.byKey(const Key('player-download')));
      expect(downloads, 0);
      decision.complete(false);
      await tester.pumpAndSettle();
      expect(downloads, 0);
      expect(find.text('已添加到下载队列'), findsNothing);
      decision = Completer<bool>();
      await openMenuAction(tester, find.byKey(const Key('player-download')));
      expect(downloads, 0);
      decision.complete(true);
      await tester.pumpAndSettle();
      expect(downloads, 1);
    },
  );

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

  Future<void> openSetting(WidgetTester tester, String label) async {
    if (label == '选集') {
      await tap(tester, find.byKey(const Key('player-playlist')));
      return;
    }
    await tap(tester, find.byTooltip('更多'));
    await scrollPanelTo(tester, find.text(label));
    await tap(tester, find.text(label));
  }

  testWidgets(
    'Zoom and offset preview update the video immediately and persist only on slider release',
    (tester) async {
      final fixture = PlaybackFixture(count: 1)
        ..configureBackend = (backend) => backend.videoSurface = true;
      final page = await render(tester, suppliedFixture: fixture);
      final controller = fixture.controller;
      await openSetting(tester, '画面');
      final zoom = find.byKey(const Key('player-video-scale'));
      await scrollPanelTo(tester, zoom);
      tester.widget<Slider>(zoom).onChanged!(1.8);
      await tester.pump();
      expect(controller.preferences.videoScale, 1.8);
      expect(page.fixture.history.preferences.videoScale, 1);
      final transform = tester.widget<Transform>(
        find.byKey(const Key('player-video-transform')),
      );
      expect(transform.transform.storage[0], 1.8);
      expect(transform.transform.storage[5], 1.8);
      tester.widget<Slider>(zoom).onChangeEnd!(1.8);
      await tester.pumpAndSettle();
      expect(page.fixture.history.preferences.videoScale, 1.8);
      final horizontal = find.byKey(const Key('player-video-offset-x'));
      await scrollPanelTo(tester, horizontal);
      tester.widget<Slider>(horizontal).onChanged!(.5);
      await tester.pump();
      final surface = find.byKey(const Key('player-video-surface'));
      final translation = tester.widget<Transform>(
        find.descendant(of: surface, matching: find.byType(Transform)).first,
      );
      expect(
        translation.transform.storage[12],
        closeTo(tester.getSize(surface).width / 4, .01),
      );
      expect(page.fixture.history.preferences.videoOffsetX, 0);
      tester.widget<Slider>(horizontal).onChangeEnd!(.5);
      await tester.pumpAndSettle();
      expect(page.fixture.history.preferences.videoOffsetX, .5);
      expect(fixture.current.lastFit, BoxFit.contain);
      expect(fixture.preparations, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, textScale) in [
    (const Size(393, 864), 1.0),
    (const Size(844, 390), 1.0),
    (const Size(320, 700), 1.8),
  ]) {
    testWidgets(
      'Layout edits the video in place and saves only when finished at $size',
      (tester) async {
        final page = await render(tester, size: size, scale: textScale);
        final backend = page.fixture.current..videoSurface = true;
        backend.emit(backend.state.copyWith(buffering: true));
        backend.emit(backend.state.copyWith(buffering: false));
        await tester.pump();
        final preparations = page.fixture.preparations;
        final pauses = backend.pauses, plays = backend.plays;
        await openSetting(tester, '布局');
        expect(find.byKey(const Key('player-panel')), findsNothing);
        expect(find.byKey(const Key('player-layout-editor')), findsOneWidget);
        expect(find.byKey(const Key('player-video-surface')), findsOneWidget);
        final scale = find.byKey(const Key('player-controls-scale'));
        tester.widget<Slider>(scale).onChanged!(1.4);
        await tester.pump();
        expect(page.fixture.controller.preferences.controlsScale, 1);
        expect(page.fixture.history.preferences.controlsScale, 1);
        for (final id in [
          'resolution',
          'cast',
          'speed',
          'playlist',
          'next',
          'lock',
          'screenshot',
        ]) {
          await tap(tester, find.byKey(Key('player-layout-toggle-$id')));
        }
        expect(page.fixture.controller.preferences.showSpeedButton, isTrue);
        expect(page.fixture.preparations, preparations);
        expect(backend.pauses, pauses);
        expect(backend.plays, plays);
        await expectLater(
          find.byKey(const Key('player-capture')),
          matchesGoldenFile('goldens/player-layout-${size.width.toInt()}.png'),
        );
        await tap(tester, find.byKey(const Key('player-layout-cancel')));
        expect(find.byKey(const Key('player-layout-editor')), findsNothing);
        expect(find.byKey(const Key('player-speed')), findsOneWidget);
        expect(page.fixture.controller.preferences.controlsScale, 1);
        await openSetting(tester, '布局');
        tester.widget<Slider>(scale).onChanged!(1.4);
        await tester.pump();
        await tap(tester, find.byKey(const Key('player-layout-toggle-speed')));
        await tap(tester, find.byKey(const Key('player-layout-done')));
        expect(page.fixture.controller.preferences.controlsScale, 1.4);
        expect(page.fixture.history.preferences.controlsScale, 1.4);
        expect(page.fixture.history.preferences.showSpeedButton, isFalse);
        expect(find.byKey(const Key('player-speed')), findsNothing);
        await openSetting(tester, '布局');
        await tap(tester, find.byKey(const Key('player-layout-reset')));
        await tap(tester, find.byKey(const Key('player-layout-done')));
        expect(page.fixture.history.preferences.controlsScale, 1);
        expect(page.fixture.history.preferences.showSpeedButton, isTrue);
        expect(page.fixture.current, same(backend));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Layout back button cancels without closing or pausing video', (
    tester,
  ) async {
    final page = await render(tester);
    final backend = page.fixture.current;
    await openSetting(tester, '布局');
    await tap(tester, find.byKey(const Key('player-layout-toggle-screenshot')));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-layout-editor')), findsNothing);
    expect(find.byKey(const Key('player-screenshot-button')), findsOneWidget);
    expect(backend.state.playing, isTrue);
    expect(page.fixture.history.preferences.showScreenshotButton, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Default screenshot shortcut captures the current frame directly',
    (tester) async {
      final fixture = PlaybackFixture()
        ..configureBackend = (backend) {
          backend.screenshotSupported = true;
          backend.screenshotBytes = Uint8List.fromList([
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
          ]);
        };
      await render(tester, suppliedFixture: fixture);
      final shortcut = find.byKey(const Key('player-screenshot-button'));
      expect(shortcut.hitTestable(), findsOneWidget);
      expect(tester.widget<IconButton>(shortcut).onPressed, isNotNull);
      await tap(tester, shortcut);
      expect(fixture.current.captures, [false]);
      expect(find.byKey(const Key('player-panel')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Long press uses configured speed and sideways movement adjusts without seeking',
    (tester) async {
      final page = await render(tester);
      await tap(tester, find.byKey(const Key('player-more')));
      final setting = find.byKey(const Key('player-boost-rate'));
      await scrollPanelTo(tester, setting);
      tester.widget<Slider>(setting).onChanged!(2.75);
      await tester.pump();
      tester.widget<Slider>(setting).onChangeEnd!(2.75);
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('关闭面板'));
      final backend = page.fixture.current;
      expect(backend.state.rate, 1);
      expect(page.fixture.history.preferences.boostRate, 2.75);
      final position = backend.state.position;
      final gesture = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      expect(backend.state.rate, 2.75);
      await gesture.moveBy(const Offset(96, 0));
      await tester.pump();
      expect(backend.state.rate, 3.75);
      await gesture.moveBy(const Offset(-144, 0));
      await tester.pump();
      expect(backend.state.rate, 2.25);
      expect(backend.state.position, position);
      await gesture.up();
      await tester.pump();
      expect(backend.state.rate, 1);
      expect(page.fixture.history.preferences.boostRate, 2.75);
      final canceled = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      expect(backend.state.rate, 2.75);
      await canceled.cancel();
      await tester.pump();
      expect(backend.state.rate, 1);
      expect(page.fixture.controller.boosting, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Phone keeps external playback in More and cancellation restores playback',
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
      expect(find.byKey(const Key('player-external-player')), findsNothing);
      await openMenuAction(
        tester,
        find.byKey(const Key('player-external-player')),
      );
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
      await openMenuAction(
        tester,
        find.byKey(const Key('player-external-player')),
      );
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
      await tap(tester, find.byTooltip('更多'));
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
      chooseExternalPlayer: () async {
        expect(find.byType(AlertDialog), findsNothing);
        return XFile('C:/Players/player${++choices}.exe');
      },
    );
    device.externalPlayer = (url, _, _) async {
      expect(url, startsWith('http://127.0.0.1:'));
      return true;
    };
    await openMenuAction(
      tester,
      find.byKey(const Key('player-external-player')),
    );
    expect(device.windowsExternalPlayer!.executable, 'C:/Players/player1.exe');
    expect(
      page.fixture.store.data['windowsExternalPlayer'],
      'C:/Players/player1.exe',
    );
    expect(page.fixture.current.state.playing, isFalse);
    await page.fixture.controller.play();
    await openMenuAction(
      tester,
      find.byKey(const Key('player-external-player')),
    );
    expect(find.text('选择其他播放器'), findsOneWidget);
    await tap(tester, find.text('取消'));
    expect(page.fixture.current.state.playing, isTrue);
    expect(choices, 1);
    await openMenuAction(
      tester,
      find.byKey(const Key('player-external-player')),
    );
    await tap(tester, find.text('player1.exe'));
    expect(choices, 1);
    await page.fixture.controller.play();
    await openMenuAction(
      tester,
      find.byKey(const Key('player-external-player')),
    );
    await tap(tester, find.text('选择其他播放器'));
    expect(choices, 2);
    expect(
      page.fixture.store.data['windowsExternalPlayer'],
      'C:/Players/player2.exe',
    );
    // Repeat the native chooser while the previous external transport is live.
    await openMenuAction(
      tester,
      find.byKey(const Key('player-external-player')),
    );
    expect(find.text('player1.exe'), findsOneWidget);
    expect(find.text('player2.exe'), findsOneWidget);
    await tap(tester, find.text('选择其他播放器'));
    expect(choices, 3);
    expect(page.fixture.store.data['windowsExternalPlayers'], [
      'C:/Players/player3.exe',
      'C:/Players/player2.exe',
      'C:/Players/player1.exe',
    ]);
    await openMenuAction(
      tester,
      find.byKey(const Key('player-external-player')),
    );
    await tap(tester, find.text('player1.exe'));
    expect(choices, 3);
    expect(page.fixture.store.data['windowsExternalPlayers'], [
      'C:/Players/player1.exe',
      'C:/Players/player3.exe',
      'C:/Players/player2.exe',
    ]);
    expect(page.fixture.leases.values.single, 2);
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
    await openMenuAction(
      tester,
      find.byKey(const Key('player-external-player')),
    );
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
    await tap(tester, find.byTooltip('更多'));
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
      await result.fixture.controller.updatePreferences(
        result.fixture.controller.preferences.copyWith(
          fit: PlaybackFit.cover,
          aspectRatio: 4 / 3,
          videoScale: 1.5,
          videoOffsetX: .4,
          videoOffsetY: .2,
        ),
      );
      await openMenuAction(tester, find.byKey(const Key('player-pip')));
      tester.view.physicalSize = const Size(480, 270);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-desktop-pip')), findsOneWidget);
      expect(find.byTooltip('更多'), findsNothing);
      expect(backend.lastFit, BoxFit.contain);
      expect(backend.lastAspectRatio, 16 / 9);
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
      expect(find.byTooltip('更多'), findsOneWidget);
      expect(backend.lastFit, BoxFit.cover);
      expect(backend.lastAspectRatio, 4 / 3);
      expect(result.fixture.controller.preferences.videoScale, 1.5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows PiP close stops playback and returns to the previous page',
    (tester) async {
      final device = FakePlaybackDevice()..supportsDesktopPip = true;
      final result = await render(tester, suppliedDevice: device);
      await openMenuAction(tester, find.byKey(const Key('player-pip')));
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
        await tap(tester, find.byTooltip('更多'));
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
      await tap(tester, find.byTooltip('更多'));
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
      await tap(tester, find.byTooltip('更多'));
      await page.device.enterPip();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(page.fixture.current.state.playing, isTrue);
      page.device.leavePip();
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('更多'));
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
    'Essential controls and More actions fit large text and safe areas',
    (tester) async {
      final page = await render(
        tester,
        size: const Size(320, 700),
        scale: 2,
        downloadAvailable: true,
      );
      for (final label in ['返回', '电视投屏', '更多']) {
        expect(find.byTooltip(label).hitTestable(), findsOneWidget);
      }
      expect(
        find.descendant(
          of: find.byKey(const Key('player-top-controls')),
          matching: find.byType(IconButton),
        ),
        findsNWidgets(3),
      );
      for (final key in [
        'player-download',
        'player-pip',
        'player-external-player',
        'player-screenshot',
      ]) {
        expect(find.byKey(Key(key)), findsNothing);
      }
      final time = tester.getRect(find.byKey(const Key('player-time')));
      expect(
        time.bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const Key('player-play-pause'))).top,
        ),
      );
      await tap(tester, find.byKey(const Key('player-more')));
      for (final label in ['音轨', '字幕', '画面', '画中画', '第三方播放器', '下载文件']) {
        final action = find.descendant(
          of: find.byKey(const Key('player-panel')),
          matching: find.byTooltip(label),
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        final rect = tester.getRect(action);
        expect(rect.width, greaterThanOrEqualTo(44));
        expect(rect.height, greaterThanOrEqualTo(44));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
      }
      await tap(tester, find.byTooltip('关闭面板'));
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
    'Android rotation keeps the title below stable system insets even when bars are hidden',
    (tester) async {
      const portrait = Size(393, 864), landscape = Size(864, 393);
      const portraitInsets = EdgeInsets.only(top: 24, bottom: 20);
      const landscapeInsets = EdgeInsets.fromLTRB(44, 24, 20, 0);
      final device = _SystemInsetsDevice()
        ..insets[portrait] = portraitInsets
        ..insets[landscape] = landscapeInsets;
      tester.view.padding = FakeViewPadding(top: 24, bottom: 20);
      tester.view.viewPadding = FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final page = await render(tester, suppliedDevice: device);
      final backend = page.fixture.current;
      final position = backend.state.position;
      final title = find.text(page.fixture.controller.current.name);
      final portraitTop = tester.getRect(title).top;
      await tester.tap(find.byKey(const Key('player-fullscreen')));
      await tester.pump();
      tester.view.physicalSize = landscape;
      tester.view.padding = FakeViewPadding();
      tester.view.viewPadding = FakeViewPadding();
      await tester.pumpAndSettle();
      final landscapeTitle = tester.getRect(title);
      expect(landscapeTitle.top, portraitTop);
      expect(landscapeTitle.left, greaterThanOrEqualTo(44));
      // An intermediate Android frame can still expose the old portrait bars.
      tester.view.padding = FakeViewPadding(top: 48, bottom: 20);
      tester.view.viewPadding = FakeViewPadding(top: 48, bottom: 20);
      await tester.pump();
      expect(tester.getRect(title), landscapeTitle);
      tester.view.padding = FakeViewPadding();
      tester.view.viewPadding = FakeViewPadding();
      await tester.pump();
      expect(tester.getRect(title), landscapeTitle);
      await tester.tap(find.byKey(const Key('player-fullscreen')));
      await tester.pump();
      tester.view.physicalSize = portrait;
      await tester.pumpAndSettle();
      expect(tester.getRect(title).top, portraitTop);
      expect(page.fixture.current, same(backend));
      expect(backend.state.position, position);
      expect(backend.state.playing, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
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
        final fixture = PlaybackFixture();
        fixture.configureBackend = (backend) =>
            backend.screenshotSupported = true;
        await render(
          tester,
          size: size,
          scale: scale,
          suppliedFixture: fixture,
          downloadAvailable: true,
          suppliedDevice: FakePlaybackDevice()
            ..supportsOrientation = true
            ..supportsExternalPlayer = true,
        );
        for (final key in [
          'player-fullscreen',
          'player-play-pause',
          'player-playlist',
          'player-speed',
        ]) {
          final button = find.byKey(Key(key));
          expect(button.hitTestable(), findsOneWidget);
          expect(tester.getRect(button).right, lessThanOrEqualTo(size.width));
        }
        expect(find.byKey(const Key('player-orientation')), findsNothing);
        if (size.width == 393) {
          await expectLater(
            find.byKey(const Key('player-capture')),
            matchesGoldenFile('goldens/player-android-phone.png'),
          );
        }
        await tap(tester, find.byKey(const Key('player-more')));
        if (scale == 1) {
          await expectLater(
            find.byKey(const Key('player-capture')),
            matchesGoldenFile(
              'goldens/player-android-more${size.width > size.height ? '-landscape' : ''}.png',
            ),
          );
        }
        for (final key in [
          'player-pip',
          'player-external-player',
          'player-download',
        ]) {
          final action = find.byKey(Key(key));
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.widget<InkWell>(action).onTap, isNotNull);
          expect(tester.getRect(action).right, lessThanOrEqualTo(size.width));
        }
        expect(find.byKey(const Key('player-screenshot')), findsNothing);
        expect(find.byKey(const Key('player-cast-settings')), findsNothing);
        await tap(tester, find.byTooltip('关闭面板'));
        await tap(tester, find.byKey(const Key('player-fullscreen')));
        expect(fixture.current.state.playing, isTrue);
        expect(find.byKey(const Key('player-panel')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Fullscreen button returns landscape video to portrait without restarting playback',
    (tester) async {
      final page = await render(
        tester,
        size: const Size(844, 390),
        suppliedDevice: FakePlaybackDevice()..supportsOrientation = true,
      );
      final backend = page.fixture.current;
      final position = backend.state.position;
      final preparations = page.fixture.preparations;
      final rotation = find.byKey(const Key('player-fullscreen'));
      expect(find.byTooltip('竖屏'), findsOneWidget);
      await tester.tap(rotation);
      await tester.pump();
      expect(page.device.orientation, PlaybackOrientation.portrait);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      expect(find.byTooltip('全屏'), findsOneWidget);
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
      expect(find.byTooltip('竖屏'), findsOneWidget);
      expect(page.fixture.current, same(backend));
      expect(page.fixture.preparations, preparations);
      expect(backend.state.position, position);
      await tap(tester, find.byTooltip('更多'));
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
      await tap(tester, find.byTooltip('更多'));
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
      await tap(tester, find.byTooltip('更多'));
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
      await tap(tester, find.byTooltip('更多'));
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
      await tap(tester, find.byTooltip('更多'));
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
      final page = await render(tester, size: size, scale: scale);
      await tap(tester, find.byTooltip('更多'));
      final custom = find.byKey(const Key('player-connections-custom'));
      await scrollPanelTo(tester, custom);
      await tap(tester, custom);
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('player-custom-connections'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '256');
      await tester.pumpAndSettle();
      final apply = find.byKey(const Key('player-apply-custom-connections'));
      await tester.ensureVisible(apply);
      await tester.pumpAndSettle();
      expect(apply.hitTestable(), findsOneWidget);
      await tap(tester, apply);
      expect(page.fixture.current.connections, 256);
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Secondary controls live in settings and landscape overlays leave the center clear',
    (tester) async {
      final page = await render(tester, size: const Size(844, 390));
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
      expect(find.byTooltip('上一集'), findsNothing);
      expect(find.byTooltip('下一集').hitTestable(), findsOneWidget);
      await tap(tester, find.byTooltip('下一集'));
      expect(page.fixture.controller.index, 1);
      expect(find.byTooltip('上一集').hitTestable(), findsOneWidget);
      await page.fixture.controller.load(page.fixture.entries.length - 1);
      await tester.pumpAndSettle();
      expect(find.byTooltip('下一集'), findsNothing);
      expect(find.byTooltip('上一集').hitTestable(), findsOneWidget);
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
      expect(find.byTooltip('更多'), findsNothing);
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
      expect(find.byTooltip('更多'), findsOneWidget);
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
      expect(find.byTooltip('更多'), findsNothing);
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
    await tap(tester, find.byTooltip('更多'));
    await scrollPanelTo(tester, find.byKey(const Key('player-skip-settings')));
    await tap(tester, find.text('跳过片头片尾'));
  }

  testWidgets(
    'skip sliders adjust each second and keep intro and outro independent',
    (tester) async {
      final page = await render(tester);
      await openSkipSettings(tester);
      for (final intro in [true, false]) {
        final finder = find.byKey(
          Key(intro ? 'player-skip-intro' : 'player-skip-outro'),
        );
        await scrollPanelTo(tester, finder);
        final slider = tester.widget<Slider>(finder);
        expect(slider.divisions, 600);
        expect(slider.max / slider.divisions!, 1);
        slider.onChanged!(intro ? 1 : 2);
        await tester.pump();
        tester.widget<Slider>(finder).onChangeEnd!(intro ? 1 : 2);
        await tester.pumpAndSettle();
      }
      expect(page.fixture.controller.preferences.skipIntroSeconds, 1);
      expect(page.fixture.controller.preferences.skipOutroSeconds, 2);
      expect(page.fixture.history.preferences.skipIntroSeconds, 1);
      expect(page.fixture.history.preferences.skipOutroSeconds, 2);
    },
  );

  testWidgets(
    'visible shortcuts stay out of settings and hidden shortcuts return there',
    (tester) async {
      final fixture = PlaybackFixture()
        ..configureBackend = (backend) => backend.screenshotSupported = true;
      await render(tester, suppliedFixture: fixture);
      await tap(tester, find.byKey(const Key('player-more')));
      final panel = find.byKey(const Key('player-panel'));
      for (final key in [
        'player-screenshot',
        'player-cast-settings',
        'player-speed',
        'player-playlist',
        'player-fullscreen',
        'player-floating',
      ]) {
        expect(
          find.descendant(of: panel, matching: find.byKey(Key(key))),
          findsNothing,
        );
      }
      await tap(tester, find.byTooltip('关闭面板'));
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(
          showScreenshotButton: false,
          showCastButton: false,
          showSpeedButton: false,
          showPlaylistButton: false,
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('player-more')));
      for (final key in ['player-screenshot', 'player-cast-settings']) {
        expect(
          find.descendant(of: panel, matching: find.byKey(Key(key))),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: panel, matching: find.text('倍速')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: panel, matching: find.text('选集')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'desktop independent window and picture in picture share one menu entry',
    (tester) async {
      await render(
        tester,
        size: const Size(1100, 720),
        suppliedDevice: FakePlaybackDevice()
          ..supportsPip = false
          ..supportsIndependentPlayerWindows = true,
      );
      await tap(tester, find.byKey(const Key('player-more')));
      expect(find.byKey(const Key('player-pip')), findsOneWidget);
      expect(find.text('画中画'), findsOneWidget);
      expect(find.byKey(const Key('player-floating')), findsNothing);
      expect(find.text('独立小窗'), findsNothing);
    },
  );

  for (final (size, scale) in [
    (const Size(393, 864), 1.0),
    (const Size(844, 390), 1.0),
    (const Size(320, 700), 1.8),
  ]) {
    testWidgets('boost rates stay near the visible video top at $size', (
      tester,
    ) async {
      final fixture = PlaybackFixture()
        ..configureBackend = (backend) => backend.videoSurface = true;
      await render(tester, size: size, scale: scale, suppliedFixture: fixture);
      final gesture = await tester.startGesture(
        Offset(size.width / 2, size.height / 2),
      );
      await tester.pump(const Duration(milliseconds: 700));
      final indicator = find.byKey(const Key('player-boost-indicator'));
      expect(indicator, findsOneWidget);
      final rect = tester.getRect(indicator);
      final videoHeight = (size.width / (1920 / 1080)).clamp(0, size.height);
      final videoTop = (size.height - videoHeight) / 2;
      final expectedTop = videoTop + (videoHeight * .06).clamp(12, 24);
      expect(rect.top, closeTo(expectedTop, .5));
      expect(rect.center.dx, closeTo(size.width / 2, .5));
      expect(rect.center.dy, lessThan(size.height / 2));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(size.width - 16));
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile('goldens/player-boost-${size.width.toInt()}.png'),
      );
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(fixture.controller.boostLocked, isTrue);
      final lockedRect = tester.getRect(indicator);
      expect(lockedRect.top, closeTo(expectedTop, .5));
      expect(lockedRect.center.dx, closeTo(size.width / 2, .5));
      expect(lockedRect.center.dy, lessThan(size.height / 2));
      expect(lockedRect.left, greaterThanOrEqualTo(16));
      expect(lockedRect.right, lessThanOrEqualTo(size.width - 16));
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile(
          'goldens/player-boost-locked-${size.width.toInt()}.png',
        ),
      );
      await gesture.moveBy(const Offset(0, 60));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(indicator, findsNothing);
      expect(fixture.current.state.rate, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, scale, playing) in [
    (const Size(393, 864), 1.0, true),
    (const Size(844, 390), 1.0, true),
    (const Size(320, 700), 1.8, false),
  ]) {
    testWidgets(
      'Custom skip times are independent of the timeline and persist per folder at $size',
      (tester) async {
        final fixture = PlaybackFixture(
          suppliedEntries: [
            for (var index = 0; index < 2; index++)
              PlaybackEntry(
                id: '$index',
                key: 'custom-skip-$index',
                name: '第 ${index + 1} 集.mkv',
                video: true,
                settingsFolder: 'custom-skip-show',
              ),
          ],
        );
        await render(
          tester,
          size: size,
          scale: scale,
          suppliedFixture: fixture,
        );
        final backend = fixture.current;
        if (!playing) await fixture.controller.pause();
        final preparations = fixture.preparations;
        final seeks = backend.seeks.length,
            plays = backend.plays,
            pauses = backend.pauses;
        await openSkipSettings(tester);
        expect(find.text('使用当前进度'), findsNothing);
        for (final (id, input, value) in [
          ('intro', '1:30', 90),
          ('outro', '75', 75),
        ]) {
          final button = find.byKey(Key('player-custom-skip-$id'));
          await scrollPanelTo(tester, button);
          await tap(tester, button);
          await tester.enterText(
            find.byKey(const Key('player-skip-time-input')),
            input,
          );
          await tap(tester, find.byKey(const Key('player-skip-time-apply')));
          final saved = fixture.history.preferencesFor('custom-skip-show');
          expect(
            id == 'intro' ? saved.skipIntroSeconds : saved.skipOutroSeconds,
            value,
          );
        }
        expect(fixture.history.preferences.skipIntroSeconds, 0);
        expect(fixture.history.preferences.skipOutroSeconds, 0);
        expect(backend.state.position, const Duration(seconds: 120));
        expect(backend.state.playing, playing);
        expect(backend.plays, plays);
        expect(backend.pauses, pauses);
        expect(backend.seeks.length, seeks);
        expect(fixture.preparations, preparations);
        await tap(tester, find.byTooltip('关闭面板'));
        await fixture.controller.next();
        await tester.pumpAndSettle();
        expect(fixture.controller.preferences.skipIntroSeconds, 90);
        expect(fixture.controller.preferences.skipOutroSeconds, 75);
        expect(fixture.current.seeks, contains(const Duration(seconds: 90)));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Custom skip input validates times and is available before duration is known',
    (tester) async {
      final page = await render(tester);
      final backend = page.fixture.current;
      await page.fixture.controller.pause();
      backend.emit(backend.state.copyWith(duration: Duration.zero));
      await tester.pump();
      await openSkipSettings(tester);
      final button = find.byKey(const Key('player-custom-skip-intro'));
      await scrollPanelTo(tester, button);
      await tap(tester, button);
      for (final invalid in ['601', '10:01', '1:60', '-1', 'abc', '1.5']) {
        await tester.enterText(
          find.byKey(const Key('player-skip-time-input')),
          invalid,
        );
        await tap(tester, find.byKey(const Key('player-skip-time-apply')));
        expect(find.byKey(const Key('player-skip-time-input')), findsOneWidget);
        expect(page.fixture.controller.preferences.skipIntroSeconds, 0);
      }
      await tester.enterText(
        find.byKey(const Key('player-skip-time-input')),
        '10:00',
      );
      await tap(tester, find.byKey(const Key('player-skip-time-apply')));
      expect(page.fixture.history.preferences.skipIntroSeconds, 600);
      await tap(tester, button);
      await tester.enterText(
        find.byKey(const Key('player-skip-time-input')),
        '0',
      );
      await tap(tester, find.byKey(const Key('player-skip-time-apply')));
      expect(page.fixture.history.preferences.skipIntroSeconds, 0);
      expect(backend.state.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android gestures adjust system volume and persist the actual step after the native reply',
    (tester) async {
      final device = FakePlaybackDevice()..supportsSystemVolume = true;
      final fixture = PlaybackFixture(
        data: {
          'playbackPreferences': {'volume': 15},
        },
      );
      final page = await render(
        tester,
        suppliedDevice: device,
        suppliedFixture: fixture,
      );
      final backend = fixture.current;
      expect(device.systemVolumes, isEmpty);
      expect(fixture.controller.state.volume, 60);
      expect(backend.volumes, [100]);
      device.changeSystemVolume(40);
      await tester.pump();
      expect(fixture.controller.state.volume, 40);
      final reply = Completer<void>();
      device.systemVolumeBarrier = reply.future;
      await tester.dragFrom(const Offset(310, 350), const Offset(0, -160));
      await tester.pump();
      expect(device.systemVolumes, isEmpty);
      reply.complete();
      await tester.pumpAndSettle();
      expect(device.systemVolume, greaterThan(40));
      expect(fixture.controller.state.volume, device.systemVolume);
      expect(fixture.history.preferences.volume, device.systemVolume);
      expect(backend.volumes, [100]);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(device.systemVolume, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(device.systemVolume, greaterThan(0));
      final beforeNext = device.systemVolumes.length;
      await fixture.controller.next();
      await tester.pumpAndSettle();
      expect(fixture.current.volumes, [100]);
      expect(device.systemVolumes.length, beforeNext);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(device.finished, isTrue);
      expect(device.systemVolumes.length, beforeNext);
      expect(tester.takeException(), isNull);
      expect(page.fixture, fixture);
    },
  );

  testWidgets(
    'System volume discovered after playback starts replaces backend attenuation',
    (tester) async {
      final device = FakePlaybackDevice();
      final fixture = PlaybackFixture(
        data: {
          'playbackPreferences': {'volume': 15},
        },
      );
      await render(tester, suppliedDevice: device, suppliedFixture: fixture);
      expect(fixture.current.volumes, [15]);
      device.supportsSystemVolume = true;
      device.changeSystemVolume(40);
      await tester.pumpAndSettle();
      expect(fixture.controller.state.volume, 40);
      expect(fixture.current.volumes, [15, 100]);
      await tester.dragFrom(const Offset(310, 350), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(device.systemVolume, 100);
      expect(fixture.controller.state.volume, 100);
      expect(fixture.history.preferences.volume, 100);
      expect(fixture.current.volumes, [15, 100]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Volume HUD shows the system accepted value when Android caps the requested maximum',
    (tester) async {
      final device = _CappedSystemVolumeDevice();
      final page = await render(tester, suppliedDevice: device);
      await tester.dragFrom(const Offset(310, 350), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(device.systemVolume, 70);
      expect(page.fixture.controller.state.volume, 70);
      expect(find.text('音量  70%'), findsOneWidget);
      expect(find.text('音量  100%'), findsNothing);
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

  testWidgets(
    'Boost indicator hides after inactivity and restarts only when the rate changes',
    (tester) async {
      final page = await render(tester);
      final gesture = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      expect(page.fixture.current.state.rate, 2);
      final indicator = find.byKey(const Key('player-boost-indicator'));
      expect(indicator, findsOneWidget);
      for (final step in [5, 6, 8, 10, 12]) {
        expect(find.byKey(ValueKey('player-boost-step-$step')), findsOneWidget);
      }
      final center = tester.getCenter(indicator).dy;
      expect(center, lessThan(432));
      expect(center, greaterThan(320));
      await tester.pump(const Duration(seconds: 2));
      expect(page.fixture.current.state.rate, 2);
      expect(indicator, findsNothing);
      await gesture.moveBy(const Offset(96, 0));
      await tester.pump();
      expect(page.fixture.current.state.rate, 3);
      expect(
        find.byKey(const ValueKey('player-boost-step-16')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-boost-step-6')), findsNothing);
      await tester.pump(const Duration(milliseconds: 900));
      await gesture.moveBy(const Offset(1, 0));
      await tester.pump(const Duration(milliseconds: 299));
      expect(indicator, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(indicator, findsNothing);
      expect(page.fixture.current.state.rate, 3);
      await gesture.moveBy(const Offset(48, 0));
      await tester.pump();
      expect(indicator, findsOneWidget);
      expect(page.fixture.current.state.rate, 3.5);
      await gesture.up();
      await tester.pump();
      expect(page.fixture.current.state.rate, 1);
      expect(indicator, findsNothing);
    },
  );

  testWidgets(
    'Sliding up locks the adjusted rate and a later downward hold cancels it',
    (tester) async {
      final page = await render(tester);
      final controller = page.fixture.controller;
      final backend = page.fixture.current;
      await controller.setRate(1.5);
      await tester.pump();
      final position = backend.state.position;
      final volume = backend.state.volume;
      final brightness = page.device.brightness;
      final gesture = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(96, -8));
      await tester.pump();
      expect(backend.state.rate, 3);
      expect(controller.boostLocked, isFalse);
      await gesture.moveBy(const Offset(3, -60));
      await tester.pump();
      expect(controller.boostLocked, isTrue);
      expect(backend.state.rate, 3);
      expect(find.text('倍速已锁定 · 长按下滑取消'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(backend.state.rate, 3);
      expect(controller.boosting, isTrue);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.byKey(const Key('player-boost-indicator')), findsNothing);
      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.boostLocked, isTrue);
      expect(backend.state.rate, 3);
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('3.0×'), findsOneWidget);
      final cancel = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      expect(backend.state.rate, 3);
      await cancel.moveBy(const Offset(3, 60));
      await tester.pump();
      expect(controller.boosting, isFalse);
      expect(controller.boostLocked, isFalse);
      expect(backend.state.rate, 1.5);
      await cancel.moveBy(const Offset(96, -120));
      await cancel.up();
      await tester.pump();
      expect(backend.state.rate, 1.5);
      expect(backend.state.position, position);
      expect(backend.state.volume, volume);
      expect(page.device.brightness, brightness);
      expect(page.fixture.history.preferences.rate, 1.5);
      expect(page.fixture.history.preferences.boostRate, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A downward turn cancels a temporary boost before releasing the finger',
    (tester) async {
      final page = await render(tester);
      final gesture = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(96, 20));
      await tester.pump();
      expect(page.fixture.current.state.rate, 3);
      expect(page.fixture.controller.boostLocked, isFalse);
      await gesture.moveBy(const Offset(2, 30));
      await tester.pump();
      expect(page.fixture.current.state.rate, 3);
      await gesture.moveBy(const Offset(2, 30));
      await tester.pump();
      expect(page.fixture.current.state.rate, 1);
      expect(page.fixture.controller.boosting, isFalse);
      expect(find.byKey(const Key('player-boost-indicator')), findsNothing);
      await gesture.up();
      await tester.pump();
      expect(page.fixture.current.state.rate, 1);
    },
  );

  testWidgets(
    'A locked hold can be cancelled downwards without lifting first',
    (tester) async {
      final page = await render(tester);
      final gesture = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(page.fixture.controller.boostLocked, isTrue);
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(page.fixture.current.state.rate, 1);
      expect(page.fixture.controller.boosting, isFalse);
      await gesture.up();
      await tester.pump();
      expect(page.fixture.current.state.rate, 1);
    },
  );

  testWidgets('Cancelling the active recognizer clears even a locked boost', (
    tester,
  ) async {
    final page = await render(tester);
    final gesture = await tester.startGesture(const Offset(196, 300));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(page.fixture.controller.boostLocked, isTrue);
    await gesture.cancel();
    await tester.pump();
    expect(page.fixture.current.state.rate, 1);
    expect(page.fixture.controller.boostLocked, isFalse);
    expect(page.fixture.controller.boosting, isFalse);
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

  for (final systemBack in [false, true]) {
    testWidgets(
      '${systemBack ? 'System' : 'Button'} back stops audio and returns while progress persistence is pending',
      (tester) async {
        final fixture = PlaybackFixture(historyFactory: _SlowProgressStore.new);
        final page = await render(tester, suppliedFixture: fixture);
        final history = fixture.history as _SlowProgressStore;
        final gate = Completer<void>();
        history.barrier = gate.future;
        final position = fixture.current.state.position;
        try {
          if (systemBack) {
            await tester.binding.handlePopRoute();
          } else {
            await tester.tap(find.byTooltip('返回'));
          }
          // Audio pauses at the start of navigation, before route disposal.
          expect(fixture.current.state.playing, isFalse);
          await tester.pumpAndSettle();
          expect(find.text('播放器已关闭'), findsOneWidget);
          expect(fixture.controller.closed, isTrue);
          expect(fixture.current.closed, isTrue);
          expect(history.saves, greaterThan(0));
          expect(page.device.finished, isTrue);
        } finally {
          gate.complete();
          await tester.pump();
          await fixture.controller.close();
        }
        expect(
          fixture.history.bookmark(fixture.entries.first.key)!.position,
          position,
        );
        expect(fixture.leases.values.every((count) => count == 0), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Background pauses immediately without waiting for an unrelated PiP query',
    (tester) async {
      final page = await render(tester);
      final gate = Completer<void>();
      page.device.queryPipBarrier = gate.future;
      try {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(page.fixture.current.state.playing, isFalse);
        expect(page.device.pipQueries, 0);
      } finally {
        gate.complete();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'A late PiP visibility reply cannot pause playback after returning to the app',
    (tester) async {
      final page = await render(tester);
      await openMenuAction(tester, find.byKey(const Key('player-pip')));
      final gate = Completer<void>();
      page.device.queryPipBarrier = gate.future;
      try {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(page.device.pipQueries, 1);
        page.device.leavePip();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(page.fixture.current.state.playing, isTrue);
      } finally {
        gate.complete();
        await tester.pumpAndSettle();
      }
      expect(page.fixture.current.state.playing, isTrue);
    },
  );

  testWidgets(
    'PiP hides Flutter controls, forwards actions and pauses when hidden',
    (tester) async {
      final page = await render(tester), backend = page.fixture.current;
      await openMenuAction(tester, find.byKey(const Key('player-pip')));
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
    'iOS player hides PiP and preserves ordinary playback after backgrounding',
    (tester) async {
      final device = FakePlaybackDevice()
        ..supportsPip = false
        ..supportsOrientation = true;
      final fixture = PlaybackFixture(
        externalStreamFactory: _FixtureExternalStream.new,
      )..configureBackend = (backend) => backend.videoSurface = true;
      final page = await render(
        tester,
        suppliedDevice: device,
        suppliedFixture: fixture,
      );
      final video = find.byKey(const Key('player-video-surface'));
      final ordinarySurface = tester.element(video);
      await tap(tester, find.byKey(const Key('player-more')));
      expect(find.byKey(const Key('player-pip')), findsNothing);
      expect(find.text('画中画'), findsNothing);
      await tap(tester, find.byTooltip('关闭面板'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(page.fixture.current.state.playing, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(page.fixture.current.state.playing, isFalse);
      expect(device.pipQueries, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(page.fixture.controller.usingSystemPip, isFalse);
      expect(page.fixture.current.state.playing, isFalse);
      await tap(tester, find.byKey(const Key('player-play-pause')));
      expect(page.fixture.current.state.playing, isTrue);
      expect(tester.element(video), same(ordinarySurface));
      expect(find.byKey(const Key('player-system-pip-surface')), findsNothing);
      expect(device.inPip, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
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
      await tap(tester, find.byTooltip('更多'));
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
        await f.controller.updatePreferences(
          f.controller.preferences.copyWith(showScreenshotButton: false),
        );
        await tester.pumpAndSettle();
        if (!initiallyPlaying) {
          await f.controller.pause();
          await tester.pumpAndSettle();
        }
        await openMenuAction(
          tester,
          find.byKey(const Key('player-screenshot')),
        );
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
          await openMenuAction(
            tester,
            find.byKey(const Key('player-screenshot')),
          );
          expect(f.current.captures, [false, true, false]);
          await tap(tester, find.byTooltip('关闭面板'));
          expect(f.current.state.playing, isFalse);
        }
      },
    );
  }
}
