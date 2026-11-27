import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/playback/online_subtitles.dart';
import 'package:asterlink/playback/subtitle_files.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/player_online_subtitle_panel.dart';
import 'package:asterlink/ui/player_page.dart';
import 'package:asterlink/ui/player_theme.dart';
import 'player_support.dart';

const _subtitle = OnlineSubtitle(
  url: 'https://subtitle.example.com/show.srt',
  name: 'Show.S01E02.srt',
  title: '简体[SRT]连续剧 第 2 集 中英双语.srt',
  format: 'srt',
  languages: ['简体', '英语'],
  duration: Duration(minutes: 47),
);

class _Service implements OnlineSubtitleService {
  final searches = <String>[];
  final searchScopes = <RequestScope>[];
  final downloads = <OnlineSubtitle>[];
  final downloadScopes = <RequestScope>[];
  List<OnlineSubtitle> results = const [_subtitle];
  Future<List<OnlineSubtitle>>? searchBarrier;
  Future<File>? downloadBarrier;
  Object? searchError, downloadError;
  bool closed = false;

  @override
  Future<List<OnlineSubtitle>> search(String name, RequestScope scope) async {
    searches.add(name);
    searchScopes.add(scope);
    if (searchError != null) throw searchError!;
    return await searchBarrier ?? results;
  }

