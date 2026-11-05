import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_qr.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/device_link_page.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'support.dart';

const _link = 'https://pan.quark.cn/s/LanExample?pwd=abcd 提取码：abcd';
const _message = '普通文字也能互传 📱\n第二行：晚上八点见。\n符号 <>&" 原样保留';
const _peerId = '11111111111111111111111111111111';

class _UiFiles extends LanFiles {
  _UiFiles() : super(android: false);
  bool pickedFolder = false;
  int pickCount = 0;
  List<String> selection = ['sample.apk'];
  @override
  Future<List<String>> pickFiles() async {
    pickCount++;
    return selection;
  }

  @override
  Future<LanFileSelection> scan(
    List<String> locations, {
    bool folder = false,
  }) async {
    pickedFolder = folder;
    return const LanFileSelection([
      LanLocalFile(
        location: 'sample.apk',
        path: '示例安装包.apk',
        size: 4,
        modifiedAt: 0,
      ),
    ]);
  }

  @override
  Future<void> createDirectories(
    String destination,
    List<String> directories,
  ) async {}
}

class _UiLan extends LanService {
  _UiLan(StateStore store)
    : super(store: store, files: _UiFiles(), discoveryEnabled: false);
  bool live = false;
  int starts = 0;
  int allowedIncoming = 0;
  bool paired = false, failSend = false;
  final sent = <({String peerId, String text})>[];
  final invitations = <({String peerId, LanShare share})>[];
  final published = <LanShare>[];
  final otherPeers = <LanPeer>[];
  final pairedIds = <String>{};
  final lookedUp = <String>[], pairCodes = <String>[], received = <String>[];
  String? lastQr;
  final peerId = _peerId;
  @override
  List<LanPeer> get peers => [
    LanPeer(
      id: peerId,
      name: '我的手机',
      address: '192.168.1.10',
      port: 52381,
      lastSeen: DateTime.now(),
    ),
    ...otherPeers,
  ];
  @override
  bool get running => live;
  @override
  int get port => 52381;
  @override
  List<LanShare> get shares => published;
  @override
  Future<void> start() async {
    starts++;
    live = true;
    id = '22222222222222222222222222222222';
    name = '我的电脑';
    connectionCode = '123456';
    addresses = ['192.168.1.9', '10.1.1.9'];
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    live = false;
    notifyListeners();
  }

  @override
  Future<void> refreshDevices() async {}
  @override
  Future<void> allowIncomingConnections() async {
    allowedIncoming++;
  }

  @override
  bool connected(LanPeer peer) =>
      paired && peer.id == peerId || pairedIds.contains(peer.id);
  @override
  String connectionQr([String? address]) =>
      lastQr = super.connectionQr(address);
  @override
  Future<LanPeer> findDevice(String address) async {
    if (!running) await start();
    lookedUp.add(address);
    return peers.single;
  }

  @override
  Future<void> connect(LanPeer peer, String code) async {
    pairCodes.add(code);
    paired = true;
    notifyListeners();
  }

  @override
  LanPeer? senderOf(LanInboxItem item) =>
      item.senderId == peerId ? peers.single : null;
  @override
  Future<void> sendMessage(LanPeer peer, String text) async {
    if (failSend) throw const AppException('对方暂时离线，请重新连接');
    sent.add((peerId: peer.id, text: text));
  }

  @override
  Future<void> sendShare(LanPeer peer, LanShare share) async {
    if (failSend) throw const AppException('对方暂时离线，请重新连接');
    require(connected(peer), '设备连接已失效');
    invitations.add((peerId: peer.id, share: share));
  }

  @override
  Future<LanShare> createShare(
    LanFileSelection selection, {
    Duration? lifetime = const Duration(hours: 1),
    void Function(int, int)? preparing,
  }) async {
    final result = LanShare(
      LanManifest(
        token: lanId(),
        name: '示例安装包.apk',
        files: [
          LanFileEntry(
            id: lanId(),
            path: '示例安装包.apk',
            size: 4,
            sha256: sha256.convert([1, 2, 3, 4]).toString(),
          ),
        ],
        expiresAt: lifetime == null ? null : DateTime.now().add(lifetime),
      ),
      {},
    );
    published.add(result);
    notifyListeners();
    return result;
  }

