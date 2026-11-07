import 'dart:async';
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'browser_test_support.dart';

class _DropConnector extends BrowserTestConnector {
  _DropConnector() : super(CloudPlatform.quark);
  final uploaded = <(String, String, List<int>)>[];
  final folders = <CloudFile>[];
  bool writable = true, foldersWritable = true;

  @override
  bool canUploadTo(BrowseSession session, String parent) =>
      writable && super.canUploadTo(session, parent);

  @override
  bool canCreateFolderIn(BrowseSession session, String parent) =>
      foldersWritable && super.canCreateFolderIn(session, parent);

  @override
  Future<CloudFile> createFolder(
    BrowseSession session,
    String parent,
    String name,
    Credential credential,
  ) async {
    final folder = CloudFile(
      id: 'folder-${folders.length}',
      name: name,
      parentId: parent,
      isDirectory: true,
    );
    folders.add(folder);
    return folder;
  }

  @override
  Future<CloudFile> upload(
    BrowseSession session,
    String parent,
    UploadFile source,
    Credential credential, {
    UploadProgressCallback? onProgress,
  }) async {
    final bytes = await source.openRead().expand((part) => part).toList();
    uploaded.add((parent, source.name, bytes));
    return CloudFile(
      id: 'uploaded-${uploaded.length}',
      name: source.name,
      parentId: parent,
      size: bytes.length,
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parent,
    Credential? credential,
  ) async => [
    ...await super.list(session, parent, credential),
    ...folders.where((f) => f.parentId == parent),
    for (final (target, name, bytes) in uploaded)
      if (target == parent)
        CloudFile(
          id: 'uploaded-$name',
          name: name,
          parentId: parent,
          size: bytes.length,
        ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const selectorChannel = MethodChannel('plugins.flutter.io/file_selector');
  late BrowserUiFixture fixture;
  late _DropConnector connector;

  Future<void> native(String method, [Object? arguments]) async {
    final reply = Completer<void>();
    messenger.handlePlatformMessage(
      'desktop_drop',
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  Future<void> render(
    WidgetTester tester, {
    bool empty = false,
    bool picking = false,
    bool searching = false,
    BrowseSession? session,
    double pixelRatio = 1,
  }) async {
    tester.view.devicePixelRatio = pixelRatio;
    tester.view.physicalSize = Size(1100 * pixelRatio, 800 * pixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: BrowserPage(
          fixture.services,
          session ?? connector.personalSession(),
          picking: picking,
          searchPage: searching,
          initialItems: empty ? const [] : null,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Offset nativePosition(WidgetTester tester, Offset logical) =>
      Platform.isWindows ? logical * tester.view.devicePixelRatio : logical;

  Future<void> enter(WidgetTester tester, {Offset? position}) async {
    final point = nativePosition(
      tester,
      position ??
          tester.getCenter(find.byKey(const Key('cloud-upload-drop-target'))),
    );
    await native('entered', [point.dx, point.dy]);
    await tester.pump();
  }

  Future<void> release(WidgetTester tester, List<String> paths) async {
    await tester.runAsync(() => native('performOperation', paths));
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (fixture.services.uploads.tasks.isNotEmpty &&
          fixture.services.uploads.activeCount == 0) {
        break;
      }
      if (find.byType(SnackBar).evaluate().isNotEmpty &&
          fixture.services.uploads.tasks.isEmpty) {
        break;
      }
    }
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
  }

  File localFile(String name, [List<int> bytes = const [1, 2, 3, 4]]) =>
      File(p.join(fixture.directory.path, name))..writeAsBytesSync(bytes);

  void scenario(
    String name,
    Future<void> Function(WidgetTester) body, {
    TargetPlatform platform = TargetPlatform.windows,
  }) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      fixture = await BrowserUiFixture.create(platform: CloudPlatform.quark);
      connector = _DropConnector();
      fixture.services.cloud.connectors[CloudPlatform.quark] = connector;
      try {
        await body(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await native('exited');
        await tester.pumpWidget(const SizedBox.shrink());
        var closed = false;
        unawaited(fixture.close().then((_) => closed = true));
        for (var i = 0; i < 100 && !closed; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        expect(closed, isTrue);
      }
    });
  }

  scenario(
    'Finder drops upload files on macOS and clear the drag overlay',
    (tester) async {
      await render(tester, empty: true);
      final file = localFile('Mac 文件.txt');
      await enter(tester);
      expect(find.text('松开鼠标上传文件或文件夹'), findsOneWidget);
      await release(tester, [file.path]);
      expect(connector.uploaded.single.$2, 'Mac 文件.txt');
      expect(connector.uploaded.single.$3, [1, 2, 3, 4]);
      expect(
        fixture.services.uploads.tasks.single.status,
        UploadStatus.completed,
      );
      expect(find.byKey(const Key('cloud-upload-drop-overlay')), findsNothing);
    },
    platform: TargetPlatform.macOS,
  );

  scenario(
    'Explorer drops upload several files into an empty folder and refresh the list',
    (tester) async {
      await render(tester, empty: true);
      final first = localFile('中文 文件.txt'),
          second = localFile('photo.png', [8, 9]);
      expect(find.textContaining('将本地文件拖到这里上传'), findsOneWidget);
      await enter(tester);
      expect(find.text('松开鼠标上传文件或文件夹'), findsOneWidget);
      expect(find.textContaining('上传到“全部文件”'), findsOneWidget);
      await release(tester, [first.path, second.path]);
      final tasks = fixture.services.uploads.tasks;
      expect(tasks, hasLength(2));
      expect(tasks.every((t) => t.status == UploadStatus.completed), isTrue);
      expect(tasks.map((t) => t.parent), everyElement('personal-root'));
      expect(connector.uploaded.map((u) => u.$2), ['中文 文件.txt', 'photo.png']);
      expect(connector.uploaded.first.$3, [1, 2, 3, 4]);
      expect(find.byKey(const Key('cloud-upload-drop-overlay')), findsNothing);
      expect(find.text('中文 文件.txt'), findsOneWidget);
      expect(first.readAsBytesSync(), [1, 2, 3, 4]);
      expect(second.existsSync(), isTrue);
    },
  );

  scenario(
    'grid drops at high DPI use the current subfolder and deduplicate paths',
    (tester) async {
      await fixture.services.updateSettings({'browserView': 'grid'});
      await render(tester, pixelRatio: 2);
      await tester.tap(find.text('假期相册'));
      await tester.pumpAndSettle();
      final file = localFile('子目录上传.txt');
      await enter(tester);
      expect(find.textContaining('上传到“假期相册”'), findsOneWidget);
      await release(tester, [file.path, file.path]);
      expect(fixture.services.uploads.tasks, hasLength(1));
      expect(fixture.services.uploads.tasks.single.parent, 'photos');
      expect(fixture.services.uploads.tasks.single.folderName, '假期相册');
    },
  );

  scenario('dropping outside the file area never uploads', (tester) async {
    await render(tester, empty: true);
    await enter(tester, position: const Offset(1, 1));
    await native('performOperation', [localFile('outside.txt').path]);
    await tester.pumpAndSettle();
    expect(fixture.services.uploads.tasks, isEmpty);
  });

  scenario('a modal hides the drop overlay and prevents background uploads', (
    tester,
  ) async {
    await render(tester, empty: true);
    final file = localFile('dialog.txt');
    final point = tester.getCenter(
      find.byKey(const Key('cloud-upload-drop-target')),
    );
    await enter(tester);
    final context = tester.element(find.byType(BrowserPage));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) =>
            const AlertDialog(title: Text('已有弹窗'), content: Text('请先关闭弹窗')),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await native('performOperation', [file.path]);
    await tester.pumpAndSettle();
    expect(fixture.services.uploads.tasks, isEmpty);
    expect(
      find.byKey(const Key('cloud-upload-drop-overlay'), skipOffstage: false),
      findsNothing,
    );
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();
    await enter(tester, position: point);
    await release(tester, [file.path]);
    expect(
      fixture.services.uploads.tasks.single.status,
      UploadStatus.completed,
    );
  });

  scenario(
    'leaving the browser prevents its retained route from receiving drops',
    (tester) async {
      await render(tester, empty: true);
      final point = nativePosition(
        tester,
        tester.getCenter(find.byKey(const Key('cloud-upload-drop-target'))),
      );
      unawaited(
        Navigator.of(tester.element(find.byType(BrowserPage))).push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold(body: Text('其他页面'))),
        ),
      );
      await tester.pumpAndSettle();
      await native('entered', [point.dx, point.dy]);
      await native('performOperation', [localFile('background.txt').path]);
      await tester.pumpAndSettle();
      expect(fixture.services.uploads.tasks, isEmpty);
    },
  );

  scenario(
    'mixed folder and file drops preserve the tree and deduplicate nested selections',
    (tester) async {
      await render(tester, empty: true);
      final file = localFile('valid.txt');
      final directory = Directory(p.join(fixture.directory.path, 'folder'))
        ..createSync();
      final nested = File(p.join(directory.path, 'sub', 'same.txt'));
      nested.parent.createSync(recursive: true);
      nested.writeAsBytesSync([6, 7]);
      Directory(p.join(directory.path, 'empty')).createSync();
      await enter(tester);
      await release(tester, [
        file.path,
        nested.path,
        directory.path,
        nested.parent.path,
        directory.path,
      ]);
      final tasks = fixture.services.uploads.tasks;
      expect(tasks, hasLength(2));
      expect(tasks.every((t) => t.status == UploadStatus.completed), isTrue);
      expect(tasks.where((t) => t.isFolder).single.folder!.files, hasLength(1));
      final root = connector.folders.singleWhere((f) => f.name == 'folder');
      final sub = connector.folders.singleWhere((f) => f.name == 'sub');
      expect(root.parentId, 'personal-root');
      expect(sub.parentId, root.id);
      expect(
        connector.folders.singleWhere((f) => f.name == 'empty').parentId,
        root.id,
      );
      expect(connector.uploaded.map((f) => (f.$1, f.$2)), [
        ('personal-root', 'valid.txt'),
        (sub.id, 'same.txt'),
      ]);
      expect(connector.uploaded.map((f) => f.$3).toList(), [
        [1, 2, 3, 4],
        [6, 7],
      ]);
      expect(file.existsSync(), isTrue);
      expect(nested.readAsBytesSync(), [6, 7]);
    },
  );

  scenario('file-only destinations reject mixed folder drops atomically', (
    tester,
  ) async {
    connector.foldersWritable = false;
    await render(tester, empty: true);
    final file = localFile('valid.txt');
    final folder = Directory(p.join(fixture.directory.path, 'folder'))
      ..createSync();
    await enter(tester);
    expect(find.text('松开鼠标上传文件'), findsOneWidget);
    await release(tester, [file.path, folder.path]);
    expect(fixture.services.uploads.tasks, isEmpty);
    expect(find.text('当前目录不支持上传文件夹'), findsOneWidget);
  });

  scenario('the add menu folder picker queues the whole selected directory', (
    tester,
  ) async {
    final folder = Directory(p.join(fixture.directory.path, 'picker-folder'))
      ..createSync();
    File(p.join(folder.path, 'one.txt')).writeAsBytesSync([4, 5]);
    messenger.setMockMethodCallHandler(selectorChannel, (call) async {
      expect(call.method, 'getDirectoryPath');
      expect(call.arguments['confirmButtonText'], '上传此文件夹');
      return folder.path;
    });
    try {
      await render(tester, empty: true);
      await tester.tap(find.byKey(const Key('browser-add-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上传文件夹'));
      for (var i = 0; i < 70; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (fixture.services.uploads.tasks.isNotEmpty &&
            fixture.services.uploads.activeCount == 0) {
          break;
        }
      }
      await tester.pumpAndSettle();
      final task = fixture.services.uploads.tasks.single;
      expect(task.isFolder, isTrue);
      expect(task.status, UploadStatus.completed, reason: task.error);
      expect(task.name, 'picker-folder');
      expect(connector.uploaded.single.$2, 'one.txt');
      expect(connector.uploaded.single.$3, [4, 5]);
      await tester.tap(find.byKey(const Key('browser-add-menu')));
      await tester.pumpAndSettle();
      expect(find.text('上传文件夹'), findsOneWidget);
    } finally {
      messenger.setMockMethodCallHandler(selectorChannel, null);
    }
  });

  scenario('a missing file fails before any upload task is created', (
    tester,
  ) async {
    await render(tester, empty: true);
    await enter(tester);
    await release(tester, [p.join(fixture.directory.path, 'missing.txt')]);
    expect(fixture.services.uploads.tasks, isEmpty);
    expect(find.text('无法读取拖入的文件，请检查文件是否存在及访问权限'), findsOneWidget);
  });

  scenario('changing account credentials while hovering disables upload', (
    tester,
  ) async {
    await render(tester, empty: true);
    final file = localFile('account.txt');
    await enter(tester);
    await fixture.services.vault.putCredential(
      CloudPlatform.quark,
      Credential('更新的账号', {'primary': 'updated'}, updatedAt: 2),
    );
    await tester.pumpAndSettle();
    await native('performOperation', [file.path]);
    await tester.pumpAndSettle();
    expect(fixture.services.uploads.tasks, isEmpty);
    expect(find.byKey(const Key('cloud-upload-drop-overlay')), findsNothing);
  });

  for (final mode in ['share', 'picking', 'search', 'readonly']) {
    scenario('$mode views do not accept files for upload', (tester) async {
      if (mode == 'readonly') connector.writable = false;
      await render(
        tester,
        empty: true,
        picking: mode == 'picking',
        searching: mode == 'search',
        session: mode == 'share'
            ? const BrowseSession(
                platform: CloudPlatform.quark,
                mode: BrowseMode.share,
                title: '分享文件',
                rootId: 'share-root',
              )
            : null,
      );
      for (final target in tester.widgetList<DropTarget>(
        find.byType(DropTarget),
      )) {
        expect(target.enable, isFalse);
      }
      final point = nativePosition(tester, const Offset(400, 450));
      await native('entered', [point.dx, point.dy]);
      await native('performOperation', [localFile('disabled.txt').path]);
      await tester.pumpAndSettle();
      expect(fixture.services.uploads.tasks, isEmpty);
    });
  }

  scenario(
    'Android retains the file picker without enabling the Windows drop target',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await render(tester, empty: true);
      expect(find.byType(DropTarget), findsNothing);
      expect(find.byKey(const Key('browser-add-menu')), findsOneWidget);
      await tester.tap(find.byKey(const Key('browser-add-menu')));
      await tester.pumpAndSettle();
      expect(find.text('上传文件夹'), findsOneWidget);
      expect(find.textContaining('将本地文件拖到这里上传'), findsNothing);
    },
  );
}
