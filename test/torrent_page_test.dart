import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/torrent_page.dart';
import 'support.dart';
import 'torrent_test.dart' show TorrentTestHttp, testTorrent, testTorrentJson;

class _MetadataEngine extends GopeedEngine {
  _MetadataEngine(this.services)
    : super(
        FakeNative(),
        services.store,
        services.vault,
        services.dataDirectory,
        services.cacheDirectory,
      );
  @override
  Future<Json> torrentCall(String method, Json args) async =>
      method == 'torrentMetadata'
      ? {'status': 'ready', 'info': services.metadata}
      : {};
  final _UiServices services;
  @override
  Future<void> close() async {}
}

class _SelectionQueue extends DownloadManager {
  _SelectionQueue(AppServices s)
    : super(
        store: s.store,
        engine: s.engine,
        files: s.files,
        cleanups: s.cleanups,
        http: s.transfer,
        refreshSource: (_) async =>
            throw StateError('No cloud request in a BT selection test'),
      );
  List<int> selection = [];
  @override
  Future<List<String>> enqueueTorrent(
    TorrentInfo info,
    List<int> selected,
  ) async {
    selection = selected;
    return [for (final index in selected) 'selected-$index'];
  }
}

class _UiServices extends Fake implements AppServices {
  _UiServices(this.dataDirectory, {Json? metadata})
    : metadata = metadata ?? testTorrentJson;
  final Json metadata;
  @override
  final Directory dataDirectory;
  @override
  late final cacheDirectory = Directory(p.join(dataDirectory.path, 'cache'));
  @override
  final store = StateStore.memory();
  @override
  late final vault = Vault(store);
  @override
  late final files = FakeFiles(Directory(p.join(dataDirectory.path, 'saved')));
  @override
  final transfer = TorrentTestHttp();
  @override
  late final cleanups = CleanupOutbox(store, FakeHttp());
  @override
  late final engine = _MetadataEngine(this);
  @override
  late final downloads = _SelectionQueue(this);
  @override
  Future<void> close() async {
    downloads.dispose();
    await engine.close();
  }
}

