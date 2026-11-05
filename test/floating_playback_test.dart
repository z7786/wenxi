import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/playback/floating_playback.dart';
import 'package:asterlink/ui/floating_playback_host.dart';
import 'package:asterlink/ui/player_page.dart';
import 'player_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('An idle host closes immediately before real-clock cleanup', (
    tester,
  ) async {
    final store = StateStore.memory();
    final manager = FloatingPlaybackManager.of(store);
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FloatingPlaybackHost(store: store, child: const SizedBox()),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => manager.close());
    expect(manager.sessions, isEmpty);
  });
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.asterlink.app/playback'),
          (call) async =>
              call.method == 'begin' ? {'pip': true, 'brightness': .5} : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.asterlink.app/playback'),
          null,
        );
  });
  testWidgets(
    'two independent windows leave main navigation usable and close only their own decoder',
    (tester) async {
      final store = StateStore.memory();
      final first = PlaybackFixture(sharedStore: store, count: 1);
      final second = PlaybackFixture(sharedStore: store, count: 1);
      await first.controller.start();
      await second.controller.start();
      first.current.nativeSubtitles = true;
      second.current.nativeSubtitles = true;
      final manager = FloatingPlaybackManager.of(store);
      addTearDown(store.dispose);
      final firstWindow = manager.add(first.controller);
      final secondWindow = manager.add(second.controller);
      var mainClicks = 0;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: manager.navigatorKey,
          builder: (_, child) =>
              FloatingPlaybackHost(store: store, child: child!),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: TextButton(
                onPressed: () => mainClicks++,
                child: const Text('主界面操作'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder window(FloatingPlaybackSession session) =>
          find.byKey(ValueKey('floating-window-${session.id}'));
      expect(window(firstWindow), findsOneWidget);
      expect(window(secondWindow), findsOneWidget);
      expect(first.current.subtitlePresentations.single.size, 12);
      expect(second.current.subtitlePresentations.single.size, 12);
      expect(first.current.subtitlePresentations.single.width, 280);
      expect(first.current.subtitlePresentations.single.height, lessThan(200));
      await tester.tap(find.text('主界面操作'));
      await tester.pump();
      expect(mainClicks, 1);
      await tester.tap(
        find.descendant(
          of: window(secondWindow),
          matching: find.byTooltip('暂停小窗'),
        ),
      );
      await tester.pump();
      expect(second.current.state.playing, isFalse);
      expect(first.current.state.playing, isTrue);
      final position = tester.getTopLeft(window(secondWindow));
      await tester.drag(
        find.descendant(
          of: window(secondWindow),
          matching: find.text(second.controller.current.name),
        ),
        const Offset(-260, -150),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(window(secondWindow)), isNot(position));
      final originalSubtitleWidth =
          second.current.subtitlePresentations.last.width!;
      await tester.drag(
        find.descendant(
          of: window(secondWindow),
          matching: find.byIcon(CupertinoIcons.arrow_down_right_arrow_up_left),
        ),
        const Offset(100, 0),
      );
      await tester.pumpAndSettle();
      expect(
        second.current.subtitlePresentations.last.width,
        greaterThan(originalSubtitleWidth),
      );
      expect(first.current.subtitlePresentations, hasLength(1));
      await tester.tap(
        find.descendant(
          of: window(secondWindow),
          matching: find.byTooltip('关闭小窗'),
        ),
      );
      await tester.pumpAndSettle();
      expect(second.controller.closed, isTrue);
      expect(second.leases.values, everyElement(0));
      expect(first.controller.closed, isFalse);
      expect(first.current.state.playing, isTrue);
      expect(window(firstWindow), findsOneWidget);
      expect(window(secondWindow), findsNothing);
      expect(tester.takeException(), isNull);
      await manager.close();
      expect(first.current.closes, 1);
      expect(first.leases.values, everyElement(0));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'phone uses system picture in picture without creating an independent window',
    (tester) async {
      final fixture = PlaybackFixture(count: 1);
      final manager = FloatingPlaybackManager.of(fixture.store);
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('asterlink-player-floating-'),
      );
      final device = FakePlaybackDevice();
      var confirmations = 0;
      BuildContext? confirmationContext;
      addTearDown(() async {
        await removePlayerFixture(directory!);
        fixture.store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: manager.navigatorKey,
          builder: (_, child) =>
              FloatingPlaybackHost(store: fixture.store, child: child!),
          initialRoute: '/player',
          routes: {
            '/': (_) => const Scaffold(body: Text('主软件')),
            '/player': (_) => PlayerPage(
              fixture.controller,
              subtitleDirectory: directory!,
              device: device,
              confirmDownload: (context) async {
                confirmations++;
                confirmationContext = context;
                return false;
              },
              onDownload: (_) async =>
                  fail('cancelled download must not enqueue'),
            ),
          },
        ),
      );
      await tester.pumpAndSettle();
      await fixture.controller.seek(const Duration(seconds: 200));
      await tester.pump();
      final decoder = fixture.current;
      await tester.tap(find.byKey(const Key('player-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-floating')), findsNothing);
      expect(find.text('独立小窗'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('player-pip')));
      await tester.tap(find.byKey(const Key('player-pip')));
      await tester.pumpAndSettle();
      expect(device.inPip, isTrue);
      expect(manager.sessions, isEmpty);
      expect(fixture.controller.closed, isFalse);
      expect(decoder.state.playing, isTrue);
      device.leavePip();
      await tester.pumpAndSettle();
      expect(manager.sessions, isEmpty);
      expect(fixture.controller.floating, isFalse);
      expect(identical(fixture.current, decoder), isTrue);
      expect(decoder.state.position, const Duration(seconds: 200));
      expect(fixture.preparations, 1);
      await tester.tap(find.byKey(const Key('player-more')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('player-download')));
      await tester.tap(find.byKey(const Key('player-download')));
      await tester.pumpAndSettle();
      expect(confirmations, 1);
      expect(confirmationContext!.mounted, isTrue);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(fixture.controller.closed, isTrue);
      expect(fixture.leases.values, everyElement(0));
      expect(tester.takeException(), isNull);
      await manager.close();
    },
  );

  test(
    'concurrent manager shutdown calls wait for the same blocked native close',
    () async {
      final fixture = PlaybackFixture(count: 1);
      await fixture.controller.start();
      final manager = FloatingPlaybackManager.of(fixture.store);
      final window = manager.add(fixture.controller);
      final blocked = Completer<void>();
      fixture.current.closeBarrier = blocked.future;
      final sessionClose = manager.closeSession(window);
      final first = manager.close(), second = manager.close();
      expect(identical(first, second), isTrue);
      var finished = false;
      second.then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      blocked.complete();
      await Future.wait([sessionClose, first, second]);
      expect(fixture.current.closes, 1);
      expect(fixture.leases.values, everyElement(0));
      fixture.store.dispose();
    },
  );

  testWidgets(
    'inactive app pauses every floating decoder without resuming audio on return',
    (tester) async {
      final store = StateStore.memory();
      addTearDown(store.dispose);
      final first = PlaybackFixture(sharedStore: store, count: 1);
      final second = PlaybackFixture(sharedStore: store, count: 1);
      await first.controller.start();
      await second.controller.start();
      final manager = FloatingPlaybackManager.of(store);
      manager.add(first.controller);
      manager.add(second.controller);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: manager.navigatorKey,
          builder: (_, child) =>
              FloatingPlaybackHost(store: store, child: child!),
          home: const Scaffold(body: Text('主软件')),
        ),
      );
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(first.current.state.playing, isFalse);
      expect(second.current.state.playing, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(first.current.state.playing, isFalse);
      expect(second.current.state.playing, isFalse);
      await manager.close();
    },
  );
}
