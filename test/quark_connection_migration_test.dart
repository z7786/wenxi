import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'support.dart';

class _MigrationHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"migration-fixture"', null), false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Quark direct connection migration', () {
    for (final previous in [null, 0, 1, 8, 64, 128, 256, 512]) {
      test('legacy override $previous adopts 512 without changing input', () {
        final saved = <String, dynamic>{
          'threads': 16,
          'concurrent': 7,
          'downloadThreadOverrides': {
            'quark_route_1': ?previous,
            'quark_route_2': 4,
            'uc': 128,
            'xunlei': 16,
          },
        };
        final upgraded = AppSettings.fromJson(saved);
        expect(upgraded.connectionsFor(CloudPlatform.quark), 512);
        expect(upgraded.threadOverrides, isNot(contains('quark_route_1')));
        expect(
          upgraded.connectionsFor(CloudPlatform.quark, 'quark_route_1'),
          512,
        );
        expect(
          upgraded.connectionsFor(CloudPlatform.quark, 'quark_route_2'),
          4,
        );
        expect(upgraded.connectionsFor(CloudPlatform.uc), 128);
        expect(upgraded.connectionsFor(CloudPlatform.xunlei), 16);
        expect(upgraded.threads, 16);
        expect(upgraded.concurrent, 7);
        expect(saved.obj('downloadThreadOverrides')['quark_route_1'], previous);
        expect(
          upgraded.toJson().integer('quarkDirectConnectionPolicy'),
          AppSettings.quarkDirectConnectionPolicyVersion,
        );
      });
    }