void main() {
  bool systemFont = false;
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
      await (FontLoader('FixtureUI')..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });
  for (final (name, size, dark, scale, count) in [
    ('phone-bt', const Size(430, 960), false, 1.0, 2),
    ('phone-bt-dark', const Size(430, 960), true, 1.0, 2),
    ('landscape-bt-large-text', const Size(900, 430), false, 1.3, 2),
    ('phone-bt-many-files', const Size(430, 960), false, 1.0, 1001),
    ('phone-bt-long-paths', const Size(393, 864), false, 1.0, 200),
    ('phone-bt-narrow-large-text', const Size(320, 700), true, 1.8, 200),
    ('phone-bt-max-files', const Size(430, 960), true, 1.3, maxTorrentFiles),
  ]) {
    testWidgets('$name file selection works without layout overflow', (
      tester,
    ) async {
      String downloadLabel(int selected) => size.width < 400 && scale * 14 > 20
          ? '下载 $selected 个文件'
          : '下载选中 $selected 个文件';
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      late Directory root;
      late AppServices services;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('aster-bt-ui-');
        services = _UiServices(
          root,
          metadata: count == 2
              ? null
              : {
                  ...testTorrentJson,
                  'files': [
                    for (var i = 0; i < count; i++)
                      {
                        'index': i,
                        'path':
                            name.contains('long-paths') ||
                                name.contains('narrow-large-text')
                            ? '学习资料/计算机课程合集/进阶课程/2026完整视频与配套练习/第${i + 1}集-课程讲解与实践示例-1080p.mp4'
                            : '合集/$i.mp4',
                        'size': 4,
                      },
                  ],
                },
        );
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(
              dark ? Brightness.dark : Brightness.light,
              fontFamily: systemFont ? 'FixtureUI' : null,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => RepaintBoundary(
                        key: const Key('capture'),
                        child: TorrentPage(services, testTorrent.magnet),
                      ),
                    ),
                  ),
                  child: const Text('打开种子'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开种子'));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(downloadLabel(count)), findsOneWidget);
        final preview = Platform.environment['APP_BT_PREVIEW_DIR'];
        if (preview != null) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            try {
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$preview/$name.png',
              ).writeAsBytes(data!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        if (count > 2 && scale == 1) {
          final listRect = tester.getRect(
            find.byKey(const PageStorageKey('torrent-files')),
          );
          final fullyVisible = find.byType(CheckboxListTile).evaluate().where((
            element,
          ) {
            final box = element.renderObject as RenderBox;
            final top = box.localToGlobal(Offset.zero).dy;
            return top >= listRect.top &&
                top + box.size.height <= listRect.bottom;
          }).length;
          expect(fullyVisible, greaterThanOrEqualTo(10));
        }
        if (name.contains('long-paths')) {
          final first = find.byKey(const ValueKey('torrent-file-0'));
          final titleTooltip = find
              .descendant(of: first, matching: find.byType(Tooltip))
              .first;
          final fullPath = (services as _UiServices).metadata
              .list('files')
              .first
              .str('path');
          expect(tester.widget<Tooltip>(titleTooltip).message, fullPath);
          await tester.longPress(titleTooltip);
          await tester.pumpAndSettle();
          expect(find.text(fullPath), findsOneWidget);
          await tester.pump(const Duration(seconds: 3));
        }
        if (systemFont && count == 2) {
          await expectLater(
            find.byKey(const Key('capture')),
            matchesGoldenFile('goldens/$name.png'),
          );
        }
        await tester.tap(find.text('清空选择'));
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('torrent-download')))
              .onPressed,
          isNull,
        );
        for (final index in [0, 1]) {
          final row = find.byKey(ValueKey('torrent-file-$index'));
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(of: row, matching: find.byType(Checkbox)),
          );
          await tester.pump();
        }
        expect(find.text(downloadLabel(2)), findsOneWidget);
        if (count > 2) {
          await tester.drag(find.byType(ListView), const Offset(0, -650));
          await tester.pumpAndSettle();
          expect(find.text(downloadLabel(2)), findsOneWidget);
          // Only visible rows are built; selecting all must include the rest.
          expect(
            find.byType(CheckboxListTile).evaluate().length,
            lessThan(count),
          );
          tester
              .state<ScrollableState>(find.byType(Scrollable))
              .position
              .jumpTo(0);
          await tester.pumpAndSettle();
        }
        for (final index in [0, 1]) {
          expect(
            tester
                .widget<CheckboxListTile>(
                  find.byKey(ValueKey('torrent-file-$index')),
                )
                .value,
            isTrue,
          );
        }
        await tester.ensureVisible(
          find.byKey(const ValueKey('torrent-file-0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('torrent-file-0')));
        await tester.pump();
        expect(find.text(downloadLabel(1)), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('torrent-file-0')));
        await tester.pump();
        expect(find.text(downloadLabel(2)), findsOneWidget);
        await tester.tap(find.text('清空选择'));
        await tester.pump();
        expect(find.text('已选 0 个'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '全选'))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.text('全选'));
        await tester.pump();
        expect(find.text(downloadLabel(count)), findsOneWidget);
        if (count > 2 && count <= 200) {
          final last = find.byKey(ValueKey('torrent-file-${count - 1}'));
          final position = tester
              .state<ScrollableState>(find.byType(Scrollable))
              .position;
          for (
            var attempt = 0;
            attempt < 10 && last.hitTestable().evaluate().isEmpty;
            attempt++
          ) {
            position.jumpTo(position.maxScrollExtent);
            await tester.pumpAndSettle();
          }
          expect(last.hitTestable(), findsOneWidget);
          expect(tester.widget<CheckboxListTile>(last).value, isTrue);
        }
        await tester.tap(find.byKey(const Key('torrent-download')));
        await tester.pumpAndSettle();
        expect(
          (services.downloads as _SelectionQueue).selection,
          List<int>.generate(count, (i) => i),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        services.close().then((_) => closed = true);
        for (var i = 0; i < 30 && !closed; i++) {
          await tester.pump();
        }
        expect(closed, isTrue);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });
  }
}