  @override
  Future<File> download(
    OnlineSubtitle subtitle,
    Directory directory,
    RequestScope scope,
  ) async {
    downloads.add(subtitle);
    downloadScopes.add(scope);
    if (downloadError != null) throw downloadError!;
    if (downloadBarrier != null) return await downloadBarrier!;
    return SubtitleFiles(directory).stage(
      subtitle.name,
      Stream.value(utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n中文字幕\n')),
    );
  }

  @override
  void close() => closed = true;
}

void main() {
  var fixtureFont = false;
  setUpAll(() async {
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      await (FontLoader('FixtureUI')..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          ))
          .load();
      fixtureFont = true;
    }
  });

  Future<({PlaybackFixture fixture, Directory directory, _Service service})>
  render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    _Service? service,
    bool television = false,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final fixture = PlaybackFixture();
    final directory = (await tester.runAsync(
      () =>
          Directory.systemTemp.createTemp('asterlink-player-online-subtitles-'),
    ))!;
    final subtitles = service ?? _Service();
    addTearDown(() => removePlayerFixture(directory));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('online-subtitle-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            brightness,
            fontFamily: fixtureFont ? 'FixtureUI' : null,
          ),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          initialRoute: '/player',
          routes: {
            '/': (_) => const Scaffold(body: Text('播放器已关闭')),
            '/player': (_) => PlayerPage(
              fixture.controller,
              device: FakePlaybackDevice()..isTelevision = television,
              subtitleDirectory: directory,
              onlineSubtitles: subtitles,
            ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fixture.controller.ready, isTrue);
    return (fixture: fixture, directory: directory, service: subtitles);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('player-panel')),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSubtitles(WidgetTester tester) async {
    final tv = find.byTooltip('字幕');
    if (tv.evaluate().isNotEmpty) {
      await tap(tester, tv);
    } else {
      await tap(tester, find.byTooltip('更多'));
      await reveal(tester, find.text('字幕'));
      await tap(tester, find.text('字幕'));
    }
  }

  Future<void> openOnline(WidgetTester tester, {bool settle = true}) async {
    await openSubtitles(tester);
    final entry = find.byKey(const Key('player-online-subtitles'));
    await reveal(tester, entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    if (settle) await tester.pumpAndSettle();
  }

  Future<void> drainFileWork(
    WidgetTester tester,
    bool Function() complete,
  ) async {
    for (var attempt = 0; attempt < 100 && !complete(); attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(complete(), isTrue);
  }

  testWidgets(
    'Online subtitles are opt-in and search the current episode on opening',
    (tester) async {
      final page = await render(tester);
      expect(page.service.searches, isEmpty);
      await openSubtitles(tester);
      expect(page.service.searches, isEmpty);
      await reveal(tester, find.byKey(const Key('player-online-subtitles')));
      await tap(tester, find.byKey(const Key('player-online-subtitles')));
      expect(find.byType(PlayerOnlineSubtitlePanel), findsOneWidget);
      expect(page.service.searches, [page.fixture.controller.current.name]);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('online-subtitle-query')))
            .controller!
            .text,
        page.fixture.controller.current.name,
      );
      expect(find.text(_subtitle.title), findsOneWidget);
      expect(find.text('简体 / 英语 · SRT · 时长 47:00'), findsOneWidget);
      expect(page.service.downloads, isEmpty);
      expect(page.fixture.current.state.playing, isTrue);
      expect(page.fixture.current.state.track.subtitle.uri, isFalse);
    },
  );

  testWidgets(
    'Editing a query cancels the previous search and ignores its late results',
    (tester) async {
      final first = Completer<List<OnlineSubtitle>>();
      final service = _Service()..searchBarrier = first.future;
      await render(tester, service: service);
      await openOnline(tester, settle: false);
      expect(find.text('正在搜索在线字幕…'), findsOneWidget);
      service.searchBarrier = null;
      service.results = const [];
      await tester.enterText(
        find.byKey(const Key('online-subtitle-query')),
        '连续剧 S01E03',
      );
      await tap(tester, find.byKey(const Key('online-subtitle-search')));
      expect(service.searches.last, '连续剧 S01E03');
      expect(service.searchScopes.first.token.isCancelled, isTrue);
      expect(find.textContaining('没有找到可用字幕'), findsOneWidget);
      first.complete(const [_subtitle]);
      await tester.pumpAndSettle();
      expect(find.text(_subtitle.title), findsNothing);
      expect(find.textContaining('没有找到可用字幕'), findsOneWidget);
    },
  );

  testWidgets('Search errors support retry without affecting playback', (
    tester,
  ) async {
    final service = _Service()
      ..searchError = const AppException('在线字幕服务暂不可用，请稍后重试');
    final page = await render(tester, service: service);
    await openOnline(tester);
    expect(find.text('在线字幕服务暂不可用，请稍后重试'), findsOneWidget);
    service.searchError = null;
    await tap(tester, find.text('重新搜索'));
    expect(find.text(_subtitle.title), findsOneWidget);
    expect(page.fixture.current.state.playing, isTrue);
    expect(page.fixture.controller.error, isEmpty);
  });

  testWidgets(
    'A failed subtitle network search shows DNS guidance and can be edited and retried',
    (tester) async {
      final previous = DiagnosticLog.active;
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        log.dispose();
        DiagnosticLog.active = previous;
      });
      final service = _Service()
        ..searchError = const DownloadNetworkException(
          'connectionError',
          cause: SocketException(
            'Failed host lookup: private.example',
            osError: OSError('fixture DNS', 11001),
          ),
        );
      final page = await render(tester, service: service);
      await openOnline(tester);
      expect(find.text('在线字幕搜索无法解析服务地址，请检查网络或 DNS 后重试'), findsOneWidget);
      expect(find.textContaining('没有找到可用字幕'), findsNothing);
      expect(find.textContaining('下载连接中断'), findsNothing);
      final fields = asJson(
        log
            .entries()
            .singleWhere(
              (e) => e.event == 'player.online_subtitle_search_failed',
            )
            .data['fields'],
      );
      expect(fields['stage'], 'search');
      expect(fields['kind'], 'connectionError');
      expect(fields['errno'], 11001);
      expect(fields['dns'], isTrue);
      service.searchError = null;
      await tester.enterText(
        find.byKey(const Key('online-subtitle-query')),
        'Name S01E02',
      );
      await tap(tester, find.byKey(const Key('online-subtitle-search')));
      expect(service.searches.last, 'Name S01E02');
      expect(find.text(_subtitle.title), findsOneWidget);
      expect(page.fixture.current.state.playing, isTrue);
      expect(page.fixture.controller.error, isEmpty);
    },
  );

  testWidgets(
    'A video switch during the initial search cannot adopt results for the previous episode',
    (tester) async {
      final gate = Completer<List<OnlineSubtitle>>();
      final service = _Service()..searchBarrier = gate.future;
      final page = await render(tester, service: service);
      await openOnline(tester, settle: false);
      await page.fixture.controller.next();
      await tester.pumpAndSettle();
      expect(service.searchScopes.single.token.isCancelled, isTrue);
      gate.complete(const [_subtitle]);
      await tester.pumpAndSettle();
      expect(find.textContaining('视频已切换'), findsOneWidget);
      expect(find.text(_subtitle.title), findsNothing);
      expect(service.downloads, isEmpty);
    },
  );

  testWidgets(
    'Selecting a result stages and loads it, preserves pause and uses normal subtitle controls',
    (tester) async {
      final page = await render(tester);
      await page.fixture.controller.pause();
      await tester.pumpAndSettle();
      await openOnline(tester);
      await tester.tap(find.text(_subtitle.title));
      await drainFileWork(
        tester,
        () => page.fixture.current.state.track.subtitle.uri,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlayerOnlineSubtitlePanel), findsNothing);
      expect(page.fixture.current.state.playing, isFalse);
      expect(page.fixture.controller.preferences.subtitles, isTrue);
      final staged = File.fromUri(
        Uri.parse(page.fixture.current.state.track.subtitle.id),
      );
      expect(staged.parent.path, page.directory.path);
      expect(await tester.runAsync(staged.readAsString), contains('中文字幕'));
      await openSubtitles(tester);
      expect(find.text(_subtitle.title), findsOneWidget);
      await reveal(tester, find.text('延后 0.5 秒'));
      await tap(tester, find.text('延后 0.5 秒'));
      expect(page.fixture.current.subtitleDelay, .5);
      await tap(tester, find.byTooltip('关闭面板'));
      await openSubtitles(tester);
      await tap(tester, find.text('关闭字幕'));
      expect(page.fixture.current.state.track.subtitle.id, 'no');
      await tap(tester, find.byTooltip('关闭面板'));
      await tap(tester, find.byTooltip('返回'));
      var closed = false;
      unawaited(page.fixture.controller.close().then((_) => closed = true));
      await drainFileWork(tester, () => closed);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(staged.exists), isFalse);
    },
  );

  testWidgets(
    'Subtitle download and native load failures keep results available for retry',
    (tester) async {
      final service = _Service()
        ..downloadError = const AppException('字幕下载地址已失效，请重新搜索');
      final page = await render(tester, service: service);
      await openOnline(tester);
      await tap(tester, find.text(_subtitle.title));
      expect(find.text('字幕下载地址已失效，请重新搜索'), findsOneWidget);
      expect(find.text(_subtitle.title), findsOneWidget);
      expect(page.fixture.current.state.playing, isTrue);

      service.downloadError = null;
      page.fixture.current.failSubtitle = true;
      await tester.tap(find.text(_subtitle.title));
      await drainFileWork(
        tester,
        () => find.text('字幕加载失败，请重新选择或重试').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlayerOnlineSubtitlePanel), findsOneWidget);
      page.fixture.current.failSubtitle = false;
      await tester.tap(find.text(_subtitle.title));
      await drainFileWork(
        tester,
        () => page.fixture.current.state.track.subtitle.uri,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlayerOnlineSubtitlePanel), findsNothing);
      expect(page.fixture.controller.error, isEmpty);
    },
  );

  testWidgets(
    'A video switch cancels a pending subtitle and deletes a late private copy',
    (tester) async {
      final gate = Completer<File>();
      final service = _Service()..downloadBarrier = gate.future;
      final page = await render(tester, service: service);
      await openOnline(tester);
      await tester.tap(find.text(_subtitle.title));
      await tester.pump();
      await page.fixture.controller.next();
      await tester.pumpAndSettle();
      expect(service.downloadScopes.single.token.isCancelled, isTrue);
      expect(find.textContaining('视频已切换'), findsOneWidget);
      final file = (await tester.runAsync(
        () => SubtitleFiles(page.directory).stage(
          _subtitle.name,
          Stream.value(
            utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nlate subtitle\n'),
          ),
        ),
      ))!;
      gate.complete(file);
      await drainFileWork(tester, () => !file.existsSync());
      expect(page.fixture.current.state.track.subtitle.uri, isFalse);
      await tap(tester, find.byTooltip('关闭面板'));
      service.downloadBarrier = null;
      await openOnline(tester);
      expect(service.searches.last, page.fixture.controller.current.name);
      expect(find.text(_subtitle.title), findsOneWidget);
    },
  );

  testWidgets('Closing the panel cancels downloading and ignores a late file', (
    tester,
  ) async {
    final gate = Completer<File>();
    final service = _Service()..downloadBarrier = gate.future;
    final page = await render(tester, service: service);
    await openOnline(tester);
    await tester.tap(find.text(_subtitle.title));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pump();
    final file = (await tester.runAsync(
      () => SubtitleFiles(page.directory).stage(
        _subtitle.name,
        Stream.value(
          utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nabandoned subtitle\n'),
        ),
      ),
    ))!;
    gate.complete(file);
    await tester.pump(const Duration(milliseconds: 300));
    await drainFileWork(tester, () => !file.existsSync());
    await tester.pumpAndSettle();
    expect(service.downloadScopes.single.token.isCancelled, isTrue);
    expect(page.fixture.current.state.track.subtitle.uri, isFalse);
    expect(service.closed, isFalse);
  });

  testWidgets(
    'Online subtitle search stays scrollable when the landscape keyboard is open',
    (tester) async {
      final page = await render(tester, size: const Size(792, 360));
      await openOnline(tester);
      final expectedGeneration = page.fixture.controller.generation;
      tester.view.viewInsets = const FakeViewPadding(bottom: 216);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(page.fixture.controller.generation, expectedGeneration);
      final input = find.byKey(const Key('online-subtitle-query'));
      await tester.ensureVisible(input);
      await tester.enterText(input, 'S01E02');
      await tester.pump();
      expect(page.fixture.controller.generation, expectedGeneration);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('online-subtitle-search')))
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(
        find.byKey(const Key('online-subtitle-search')),
      );
      await tester.pump();
      await tap(tester, find.byKey(const Key('online-subtitle-search')));
      expect(page.service.searches.last, 'S01E02');
      expect(page.fixture.controller.generation, expectedGeneration);
      await tester.scrollUntilVisible(
        find.text(_subtitle.title),
        80,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('online-subtitle-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text(_subtitle.title), findsOneWidget);
    },
  );

  for (final (label, size, keyboardHeight) in [
    ('phone', const Size(393, 864), 320.0),
    ('landscape', const Size(792, 360), 216.0),
  ]) {
    testWidgets(
      'Online subtitle input retains focus as $label keyboard opens',
      (tester) async {
        final page = await render(tester, size: size);
        await openOnline(tester);
        final input = find.byKey(const Key('online-subtitle-query'));
        final editable = find.descendant(
          of: input,
          matching: find.byType(EditableText),
        );
        await tester.showKeyboard(input);
        await tester.pump();
        final original = tester.state<EditableTextState>(editable);
        final focus = original.widget.focusNode;
        addTearDown(tester.view.resetViewInsets);
        for (final fraction in [.25, .5, 1.0]) {
          tester.view.viewInsets = FakeViewPadding(
            bottom: keyboardHeight * fraction,
          );
          await tester.pump();
          expect(tester.state<EditableTextState>(editable), same(original));
          expect(focus.hasFocus, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          expect(tester.takeException(), isNull);
        }
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '中文第二集',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 2, end: 5),
          ),
        );
        await tester.pump();
        expect(original.widget.controller.text, '中文第二集');
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pump();
        expect(tester.state<EditableTextState>(editable), same(original));
        expect(focus.hasFocus, isTrue);
        await tap(tester, find.byKey(const Key('online-subtitle-search')));
        expect(page.service.searches.last, '中文第二集');
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'Online subtitle form matches the player in $brightness theme',
      (tester) async {
        await render(tester, brightness: brightness);
        await openOnline(tester);
        final input = find.byKey(const Key('online-subtitle-query'));
        final decorator = tester.widget<InputDecorator>(
          find.descendant(of: input, matching: find.byType(InputDecorator)),
        );
        final fill = decorator.decoration.fillColor!;
        expect(decorator.decoration.filled, isTrue);
        expect(fill.computeLuminance(), lessThan(.08));
        expect(
          (decorator.decoration.enabledBorder! as OutlineInputBorder)
              .borderRadius,
          BorderRadius.circular(12),
        );
        expect(decorator.baseStyle!.color, Colors.white);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (label, size, scale, television) in [
    ('phone', const Size(393, 864), 1.0, false),
    ('narrow', const Size(320, 700), 1.5, false),
    ('landscape', const Size(792, 360), 1.0, false),
    ('desktop', const Size(1280, 800), 1.0, false),
    ('television', const Size(1920, 1080), 1.0, true),
  ]) {
    testWidgets('Online subtitle search and results fit $label controls', (
      tester,
    ) async {
      final page = await render(
        tester,
        size: size,
        scale: scale,
        television: television,
      );
      await openOnline(tester);
      expect(find.byKey(const Key('online-subtitle-query')), findsOneWidget);
      expect(find.text(_subtitle.title), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Material>(find.byKey(const Key('player-panel'))).color,
        playerPanelColor,
      );
      expect(
        tester.getRect(find.text(_subtitle.title)).right,
        lessThanOrEqualTo(size.width),
      );
      if (Platform.environment['ASTERLINK_SUBTITLE_CAPTURE'] == '1') {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('online-subtitle-capture')),
        );
        await tester.runAsync(() async {
          final captured = await boundary.toImage();
          final bytes = await captured.toByteData(
            format: ui.ImageByteFormat.png,
          );
          captured.dispose();
          final directory = Directory(
            '.local/online-subtitles-20261115/screenshots',
          );
          await directory.create(recursive: true);
          await File(
            '${directory.path}/$label.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      expect(page.service.searches, hasLength(1));
      await tap(tester, find.byTooltip('关闭面板'));
    });
  }
}