    test('manual choices and global inheritance survive after migration', () {
      final upgraded = AppSettings.fromJson({
        'threads': 16,
        'downloadThreadOverrides': {'quark_route_1': 128, 'quark_route_2': 4},
      });
      for (final chosen in [0, 1, 8, 64, 128, 256, 512]) {
        final custom = upgraded.update({
          'downloadThreadOverrides': {
            ...upgraded.threadOverrides,
            'quark_route_1': chosen,
          },
        });
        final restored = AppSettings.fromJson(custom.toJson());
        expect(restored.threadOverrides['quark_route_1'], chosen);
        expect(
          restored.connectionsFor(CloudPlatform.quark),
          chosen == 0 ? 16 : chosen,
        );
        expect(
          restored.connectionsFor(CloudPlatform.quark, 'quark_route_2'),
          4,
        );
        if (chosen == 0) {
          expect(
            restored
                .update({'threads': 32})
                .connectionsFor(CloudPlatform.quark),
            32,
          );
        }
      }
      final preset = upgraded.update({
        'downloadThreadOverrides': upgraded.threadOverrides,
      });
      expect(
        AppSettings.fromJson(
          preset.toJson(),
        ).connectionsFor(CloudPlatform.quark),
        512,
      );
      expect(const AppSettings().connectionsFor(CloudPlatform.quark), 512);
    });

    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('aster-quark-upgrade-');
    });
    tearDown(() async {
      await root.delete(recursive: true);
    });

    AppServices servicesFor(StateStore store, {FakeNative? native}) {
      final services = AppServices(
        store: store,
        dataDirectory: Directory('${root.path}/state'),
        cacheDirectory: Directory('${root.path}/cache'),
        transport: native ?? FakeNative(),
        files: FakeFiles(Directory('${root.path}/saved')),
        http: FakeHttp(),
        transferHttp: _MigrationHttp(),
        platformFeatures: false,
        controlEnabled: false,
      );
      addTearDown(services.close);
      return services;
    }

    test(
      'startup persists migration before tasks and preserves later choices',
      () async {
        final stateDirectory = Directory('${root.path}/state');
        final store = await StateStore.open(stateDirectory);
        const oldTask = DownloadTask(
          id: 'old-quark-video',
          spec: DownloadSpec(
            url: 'https://example.test/old-video',
            fileName: 'old.mkv',
            expectedSize: 4,
            source: {'platform': 'Quark'},
          ),
          createdAt: 1,
          status: DownloadStatus.paused,
          connections: 128,
        );
        final legacySettings = <String, dynamic>{
          'threads': 16,
          'concurrent': 7,
          'retries': 2,
          'speedLimit': 4096,
          'destination': '${root.path}/saved',
          'quarkAuthenticatedDirectDownload': true,
          'downloadThreadOverrides': {
            'quark_route_1': 0,
            'quark_route_2': 4,
            'uc': 128,
          },
          'futurePreference': {'keep': true},
        };
        await store.change((draft) {
          draft['settings'] = legacySettings;
          draft['tasks'] = [oldTask.toJson()];
        });
        final native = FakeNative();
        final services = servicesFor(store, native: native);
        await services.initialize();
        final expectedSettings = <String, dynamic>{
          ...legacySettings,
          'downloadThreadOverrides': {'quark_route_2': 4, 'uc': 128},
          'quarkDirectConnectionPolicy':
              AppSettings.quarkDirectConnectionPolicyVersion,
        };
        expect(store.data.obj('settings'), expectedSettings);
        expect(services.settings.connectionsFor(CloudPlatform.quark), 512);
        expect(services.downloads.task(oldTask.id)!.connections, 128);

        final persisted = await StateStore.open(stateDirectory);
        expect(persisted.data.obj('settings'), expectedSettings);
        persisted.dispose();

        await services.downloads.resume(oldTask.id);
        await until(
          () =>
              services.downloads.task(oldTask.id)!.status ==
              DownloadStatus.completed,
        );
        expect(native.begins.last['connections'], 128);
        for (final (fileName, profile, count) in [
          ('file.bin', null, 512),
          ('video.mkv', 'quark_route_1', 512),
          ('quick.mp4', 'quark_route_2', 4),
        ]) {
          final id = await services.downloads.enqueue(
            DownloadSpec(
              url: 'https://example.test/$fileName',
              fileName: fileName,
              expectedSize: 4,
              source: const {'platform': 'Quark'},
              profile: profile,
            ),
          );
          await until(
            () =>
                services.downloads.task(id)!.status == DownloadStatus.completed,
          );
          expect(services.downloads.task(id)!.connections, count);
          expect(native.begins.last['connections'], count);
        }
        await services.close();
        store.dispose();

        final reopenedStore = await StateStore.open(stateDirectory);
        final reopened = servicesFor(reopenedStore);
        await reopened.initialize();
        expect(reopened.settings.connectionsFor(CloudPlatform.quark), 512);
        await reopened.updateSettings({
          'downloadThreadOverrides': {
            ...reopened.settings.threadOverrides,
            'quark_route_1': 64,
          },
        });
        await reopened.close();
        reopenedStore.dispose();

        final customStore = await StateStore.open(stateDirectory);
        final custom = servicesFor(customStore);
        await custom.initialize();
        expect(custom.settings.connectionsFor(CloudPlatform.quark), 64);
        await custom.updateSettings({
          'downloadThreadOverrides': {
            ...custom.settings.threadOverrides,
            'quark_route_1': 0,
          },
        });
        await custom.close();
        customStore.dispose();

        final globalStore = await StateStore.open(stateDirectory);
        final global = servicesFor(globalStore);
        await global.initialize();
        expect(global.settings.connectionsFor(CloudPlatform.quark), 16);
        expect(global.settings.threadOverrides['quark_route_1'], 0);
        expect(
          global.settings.connectionsFor(CloudPlatform.quark, 'quark_route_2'),
          4,
        );
        await global.close();
        globalStore.dispose();
      },
    );

    test(
      'missing settings remain available for a later legacy import',
      () async {
        final store = StateStore.memory();
        final services = servicesFor(store);
        await services.initialize();
        expect(store.data, isNot(contains('settings')));
        expect(services.settings.connectionsFor(CloudPlatform.quark), 512);
        await services.updateSettings({'threads': 16});
        expect(
          store.data.obj('settings').integer('quarkDirectConnectionPolicy'),
          1,
        );
        await services.close();
        store.dispose();
      },
    );

    test(
      'failed persistence keeps old settings and retries on next startup',
      () async {
        final stateDirectory = Directory('${root.path}/state');
        final store = await StateStore.open(stateDirectory);
        final legacySettings = <String, dynamic>{
          'downloadThreadOverrides': {'quark_route_1': 128},
        };
        await store.put('settings', legacySettings);
        final blocker = await Directory('${store.file!.path}.tmp').create();
        final services = servicesFor(store);
        await expectLater(
          services.initialize(),
          throwsA(isA<FileSystemException>()),
        );
        expect(store.data.obj('settings'), legacySettings);
        final persisted = await StateStore.open(stateDirectory);
        expect(persisted.data.obj('settings'), legacySettings);
        persisted.dispose();
        await blocker.delete();
        await services.close();
        store.dispose();

        final retryStore = await StateStore.open(stateDirectory);
        final retried = servicesFor(retryStore);
        await retried.initialize();
        expect(retried.settings.connectionsFor(CloudPlatform.quark), 512);
        expect(
          retryStore.data
              .obj('settings')
              .integer('quarkDirectConnectionPolicy'),
          1,
        );
        await retried.close();
        retryStore.dispose();
      },
    );

    test(
      'old backup migrates once and new backup restores manual choices',
      () async {
        final store = StateStore.memory();
        final backup = BackupRepository(store);
        final oldBytes = encodePlainBackup({
          'package': 'com.asterlink.app',
          'schema': 1,
          'settings': {
            'threads': 16,
            'downloadThreadOverrides': {
              'quark_route_1': 128,
              'quark_route_2': 4,
            },
          },
        });
        await backup.restore(oldBytes, '');
        final upgraded = AppSettings.fromJson(store.data.obj('settings'));
        expect(upgraded.connectionsFor(CloudPlatform.quark), 512);
        expect(
          upgraded.connectionsFor(CloudPlatform.quark, 'quark_route_2'),
          4,
        );
        expect(
          store.data.obj('settings').integer('quarkDirectConnectionPolicy'),
          1,
        );
        await store.put(
          'settings',
          upgraded.update({
            'downloadThreadOverrides': {
              ...upgraded.threadOverrides,
              'quark_route_1': 32,
            },
          }).toJson(),
        );
        final newBytes = await backup.create('');
        final restoredStore = StateStore.memory();
        await BackupRepository(restoredStore).restore(newBytes, '');
        final restored = AppSettings.fromJson(
          restoredStore.data.obj('settings'),
        );
        expect(restored.connectionsFor(CloudPlatform.quark), 32);
        expect(
          restored.connectionsFor(CloudPlatform.quark, 'quark_route_2'),
          4,
        );
        store.dispose();
        restoredStore.dispose();
      },
    );
  });
}
