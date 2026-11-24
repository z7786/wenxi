import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/lan/lan_browser_receiver.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:asterlink/platform/completed_file_actions.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/ui/download_location_picker.dart';
import 'package:asterlink/ui/lan_browser_panel.dart';

import 'support.dart';

class _PanelLan extends LanService {
  _PanelLan(StateStore store, LanBrowserReceiver receiver)
    : super(
        store: store,
        files: LanFiles(android: false),
        browserReceiver: receiver,
        discoveryEnabled: false,
      ) {
    addresses = ['192.168.1.20'];
    connectionCode = '123456';
  }
  bool live = true;
  @override
  bool get running => live;
  @override
  int get port => 52381;
  void changeNetwork() {
    addresses = ['192.168.2.20'];
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late AppServices services;
  late _PanelLan lan;
  late FakeFiles files;
  late String receiptId;
  late List<MethodCall> calls;
  const savedPath = 'content://downloads.test/document/received';

  Future<void> setup(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
    Size size = const Size(320, 720),
    bool dark = false,
    double scale = 1,
    bool receipt = true,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    root = Directory.systemTemp.createTempSync('lan-browser-ui-');
    receiptId = lanId();
    final store = StateStore.memory({
      'settings': {'destination': r'D:\Downloads'},
      if (receipt)
        'lanBrowserReceipts': [
          {
            'id': receiptId,
            'path': '资料/中文文件.txt',
            'size': 3,
            'sha256': sha256.convert([1, 2, 3]).toString(),
            'sender': '手机浏览器',
            'createdAt': 1,
            'savedPath': savedPath,
          },
        ],
    });
    files = FakeFiles(Directory(p.join(root.path, 'saved')));
    final receiver = LanBrowserReceiver(
      store: store,
      cache: Directory(p.join(root.path, 'web-cache')),
      files: files,
      destination: () => null,
    );
    lan = _PanelLan(store, receiver);
    services = AppServices(
      store: store,
      dataDirectory: root,
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      transport: FakeNative(),
      files: files,
      http: FakeHttp(),
      lanService: lan,
      platformFeatures: false,
      controlEnabled: false,
    );
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: LanBrowserReceiptsPage(
          services,
          fileActions: CompletedFileActions(platform: 'android'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    services.close().then((_) => closed = true);
    for (var i = 0; i < 100 && !closed; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(closed, isTrue);
    await tester.runAsync(() => root.delete(recursive: true));
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    messenger.setMockMethodCallHandler(channel, null);
  }

  testWidgets(
    'Phone keeps the configured directory and opens a SAF receipt through the existing native bridge',
    (tester) async {
      await setup(tester, dark: true, scale: 1.3);
      try {
        expect(find.byType(DownloadLocationField), findsNothing);
        expect(find.text(r'保存位置：D:\Downloads'), findsOneWidget);
        expect(find.text('中文文件.txt'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('打开文件'));
        await tester.tap(find.byTooltip('打开文件'));
        await tester.pumpAndSettle();
        expect(calls.single.method, 'openFile');
        expect(calls.single.arguments, {
          'path': savedPath,
          'name': '中文文件.txt',
          'chooseApp': true,
        });
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'An unavailable receipt remains visible and reports the problem without opening it',
    (tester) async {
      await setup(tester);
      try {
        files.availability[savedPath] = FileAvailability.missing;
        await tester.ensureVisible(find.byTooltip('打开文件'));
        await tester.tap(find.byTooltip('打开文件'));
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        expect(find.text('文件已移动或无法访问，请检查保存目录'), findsOneWidget);
        expect(find.text('中文文件.txt'), findsOneWidget);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Desktop browser destination is independent of ordinary downloads',
    (tester) async {
      await setup(
        tester,
        platform: TargetPlatform.windows,
        size: const Size(1200, 800),
        receipt: false,
      );
      try {
        final field = tester.widget<DownloadLocationField>(
          find.byType(DownloadLocationField),
        );
        expect(field.showDefaultOption, isFalse);
        expect(field.selection.path, r'D:\Downloads');
        await tester.tap(find.byKey(const Key('download-location-browse')));
        await tester.pumpAndSettle();
        expect(services.lanBrowserDestination, files.directory.path);
        expect(services.settings.destination, r'D:\Downloads');
        expect(
          find.byKey(const Key('download-location-default')),
          findsNothing,
        );
        expect(find.text('暂无网页接收记录'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Browser QR uses HTTP and becomes invalid when the network address changes',
    (tester) async {
      await setup(tester, receipt: false);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: LanBrowserPanel(services, address: '192.168.1.20'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('http://192.168.1.20:52381/'), findsOneWidget);
        await tester.tap(find.byKey(const Key('lan-browser-qr')));
        await tester.pumpAndSettle();
        expect(find.byType(QrImageView), findsOneWidget);
        expect(find.text('http://192.168.1.20:52381/'), findsNWidgets(2));
        expect(lan.browserUrl('192.168.1.20').scheme, 'http');
        lan.changeNetwork();
        await tester.pumpAndSettle();
        expect(find.byType(QrImageView), findsNothing);
        expect(find.text('网页地址已失效，请重新开启互联并查看当前地址。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );
}