  @override
  Future<LanManifest> readShare(String address) async {
    received.add(address);
    return published.first.manifest;
  }
}

class _ShareConnector extends CloudConnector {
  @override
  CloudPlatform get platform => CloudPlatform.quark;
  final links = <ParsedLink>[];
  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    links.add(link);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '收到的分享',
      rootId: 'root',
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async => const [
    CloudFile(id: 'sample', name: '测试文件.txt', parentId: 'root', size: 4),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UiHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"fixture"', null), false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var fixtureFont = false;
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('LanFixture')..addFont(
            font.readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
      fixtureFont = true;
    }
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });
  late AppServices services;
  late _UiLan lan;
  late Directory root;
  late _ShareConnector connector;

  Future<void> render(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
    bool dark = false,
    bool shell = false,
    bool inbox = false,
    bool textInbox = false,
    String messageText = _message,
    bool initiallyRunning = false,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    root = Directory.systemTemp.createTempSync('aster-lan-ui-');
    final store = StateStore.memory({
      'credentials': {
        'Quark': Credential('测试账号', {
          'primary': '__pus=fixture; __puus=fixture',
        }).toJson(),
      },
      if (inbox || textInbox)
        'lanInbox': [
          LanInboxItem(
            id: lanId(),
            sender: '我的手机',
            senderId: _peerId,
            kind: textInbox ? 'text' : 'link',
            value: textInbox ? messageText : _link,
            createdAt: 1,
          ).toJson(),
        ],
    });
    lan = _UiLan(store);
    if (initiallyRunning) {
      await lan.start();
      lan.starts = 0;
    }
    services = AppServices(
      store: store,
      lanService: lan,
      dataDirectory: root,
      cacheDirectory: Directory('${root.path}/cache'),
      files: FakeFiles(Directory('${root.path}/saved')),
      transport: FakeNative(),
      transferHttp: _UiHttp(),
      http: FakeHttp(),
      platformFeatures: false,
      controlEnabled: false,
    );
    connector = _ShareConnector();
    services.cloud.connectors[CloudPlatform.quark] = connector;
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('lan-preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            dark ? Brightness.dark : Brightness.light,
            fontFamily: fixtureFont ? 'LanFixture' : null,
          ),
          home: shell ? MainShell(services) : DeviceLinkPage(services),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (const bool.fromEnvironment('LAN_CAPTURE_PREVIEWS') && !shell) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('lan-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.local/lan-preview-${size.width.toInt()}-${dark ? 'dark' : 'light'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }
  }

  Future<void> close(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    services.close().then((_) {
      closed = true;
    });
    for (var i = 0; i < 100 && !closed; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(closed, isTrue);
    await tester.runAsync(() => root.delete(recursive: true));
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    if (find.text(text).evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        find.text(text),
        180,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(find.text(text).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  void mockScanner(Future<String?> Function() scan) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'lanScanQr') return scan();
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(nativeChannel, null));
  }

  testWidgets(
    'Mobile scan cancellation, invalid QR and permission denial do not start sharing',
    (tester) async {
      try {
        await render(tester);
        mockScanner(() async => null);
        await tapText(tester, '扫码连接');
        expect(lan.starts, 0);
        expect(lan.lookedUp, isEmpty);
        expect(find.text('正在扫码…'), findsNothing);
        mockScanner(() async => 'https://example.com/unrelated');
        await tapText(tester, '扫码连接');
        expect(find.text('请扫描文析助手的设备连接二维码或文件分享二维码'), findsOneWidget);
        expect(lan.starts, 0);
        mockScanner(
          () async => throw PlatformException(
            code: 'qr_permission',
            message: '请允许相机权限后重试',
          ),
        );
        await tapText(tester, '扫码连接');
        expect(find.text('请允许相机权限后重试'), findsOneWidget);
        expect(lan.starts, 0);
        expect(lan.lookedUp, isEmpty);
        expect(lan.received, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Scanning a connection QR pairs the selected device without another PIN prompt',
    (tester) async {
      try {
        await render(tester);
        final qr = LanConnectionQr(
          address: lan.peers.single.base,
          deviceId: _peerId,
          code: '001234',
        );
        mockScanner(() async => qr.encode());
        expect(lan.starts, 0);
        await tapText(tester, '扫码连接');
        expect(lan.starts, 1);
        expect(lan.lookedUp.single, qr.address.toString());
        expect(lan.pairCodes.single, '001234');
        expect(lan.paired, isTrue);
        expect(find.text('查看对方分享的文件'), findsOneWidget);
        expect(find.byKey(const Key('lan-dialog-input')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Scanning a file QR opens confirmation and waits before downloading',
    (tester) async {
      try {
        await render(tester);
        final shared = await lan.createShare(const LanFileSelection([]));
        final url = 'http://192.168.1.10:52381/s/${shared.manifest.token}';
        mockScanner(() async => url);
        await tapText(tester, '扫码连接');
        expect(lan.received.single, url);
        expect(lan.pairCodes, isEmpty);
        expect(find.text('接收文件'), findsOneWidget);
        expect(find.byKey(const Key('lan-receive-all')), findsOneWidget);
        expect(services.downloads.tasks, isEmpty);
        expect(lan.starts, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Desktop connection QR follows address changes and disappears when stopped',
    (tester) async {
      try {
        await render(
          tester,
          platform: TargetPlatform.windows,
          size: const Size(320, 640),
          scale: 1.4,
        );
        expect(find.byKey(const Key('lan-scan-qr')), findsNothing);
        final inlineQr = find.byKey(const Key('lan-inline-qr'));
        expect(inlineQr, findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('lan-show-qr')));
        await tester.tap(find.byKey(const Key('lan-show-qr')));
        await tester.pumpAndSettle();
        final qrFinder = find.byKey(const Key('lan-connection-qr'));
        LanConnectionQr displayed() =>
            LanQrTarget.parse(lan.lastQr!) as LanConnectionQr;
        expect(displayed().address.host, '192.168.1.9');
        expect(displayed().code, '123456');
        expect(displayed().deviceId, lan.id);
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('LAN_CAPTURE_PREVIEWS')) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('lan-preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            try {
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '.local/lan-qr-sheet.png',
              ).writeAsBytes(data!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        lan.addresses = ['10.1.1.9'];
        lan.notifyListeners();
        await tester.pumpAndSettle();
        expect(displayed().address.host, '10.1.1.9');
        await lan.stop();
        await tester.pumpAndSettle();
        expect(qrFinder, findsNothing);
        expect(find.text('连接二维码已失效，请开启设备互联并连接局域网后重试。'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('lan-power')))
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Windows shows the QR on the right and enlarges the selected network address',
    (tester) async {
      try {
        await render(
          tester,
          platform: TargetPlatform.windows,
          size: const Size(1080, 760),
        );
        final allow = find.byKey(const Key('lan-allow-incoming'));
        expect(allow, findsOneWidget);
        await tester.tap(allow);
        await tester.pumpAndSettle();
        expect(lan.allowedIncoming, 1);
        final inlineQr = find.byKey(const Key('lan-inline-qr'));
        final code = find.byKey(const Key('lan-local-code'));
        expect(inlineQr, findsOneWidget);
        expect(
          tester.getTopLeft(inlineQr).dx,
          greaterThan(tester.getTopRight(code).dx),
        );
        expect(lan.starts, 1);
        await tester.tap(find.byKey(const Key('lan-device-address')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('http://10.1.1.9:52381').last);
        await tester.pumpAndSettle();
        expect(
          (LanQrTarget.parse(lan.lastQr!) as LanConnectionQr).address.host,
          '10.1.1.9',
        );
        await tester.tap(find.byKey(const Key('lan-show-qr')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('lan-connection-qr')), findsOneWidget);
        expect(
          (LanQrTarget.parse(lan.lastQr!) as LanConnectionQr).address.host,
          '10.1.1.9',
        );
        await tapText(tester, '关闭');
        await lan.stop();
        await tester.pumpAndSettle();
        expect(inlineQr, findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Desktop entry starts discovery once and preserves it after leaving the page',
    (tester) async {
      try {
        await render(tester, shell: true, platform: TargetPlatform.windows);
        expect(lan.starts, 0);
        final entry = find.byKey(const Key('parse-device-link'));
        expect(entry, findsOneWidget);
        expect(tester.getCenter(entry).dx, greaterThan(250));
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.byType(DeviceLinkPage), findsOneWidget);
        expect(lan.starts, 1);
        for (final label in ['发送文件', '发送文件夹', '分享已下载', '发送消息']) {
          expect(find.text(label), findsOneWidget);
        }
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(lan.running, isTrue);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(lan.starts, 1);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Mobile entry waits for an explicit start, including on a wide screen',
    (tester) async {
      try {
        await render(tester, shell: true, size: const Size(1080, 760));
        await tester.tap(find.byKey(const Key('parse-device-link')));
        await tester.pumpAndSettle();
        expect(lan.starts, 0);
        expect(lan.running, isFalse);
        expect(find.byKey(const Key('lan-enable')), findsOneWidget);
        await tester.tap(find.byKey(const Key('lan-enable')));
        await tester.pumpAndSettle();
        expect(lan.starts, 1);
        expect(lan.running, isTrue);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('parse-device-link')));
        await tester.pumpAndSettle();
        expect(lan.starts, 1);
        expect(find.byKey(const Key('lan-local-code')), findsOneWidget);
        await lan.stop();
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('parse-device-link')));
        await tester.pumpAndSettle();
        expect(lan.running, isFalse);
        expect(lan.starts, 1);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Text inbox can be viewed and copied while mobile sharing is off',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      try {
        await render(tester, textInbox: true);
        expect(lan.starts, 0);
        await tapText(tester, '收件箱 1');
        final send = tester.widget<FilledButton>(
          find.byKey(const Key('lan-inbox-send')),
        );
        expect(send.onPressed, isNull);
        await tapText(tester, '查看消息');
        expect(find.byKey(const Key('lan-message-content')), findsOneWidget);
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const Key('lan-message-content')),
              )
              .data,
          _message,
        );
        await tester.tap(find.text('复制消息'));
        await tester.pumpAndSettle();
        expect(copied, _message);
        expect(lan.unread, 0);
        expect(lan.starts, 0);
        expect(find.byType(DeviceLinkPage), findsOneWidget);
        expect(find.byType(BrowserPage), findsNothing);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Inbox sends plain text and retains the draft when a delivery fails',
    (tester) async {
      try {
        await render(tester, initiallyRunning: true);
        lan.paired = true;
        lan.failSend = true;
        await tapText(tester, '收件箱');
        Future<void> compose() async {
          await tester.ensureVisible(find.byKey(const Key('lan-inbox-send')));
          await tester.tap(find.byKey(const Key('lan-inbox-send')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('我的手机').last);
          await tester.pumpAndSettle();
        }

        await compose();
        await tester.enterText(
          find.byKey(const Key('lan-dialog-input')),
          _message,
        );
        await tester.tap(find.byKey(const Key('lan-dialog-confirm')));
        await tester.pumpAndSettle();
        expect(lan.sent, isEmpty);
        expect(find.text('对方暂时离线，请重新连接'), findsOneWidget);
        await compose();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('lan-dialog-input')))
              .controller!
              .text,
          _message,
        );
        lan.failSend = false;
        await tester.tap(find.byKey(const Key('lan-dialog-confirm')));
        await tester.pumpAndSettle();
        expect(lan.sent.single, (peerId: _peerId, text: _message));
        expect(find.text('消息已送达，可在对方收件箱查看'), findsOneWidget);
        expect(lan.starts, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Reply uses the sender identity instead of asking for another target',
    (tester) async {
      try {
        await render(tester, textInbox: true, initiallyRunning: true);
        lan.paired = true;
        await tapText(tester, '收件箱 1');
        await tapText(tester, '回复');
        expect(find.text('选择接收设备'), findsNothing);
        await tester.enterText(
          find.byKey(const Key('lan-dialog-input')),
          '已收到，谢谢',
        );
        await tester.tap(find.byKey(const Key('lan-dialog-confirm')));
        await tester.pumpAndSettle();
        expect(lan.sent.single, (peerId: _peerId, text: '已收到，谢谢'));
        expect(lan.unread, 0);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'A link inside a text message is parsed only after the user chooses that action',
    (tester) async {
      try {
        await render(tester, shell: true, textInbox: true, messageText: _link);
        await tester.tap(find.byKey(const Key('parse-device-link')));
        await tester.pumpAndSettle();
        await tapText(tester, '收件箱 1');
        await tapText(tester, '查看消息');
        expect(connector.links, isEmpty);
        expect(find.byKey(const Key('lan-message-content')), findsOneWidget);
        await tester.tap(find.text('解析链接'));
        await tester.pumpAndSettle();
        expect(connector.links.single.passcode, 'abcd');
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(lan.starts, 0);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Received cloud link waits for a click, then opens the existing share browser',
    (tester) async {
      try {
        await render(tester, shell: true, inbox: true);
        expect(connector.links, isEmpty);
        expect(lan.unread, 1);
        await tester.tap(find.byKey(const Key('parse-device-link')));
        await tester.pumpAndSettle();
        await tapText(tester, '收件箱 1');
        await tapText(tester, '解析链接');
        expect(connector.links, hasLength(1));
        expect(connector.links.single.passcode, 'abcd');
        expect(lan.unread, 0);
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(find.text('测试文件.txt'), findsOneWidget);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Sending files first chooses among connected devices, then sends directly',
    (tester) async {
      try {
        await render(tester, initiallyRunning: true);
        lan.paired = true;
        final tabletId = lanId();
        final offlineId = lanId();
        lan.otherPeers.addAll([
          LanPeer(
            id: tabletId,
            name: '已连接平板',
            address: '192.168.1.11',
            port: 52381,
            lastSeen: DateTime.now(),
          ),
          LanPeer(
            id: offlineId,
            name: '附近未连接电脑',
            address: '192.168.1.12',
            port: 52381,
            lastSeen: DateTime.now(),
          ),
        ]);
        lan.pairedIds.add(tabletId);
        final files = lan.files as _UiFiles;
        await tapText(tester, '发送文件');
        final sheet = find.byKey(const Key('lan-file-recipient'));
        expect(sheet, findsOneWidget);
        expect(files.pickCount, 0);
        expect(
          find.descendant(of: sheet, matching: find.text('我的手机')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sheet, matching: find.text('已连接平板')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sheet, matching: find.text('附近未连接电脑')),
          findsNothing,
        );
        await tester.tap(find.byKey(ValueKey('lan-file-recipient-$tabletId')));
        await tester.pumpAndSettle();
        expect(files.pickCount, 1);
        expect(lan.invitations, isEmpty);
        await tapText(tester, '1 小时');
        expect(lan.invitations, hasLength(1));
        expect(lan.invitations.single.peerId, tabletId);
        expect(lan.invitations.single.share, same(lan.published.single));
        expect(find.text('查看分享'), findsOneWidget);
        expect(find.byKey(const Key('lan-file-qr')), findsNothing);
        expect(lan.pairCodes, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Cancelling recipient or file selection never publishes or sends a share',
    (tester) async {
      try {
        await render(tester, initiallyRunning: true);
        lan.paired = true;
        final files = lan.files as _UiFiles;
        await tapText(tester, '发送文件');
        Navigator.of(
          tester.element(find.byKey(const Key('lan-file-recipient'))),
        ).pop();
        await tester.pumpAndSettle();
        expect(files.pickCount, 0);
        expect(lan.published, isEmpty);
        files.selection = [];
        await tapText(tester, '发送文件');
        await tester.tap(
          find.byKey(const ValueKey('lan-file-recipient-$_peerId')),
        );
        await tester.pumpAndSettle();
        expect(files.pickCount, 1);
        expect(find.text('分享有效期'), findsNothing);
        expect(lan.published, isEmpty);
        expect(lan.invitations, isEmpty);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Mobile without connections explains pairing and keeps link sharing available',
    (tester) async {
      try {
        await render(tester);
        await tapText(tester, '发送文件');
        expect(find.text('暂无已连接设备，请先扫码或输入连接码连接。'), findsOneWidget);
        expect(find.byKey(const Key('lan-file-share-link')), findsOneWidget);
        expect(lan.starts, 0);
        expect((lan.files as _UiFiles).pickCount, 0);
        expect(lan.invitations, isEmpty);
        expect(find.byKey(const Key('lan-inline-qr')), findsNothing);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Folder sending retains the share when an invitation fails and permits retry',
    (tester) async {
      try {
        await render(tester, initiallyRunning: true);
        lan.paired = true;
        lan.failSend = true;
        await tapText(tester, '发送文件夹');
        await tester.tap(
          find.byKey(const ValueKey('lan-file-recipient-$_peerId')),
        );
        await tester.pumpAndSettle();
        await tapText(tester, '直到关闭分享或退出应用');
        expect((lan.files as _UiFiles).pickedFolder, isTrue);
        expect(lan.published, hasLength(1));
        expect(lan.published.single.manifest.expiresAt, isNull);
        expect(lan.invitations, isEmpty);
        expect(find.text('对方暂时离线，请重新连接'), findsOneWidget);
        lan.failSend = false;
        await tapText(tester, '发送给设备');
        await tapText(tester, '我的手机');
        expect(lan.invitations, hasLength(1));
        expect(lan.published, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Sharing a local file provides a QR code using the selected network address',
    (tester) async {
      try {
        String? copied;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String?;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await render(tester, initiallyRunning: true);
        await tapText(tester, '发送文件');
        await tapText(tester, '生成分享链接 / 二维码');
        await tapText(tester, '1 小时');
        expect(find.byType(QrImageView), findsOneWidget);
        await tapText(tester, '复制分享链接');
        expect(copied, startsWith('http://192.168.1.9:52381/s/'));
        expect(
          tester
              .widget<SelectableText>(find.byKey(const Key('lan-share-url')))
              .data,
          copied,
        );
        expect(
          find.widgetWithText(TextButton, 'http://192.168.1.9:52381'),
          findsNothing,
        );
        await tester.ensureVisible(
          find.byType(DropdownButtonFormField<String>),
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10.1.1.9').last);
        await tester.pumpAndSettle();
        await tapText(tester, '复制分享链接');
        expect(copied, startsWith('http://10.1.1.9:52381/s/'));
        expect(
          tester
              .widget<SelectableText>(find.byKey(const Key('lan-share-url')))
              .data,
          copied,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'Receive action queues a verified file and navigates to transfer management',
    (tester) async {
      try {
        await render(tester, shell: true);
        final shared = await lan.createShare(const LanFileSelection([]));
        await tester.tap(find.byKey(const Key('parse-device-link')));
        await tester.pumpAndSettle();
        await tapText(tester, '打开分享链接');
        await tester.enterText(
          find.byKey(const Key('lan-dialog-input')),
          'http://192.168.1.9:52381/s/${shared.manifest.token}',
        );
        await tester.tap(find.byKey(const Key('lan-dialog-confirm')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('lan-receive-all')));
        for (var i = 0; i < 50 && services.downloads.tasks.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        expect(services.downloads.tasks, hasLength(1));
        expect(services.downloads.tasks.single.spec.profile, 'lan');
        expect(services.downloads.tasks.single.spec.checksumType, 'sha256');
        expect(
          services.downloads.tasks.single.destination,
          '${root.path}/saved',
        );
        expect(find.byType(DeviceLinkPage), findsNothing);
        expect(find.widgetWithText(AppBar, '传输管理'), findsOneWidget);
      } finally {
        await close(tester);
      }
    },
  );

  for (final scenario in [
    (const Size(320, 640), 1.8, false),
    (const Size(390, 844), 1.0, true),
    (const Size(1080, 760), 1.2, false),
  ]) {
    testWidgets('Device page fits $scenario', (tester) async {
      try {
        await render(
          tester,
          size: scenario.$1,
          scale: scenario.$2,
          dark: scenario.$3,
          inbox: true,
          initiallyRunning: true,
        );
        expect(tester.takeException(), isNull);
        await tapText(tester, '输入连接码');
        expect(find.byKey(const Key('lan-dialog-input')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tapText(tester, '取消');
        await tapText(tester, '收件箱 1');
        await tester.ensureVisible(find.text('解析链接'));
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    });
  }
}
