import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'support.dart';

class BrowserTestConnector extends TianyiConnector {
  BrowserTestConnector(this.drive) : super(FakeHttp());
  final CloudPlatform drive;
  @override
  CloudPlatform get platform => drive;
  List<CloudSpace> spaces = const [
    CloudSpace('12001', '周末相册'),
    CloudSpace('12002', '家人的云盘'),
  ];
  final reads = <(String, String)>[];
  Completer<List<CloudFile>>? pendingFolder;
  AppException? familyFailure;

  BrowseSession personalSession() => BrowseSession(
    platform: platform,
    mode: BrowseMode.personal,
    title: platform.label,
    rootId: 'personal-root',
  );
  BrowseSession familySession(CloudSpace space) => BrowseSession(
    platform: platform,
    mode: BrowseMode.personal,
    title: '${platform == CloudPlatform.tianyi ? '天翼' : '移动'}家庭云',
    rootId: platform == CloudPlatform.tianyi ? '' : 'root-${space.id}',
    metadata: {'familyId': space.id, 'familyName': space.name},
  );
  @override
  Future<CloudAccount> account(Credential credential) async =>
      const CloudAccount('测试账号', total: 1000, used: 100);
  @override
  Future<BrowseSession> openPersonal(Credential credential) async =>
      personalSession();
  @override
  Future<List<CloudSpace>> familySpaces(Credential credential) async {
    if (familyFailure != null) throw familyFailure!;
    return spaces;
  }

  @override
  Future<BrowseSession> openFamily(
    CloudSpace space,
    Credential credential,
  ) async => familySession(space);
  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    reads.add((session.familyId, parentId));
    if (parentId != session.rootId) {
      if (pendingFolder != null) return pendingFolder!.future;
      return [
        CloudFile(
          id: 'nested-video',
          name: '旧目录视频.mp4',
          parentId: parentId,
          size: 42000,
        ),
      ];
    }
    return [
      CloudFile(
        id: 'photos',
        name: '假期相册',
        isDirectory: true,
        parentId: parentId,
      ),
      CloudFile(
        id: 'work',
        name: '工作资料',
        isDirectory: true,
        parentId: parentId,
      ),
      CloudFile(
        id: 'photo',
        name: '01 海边照片.jpg',
        size: 2842102,
        parentId: parentId,
        modifiedAt: '2026-09-17 17:32',
        thumbnailUrl: 'https://preview.example.test/photo.png',
      ),
      CloudFile(
        id: 'video',
        name: '02 旅行视频.mp4',
        size: 235623874,
        parentId: parentId,
        modifiedAt: '2026-09-17 16:10',
        thumbnailUrl: 'https://preview.example.test/video.png',
      ),
      CloudFile(
        id: 'notes',
        name: '使用说明.txt',
        size: 1080,
        parentId: parentId,
        modifiedAt: '2026-09-16 12:00',
      ),
      CloudFile(
        id: 'plan',
        name: '旅行计划.pdf',
        size: 3425012,
        parentId: parentId,
        modifiedAt: '2026-09-15 09:30',
      ),
    ];
  }
}

class BrowserUiFixture {
  BrowserUiFixture._(this.directory, this.services, this.connector);
  final Directory directory;
  final AppServices services;
  final BrowserTestConnector connector;

  static Future<BrowserUiFixture> create({
    CloudPlatform platform = CloudPlatform.tianyi,
    String view = 'list',
    DateTime Function() clock = DateTime.now,
  }) async {
    final directory = Directory.systemTemp.createTempSync(
      'asterlink-browser-test-',
    );
    final connector = BrowserTestConnector(platform);
    final services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'settings': {'browserView': view, 'theme': 'Light'},
        'credentials': {
          platform.key: Credential('测试账号', {
            'primary': 'COOKIE_LOGIN_USER=fixture',
          }, updatedAt: 1).toJson(),
        },
      }),
      dataDirectory: directory,
      cacheDirectory: Directory('${directory.path}/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('${directory.path}/saved')),
      platformFeatures: false,
      clock: clock,
      http: FakeHttp(),
    );
    services.cloud.connectors[platform] = connector;
    await services.initialize();
    return BrowserUiFixture._(directory, services, connector);
  }

  Future<void> render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    bool dark = false,
    double scale = 1,
    BrowseSession? session,
    bool picking = false,
    String? font,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('browser-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            dark ? Brightness.dark : Brightness.light,
            fontFamily: font,
          ),
          home: BrowserPage(
            services,
            session ?? connector.personalSession(),
            picking: picking,
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> close() async {
    await services.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

class ThumbnailHttpClient implements HttpClient {
  ThumbnailHttpClient({List<int>? image})
    : image =
          image ??
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          );
  List<int> image;
  final requests = <ThumbnailRequest>[];
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final request = ThumbnailRequest(url, image);
    requests.add(request);
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ThumbnailRequest implements HttpClientRequest {
  ThumbnailRequest(this.uri, this.bytes);
  @override
  final Uri uri;
  final List<int> bytes;
  @override
  final ThumbnailHeaders headers = ThumbnailHeaders();
  @override
  Future<HttpClientResponse> close() async =>
      ThumbnailResponse(bytes, uri.path.contains('broken') ? 404 : 200);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ThumbnailHeaders implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ThumbnailResponse extends Stream<List<int>>
    implements HttpClientResponse {
  ThumbnailResponse(this.bytes, this.statusCode);
  final List<int> bytes;
  @override
  final int statusCode;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
