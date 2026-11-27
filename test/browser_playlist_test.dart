import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/preview_page.dart';
import 'support.dart';

final _share = BrowseSession(
  platform: CloudPlatform.guangya,
  mode: BrowseMode.share,
  title: '熊出没·年年有熊 (2026)',
  rootId: 'root',
  sourceLink: ParsedLink(
    source: 'fixture',
    url: 'https://www.guangyapan.com/s/1936844829381554216_adyPbY8EdLN_2AZv',
    kind: LinkKind.cloudShare,
    platform: CloudPlatform.guangya,
    shareId: '1936844829381554216_adyPbY8EdLN_2AZv',
  ),
);
const _folder = '1925627925871480875';
const _trail = [('root', '全部文件'), (_folder, '熊出没·年年有熊 (2026)')];
final _videos = [
  GuangyaConnector.file(
    {
      'fileId': '1925627925967949891',
      'fileName':
          'Boonie.Booni.The.Hidden.Protector.2026.2160p.WEB-DL.H.265.AAC.mp4',
      'fileSize': 13853270596,
      'resType': 1,
      'dirType': 1,
      'fileType': 2,
    },
    _folder,
    share: true,
  ),
  GuangyaConnector.file(
    {
      'fileId': '1925627925967949893',
      'fileName':
          'Boonie.Booni.The.Hidden.Protector.2026.2160p.WEB-DL.HQ.DV.H.265.AAC.mp4',
      'fileSize': 17329927399,
      'resType': 1,
      'dirType': 1,
      'fileType': 2,
    },
    _folder,
    share: true,
  ),
];

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final entry in ['favorite', 'search', 'partial-list']) {
    testWidgets('$entry preview keeps the full Guangya source directory', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync(
        'asterlink-browser-playlist-',
      );
      final reads = <String>[];
      final http = FakeHttp((request) {
        if (request.uri.path.endsWith('get_share_access_token')) {
          return jsonResponse({
            'msg': 'success',
            'data': {'accessToken': 'fixture-share'},
          });
        }
        expect(request.uri.path, '/userres/v1/get_share_page_files_list');
        final parent = request.json.str('parentId');
        reads.add(parent);
        final files = parent.isEmpty
            ? [
                const CloudFile(
                  id: _folder,
                  name: '熊出没·年年有熊 (2026)',
                  isDirectory: true,
                ),
              ]
            : _videos;
        return jsonResponse({
          'msg': 'success',
          'data': {
            'total': files.length,
            'cursor': 100,
            'list': [
              for (final file in files)
                {
                  'fileId': file.id,
                  'fileName': file.name,
                  'fileSize': file.size,
                  'resType': file.isDirectory ? 2 : 1,
                  'dirType': 1,
                },
            ],
          },
        });
      });
      final services = AppServices(
        store: StateStore.memory(),
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(directory),
        http: http,
        platformFeatures: false,
        controlEnabled: false,
      );
      final routes = _Routes();
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [routes],
            home: BrowserPage(
              services,
              _share,
              initialItems: entry == 'partial-list' ? [_videos.first] : _videos,
              initialCursor: entry == 'partial-list' ? 'next' : null,
              initialTrail: _trail,
              highlightedFileId: entry == 'favorite' ? _videos.first.id : null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (entry == 'search') {
          await tester.tap(find.byKey(const Key('browser-search-entry')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('browser-search-input')),
            'WEB-DL.H.265',
          );
          await tester.tap(find.byKey(const Key('browser-search-submit')));
          await tester.pumpAndSettle();
        }
        expect(find.byTooltip('${_videos.first.name}操作'), findsOneWidget);
        if (entry != 'partial-list') {
          expect(find.byTooltip('${_videos.last.name}操作'), findsNothing);
        }
        await tester.tap(find.byTooltip('${_videos.first.name}操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('预览 / 文件详情'));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        // Inspect the route before mounting its native video backend.
        final route = routes.pushed.last as MaterialPageRoute;
        final preview =
            route.builder(tester.element(find.byType(Navigator).first))
                as PreviewPage;
        expect(
          preview.playlist.map((file) => file.id),
          _videos.map((file) => file.id),
        );
        expect(preview.parentFolders, {
          for (final file in _videos) file.id: _folder,
        });
        if (entry == 'partial-list') expect(reads, contains(_folder));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await services.close();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    });
  }
}
