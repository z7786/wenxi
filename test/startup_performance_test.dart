import 'dart:async';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/diagnostics/diagnostic_runtime.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/external_open.dart';
import 'package:asterlink/platform/native_engine.dart' show nativeChannel;
import 'package:asterlink/ui/cloud_page.dart';
import 'package:asterlink/ui/mine_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'package:asterlink/ui/resource_home_page.dart';
import 'package:asterlink/ui/startup_loading_page.dart';
import 'package:asterlink/ui/transfers_page.dart';
import 'package:asterlink/upload/upload_manager.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'support.dart';

class _StartupStore extends ChangeNotifier implements StateStore {
  _StartupStore(Json initial) : delegate = StateStore.memory(initial) {
    delegate.addListener(notifyListeners);
  }
  final StateStore delegate;
  final _writes = AsyncGate();
  final snapshots = <Json>[];
  Completer<void>? barrier;
  int requestedWrites = 0;

  @override
  Json get data => delegate.data;

  @override
  Future<T> change<T>(T Function(Json draft) edit, {String? recoveryPassword}) {
    requestedWrites++;
    return _writes.run(() async {
      await barrier?.future;
      final result = await delegate.change(
        edit,
        recoveryPassword: recoveryPassword,
      );
      final snapshot = StateStore.memory(data);
      snapshots.add(snapshot.data);
      snapshot.dispose();
      return result;
    });
  }

  @override
  Future<void> put(String key, Object? value) => change<void>((draft) {
    draft[key] = value;
  });

  @override
  Future<void> flush() => _writes.run(delegate.flush);

  void release() {
    barrier?.complete();
    barrier = null;
  }

