import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/main.dart';
import 'support.dart';
import 'torrent_test.dart' show testTorrent;

class _BtNative extends FakeNative {
  int peers = 7;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method != 'snapshot') return result;
    return {
      ...asJson(result),
      'bt': {
        'connected': peers,
        'known': 32,
        'seeders': 2,
        'webseeds': 1,
        'trackers': 8,
        'uploadLimit': 256 * 1024,
        'sessionReused': true,
      },
    };
  }
}

void main() {
  test('BT upload limit preserves default, explicit limit and unlimited', () {
    expect(AppSettings.fromJson({}).btUploadLimit, 512 * 1024);
    expect(
      AppSettings.fromJson({'btUploadLimit': 0}).update({}).btUploadLimit,
      0,
    );
    expect(
      AppSettings.fromJson({'btUploadLimit': 65536}).toJson()['btUploadLimit'],
      65536,
    );
  });
  testWidgets(
    'BT live sources update without byte progress and disappear on pause',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 864);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      late Directory root;
      late AppServices services;
      late String id;
      final native = _BtNative()..finish = false;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('aster-bt-sources-');
        services = AppServices(
          controlEnabled: false,
          store: StateStore.memory({
            'settings': {'btUploadLimit': 256 * 1024},
          }),
          dataDirectory: Directory('${root.path}/state'),
          cacheDirectory: Directory('${root.path}/cache'),
          transport: native,
          files: FakeFiles(Directory('${root.path}/saved')),
          http: FakeHttp(),
          platformFeatures: false,
        );
        await services.downloads.initialize();
        id = (await services.downloads.enqueueTorrent(testTorrent, [0])).single;
        await until(() => services.downloads.btSources(id) != null);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await services.close();
          await root.delete(recursive: true);
        });
      });
      expect(native.begins.single['btUploadLimit'], 256 * 1024);
      await tester.pumpWidget(AsterLinkApp(services, initialTab: 3));
      await tester.pumpAndSettle();
      final badge = find.byKey(ValueKey('download-connections-$id'));
      expect(tester.widget<Text>(badge).data, '8 来源');
      await tester.tap(find.byKey(ValueKey('download-row-$id')));
      await tester.pumpAndSettle();
      expect(find.textContaining('完整做种者 2'), findsOneWidget);
      expect(find.textContaining('已复用同种子连接'), findsOneWidget);
      native.peers = 3;
      await tester.runAsync(
        () => until(() => services.downloads.btSources(id)?.connected == 3),
      );
      await tester.pump();
      expect(tester.widget<Text>(badge).data, '4 来源');
      await tester.runAsync(() => services.downloads.pause(id));
      await tester.pumpAndSettle();
      expect(find.textContaining('完整做种者'), findsNothing);
      expect(tester.widget<Text>(badge).data, 'BT');
      expect(tester.takeException(), isNull);
    },
  );
}