  @override
  void dispose() {
    delegate.removeListener(notifyListeners);
    delegate.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadTask _download(
  String id, {
  DownloadStatus status = DownloadStatus.paused,
  DownloadCleanup? cleanup,
}) => DownloadTask(
  id: id,
  createdAt: 1,
  status: status,
  downloaded: 1024,
  total: 4096,
  speed: status == DownloadStatus.running ? 2048 : 0,
  spec: DownloadSpec(
    url: 'https://download.example.test/video.mp4',
    fileName: '$id.mp4',
    cleanup: cleanup,
  ),
);

UploadTask _upload(String id, {UploadStatus status = UploadStatus.completed}) =>
    UploadTask(
      id: id,
      session: const BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'Files',
        rootId: '0',
        metadata: {'accountId': 'fixture-account'},
      ),
      parent: '0',
      folderName: 'Files',
      accountName: 'fixture',
      path: '$id.mp4',
      name: '$id.mp4',
      size: 4096,
      modifiedAt: 1,
      createdAt: 1,
      status: status,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  AppServices services(StateStore store, {bool platformFeatures = false}) =>
      AppServices(
        store: store,
        dataDirectory: Directory('test-fixture/startup-performance'),
        cacheDirectory: Directory('test-fixture/startup-performance/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('test-fixture/startup-performance/saved')),
        http: FakeHttp(),
        platformFeatures: platformFeatures,
        controlEnabled: false,
        announcementsUrl: '',
      );

  Future<void> closeUi(WidgetTester tester, AppServices app) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    final closing = app.close().whenComplete(() => closed = true);
    for (var i = 0; i < 100 && !closed; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(closed, isTrue, reason: 'Fixture services must finish closing');
    await closing;
    app.store.dispose();
  }

  setUp(() {
    // Tests that use the real runtime read an explicitly disabled preference.
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.asterlink.app/window_theme'),
      (_) async => null,
    );
  });
  tearDown(() {
    DiagnosticRuntime.stop();
    DiagnosticLog.active = null;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.asterlink.app/window_theme'),
      null,
    );
    messenger.setMockMethodCallHandler(windowsExternalOpenChannel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
  });

  testWidgets(
    'Splash submits before a slow diagnostics preference read',
    (tester) async {
      const channel = MethodChannel('com.asterlink.app/diagnostics');
      final preference = Completer<Object?>();
      final loaded = Completer<AppServices>();
      final phases = <SchedulerPhase>[];
      var loads = 0;
      final logDirectory = Directory.systemTemp.createTempSync(
        'asterlink-startup-logs-',
      );
      final app = services(StateStore.memory());
      messenger.setMockMethodCallHandler(channel, (call) {
        expect(call.method, 'diagnosticPaths');
        phases.add(SchedulerBinding.instance.schedulerPhase);
        return preference.future;
      });
      try {
        await tester.pumpWidget(
          Builder(
            builder: (_) {
              expect(phases, isEmpty);
              return AppBootstrap(
                initializeRuntime: () async => await DiagnosticRuntime.start(),
                servicesLoader: () {
                  loads++;
                  return loaded.future;
                },
              );
            },
          ),
        );
        expect(find.byType(StartupLoadingPage), findsOneWidget);
        expect(phases, [SchedulerPhase.idle]);
        await tester.pump(const Duration(seconds: 2));
        expect(loads, 0);
        expect(DiagnosticLog.active, isNull);
        preference.complete({'logs': logDirectory.path, 'enabled': false});
        await tester.pump();
        expect(loads, 1);
        expect(DiagnosticLog.active!.enabled, isFalse);
        expect(DiagnosticLog.active!.entries(), isEmpty);
        expect(find.byType(StartupLoadingPage), findsOneWidget);
        loaded.complete(app);
        await tester.pump();
        expect(find.byType(MainShell), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!preference.isCompleted) {
          preference.complete({'logs': logDirectory.path, 'enabled': false});
        }
        if (!loaded.isCompleted) loaded.complete(app);
        await closeUi(tester, app);
        messenger.setMockMethodCallHandler(channel, null);
        DiagnosticRuntime.stop();
        logDirectory.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets('Failed startup can retry without a minimum splash delay', (
    tester,
  ) async {
    final app = services(StateStore.memory());
    var attempts = 0, runtimeStarts = 0;
    try {
      await tester.pumpWidget(
        AppBootstrap(
          initializeRuntime: () async {
            runtimeStarts++;
          },
          servicesLoader: () async {
            if (++attempts == 1) {
              throw const AppException('fixture startup failure');
            }
            return app;
          },
        ),
      );
      await tester.pump();
      expect(find.byType(StartupFailurePage), findsOneWidget);
      expect(find.text('fixture startup failure'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump();
      expect(attempts, 2);
      expect(runtimeStarts, 1);
      expect(find.byType(MainShell), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await closeUi(tester, app);
    }
  });

  testWidgets(
    'Startup retry continues when the app is paused before the next frame',
    (tester) async {
      final app = services(StateStore.memory());
      var attempts = 0;
      try {
        await tester.pumpWidget(
          AppBootstrap(
            initializeRuntime: () async {},
            servicesLoader: () async {
              if (++attempts == 1) throw const AppException('fixture retry');
              return app;
            },
          ),
        );
        await tester.pump();
        expect(find.byType(StartupFailurePage), findsOneWidget);
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.tap(find.text('重试'));
        expect(tester.binding.hasScheduledFrame, isFalse);
        // Do not supply another frame: a screen-off engine must still recover.
        await tester.pump(const Duration(seconds: 1));
        expect(attempts, 2);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await closeUi(tester, app);
      }
    },
  );

  testWidgets('Only first-visited tabs build and their state is retained', (
    tester,
  ) async {
    final app = services(StateStore.memory());
    try {
      await tester.pumpWidget(AsterLinkApp(app));
      final parser = tester.state<ParsePageState>(find.byType(ParsePage));
      parser.input.text = 'fixture parser input';
      for (final type in [
        ResourceHomePage,
        CloudPage,
        TransfersPage,
        MinePage,
      ]) {
        expect(find.byType(type, skipOffstage: false), findsNothing);
      }
      await tester.tap(find.byKey(const ValueKey('navigation-1')));
      await tester.pump();
      final resource = tester.state(find.byType(ResourceHomePage));
      expect(TickerMode.valuesOf(resource.context).enabled, isTrue);
      await tester.tap(find.byKey(const ValueKey('navigation-3')));
      await tester.pump();
      expect(find.byType(TransfersPage), findsOneWidget);
      expect(TickerMode.valuesOf(resource.context).enabled, isFalse);
      expect(find.byType(CloudPage, skipOffstage: false), findsNothing);
      await tester.tap(find.byKey(const ValueKey('navigation-1')));
      await tester.pump();
      expect(tester.state(find.byType(ResourceHomePage)), same(resource));
      await tester.tap(find.byKey(const ValueKey('navigation-0')));
      await tester.pump();
      expect(
        tester.state<ParsePageState>(find.byType(ParsePage)),
        same(parser),
      );
      expect(parser.input.text, 'fixture parser input');
      expect(tester.takeException(), isNull);
    } finally {
      await closeUi(tester, app);
    }
  });

  test(
    'Settled account, upload and download history skips a busy write queue',
    () async {
      final store = _StartupStore({
        'schema': 1,
        'baiduConnectionsPolicy': 1,
        'tasks': [
          for (var i = 0; i < 400; i++)
            _download('history-$i', status: DownloadStatus.completed).toJson(),
        ],
        'uploadTasks': [
          for (var i = 0; i < 400; i++) _upload('upload-$i').toJson(),
        ],
      })..barrier = Completer<void>();
      final app = services(store);
      try {
        await app.initialize().timeout(const Duration(seconds: 2));
        expect(store.requestedWrites, 0);
        expect(app.downloads.tasks, hasLength(400));
        expect(app.uploads.tasks, hasLength(400));
        expect((app.engine.transport as FakeNative).openCount, 0);
      } finally {
        store.release();
        await app.close();
        store.dispose();
      }
    },
  );

  test(
    'Account migration compares only account data and preserves newer login revisions',
    () async {
      final credential = Credential('fixture', {
        'primary': 'fixture-cookie',
      }, updatedAt: 1);
      final store = _StartupStore({
        'credentials': {CloudPlatform.quark.key: credential.toJson()},
      });
      final vault = Vault(store);
      try {
        await vault.initializeAccounts();
        expect(store.requestedWrites, 1);
        final snapshot = StateStore.memory(store.data);
        final original = snapshot.data;
        snapshot.dispose();
        store.barrier = Completer<void>();
        await Vault(
          store,
        ).initializeAccounts().timeout(const Duration(seconds: 2));
        expect(store.requestedWrites, 1);
        expect(
          const DeepCollectionEquality().equals(original, store.data),
          isTrue,
        );
        store.release();
        await store.put('credentials', {
          CloudPlatform.quark.key: Credential('fixture', {
            'primary': 'updated-cookie',
          }, updatedAt: 2).toJson(),
        });
        await vault.initializeAccounts();
        expect(
          vault
              .credentialFor(
                CloudPlatform.quark,
                vault.activeAccountId(CloudPlatform.quark),
              )!
              .updatedAt,
          2,
        );
        expect(
          store.data
              .obj('cloudAccounts')
              .obj(CloudPlatform.quark.key)
              .obj(vault.activeAccountId(CloudPlatform.quark)!)
              .obj('credential')
              .integer('updatedAt'),
          2,
        );
      } finally {
        store.release();
        store.dispose();
      }
    },
  );

  test(
    'Interrupted queue and orphan cleanup commit together before recovery',
    () async {
      const orphan = DownloadCleanup(
        url: 'https://cleanup.example.test/orphan',
      );
      const shared = DownloadCleanup(
        url: 'https://cleanup.example.test/shared',
      );
      final store = _StartupStore({
        'baiduConnectionsPolicy': 1,
        'tasks': [
          _download(
            'interrupted',
            status: DownloadStatus.running,
            cleanup: shared,
          ).toJson(),
        ],
        'cleanups': {
          cleanupKey(orphan): {'payload': orphan.toJson(), 'ready': false},
          cleanupKey(shared): {'payload': shared.toJson(), 'ready': false},
        },
      });
      final app = services(store);
      try {
        await app.downloads.initialize();
        final committed = store.snapshots.first;
        expect(committed.list('tasks').single.str('status'), 'paused');
        expect(committed.list('tasks').single.integer('speed'), 0);
        expect(committed['downloadRecovery'], ['interrupted']);
        expect(
          committed.obj('cleanups').obj(cleanupKey(orphan)).boolean('ready'),
          isTrue,
        );
        expect(
          committed.obj('cleanups').obj(cleanupKey(shared)).boolean('ready'),
          isFalse,
        );
        expect((app.engine.transport as FakeNative).openCount, 0);
      } finally {
        await app.close();
        store.dispose();
      }
    },
  );

  test(
    'Upload restore repairs active records, secrets and invalid duplicates once',
    () async {
      final invalid = _upload('same-id').toJson();
      invalid['session'] = const BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'Files',
        rootId: '0',
      ).toJson();
      final active = _upload('active', status: UploadStatus.running).toJson();
      active['session'] = {
        ...active.obj('session'),
        'metadata': {
          'accountId': 'fixture-account',
          'cookie': 'private-old-session',
        },
      };
      final store = _StartupStore({
        'uploadTasks': [
          invalid,
          _upload('same-id').toJson(),
          active,
          active,
          false,
        ],
      });
      final http = FakeHttp();
      final cloud = CloudRepository(
        http,
        Vault(store),
        CleanupOutbox(store, http),
      );
      final manager = UploadManager(store: store, cloud: cloud);
      try {
        await manager.initialize();
        expect(manager.tasks, hasLength(2));
        expect(manager.task('same-id'), isNotNull);
        expect(manager.task('active')!.status, UploadStatus.interrupted);
        expect(store.requestedWrites, 1);
        expect(
          store.data.list('uploadTasks').last.obj('session').obj('metadata'),
          {'accountId': 'fixture-account'},
        );
        await manager.close();
        manager.dispose();
        final restored = UploadManager(store: store, cloud: cloud);
        final writes = store.requestedWrites;
        try {
          await restored.initialize();
          expect(store.requestedWrites, writes);
        } finally {
          await restored.close();
          restored.dispose();
        }
      } finally {
        store.dispose();
      }
    },
  );

  for (final failed in [false, true]) {
    test(
      'Native incoming-file read cannot block startup and ${failed ? 'failure permits retry' : 'late files remain available'}',
      () async {
        final inbox = Completer<List<Object?>>();
        var reads = 0;
        messenger.setMockMethodCallHandler(windowsExternalOpenChannel, (call) {
          expect(call.method, 'takeExternalOpens');
          return ++reads == 1 ? inbox.future : Future.value(<Object?>[]);
        });
        messenger.setMockMethodCallHandler(nativeChannel, (_) async => null);
        final store = _StartupStore({});
        final app = services(store, platformFeatures: true);
        try {
          await app.initialize().timeout(const Duration(seconds: 1));
          expect(store.data.integer('baiduConnectionsPolicy'), 1);
          expect(app.downloads.tasks, isEmpty);
          if (failed) {
            inbox.completeError(
              PlatformException(code: 'fixture-inbox-failure'),
            );
            await Future<void>.delayed(Duration.zero);
            await app.externalOpens.refresh();
            expect(reads, 2);
          } else {
            inbox.complete([
              {
                'id': 'late-entry',
                'kind': 'share',
                'text': 'https://pan.quark.cn/s/tgcourse',
              },
            ]);
            await until(() => app.externalOpens.hasPending);
            expect(app.externalOpens.take()!.id, 'late-entry');
          }
        } finally {
          if (!inbox.isCompleted) inbox.complete([]);
          await app.close();
          store.dispose();
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
