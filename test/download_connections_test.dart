import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/main.dart';
import 'support.dart';

class _ConnectionHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"counts-fixture"', null), false);
}

class _ConnectionNative extends FakeNative {
  int active = 7;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method != 'snapshot') return result;
    return {
      ...asJson(result),
      'activeConnections': active,
      'totalConnections': 16,
    };
  }
}

void main() {
  testWidgets(
    'account direct settings show effective limit and bound custom and global connections',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 864);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late AppServices services;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('aster-direct-settings-');
        services = AppServices(
          controlEnabled: false,
          store: StateStore.memory({
            'settings': {
              'threads': 64,
              'downloadThreadOverrides': {'baidu_direct': 512},
            },
          }),
          dataDirectory: Directory('${root.path}/state'),
          cacheDirectory: Directory('${root.path}/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('${root.path}/saved')),
          http: FakeHttp(),
          platformFeatures: false,
        );
        await services.downloads.initialize();
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await services.close();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(AsterLinkApp(services, initialTab: 4));
      await tester.pumpAndSettle();
      Future<void> tap(Finder target) async {
        await tester.runAsync(() => tester.tap(target));
        await tester.pumpAndSettle();
      }

      await tester.ensureVisible(find.text('各网盘连接数'));
      await tester.pumpAndSettle();
      await tap(find.text('各网盘连接数'));
      final row = find.ancestor(
        of: find.text('百度网盘 · 账号直链'),
        matching: find.byType(ListTile),
      );
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('最多 8')),
        findsOneWidget,
      );
      await tap(row);
      expect(find.text('跟随全局（8）'), findsOneWidget);
      await tap(find.text('自定义连接数…'));
      final input = find.byType(TextField);
      expect(tester.widget<TextField>(input).decoration?.hintText, '1–8');
      expect(tester.widget<TextField>(input).controller?.text, '8');
      await tester.enterText(input, '9');
      await tap(find.text('确定'));
      expect(find.text('连接数范围为 1–8'), findsOneWidget);
      expect(services.settings.threadOverrides['baidu_direct'], 512);
      await tap(row);
      await tap(find.text('自定义连接数…'));
      await tester.enterText(find.byType(TextField), '6');
      await tap(find.text('确定'));
      await tester.runAsync(
        () =>
            until(() => services.settings.threadOverrides['baidu_direct'] == 6),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('最多 6')),
        findsOneWidget,
      );
      await tap(row);
      await tap(find.text('跟随全局（8）'));
      await tester.runAsync(
        () =>
            until(() => services.settings.threadOverrides['baidu_direct'] == 0),
      );
      await tester.pumpAndSettle();
      expect(services.settings.connectionsFor(null, 'baidu_direct'), 8);
      await tap(row);
      await tap(find.text('平台预设（3）'));
      await tester.runAsync(
        () => until(
          () => !services.settings.threadOverrides.containsKey('baidu_direct'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('最多 3')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final (platform, profile, limit) in [
    (CloudPlatform.quark, null, 512),
    (CloudPlatform.baidu, 'baidu', 8),
    (CloudPlatform.baidu, 'baidu_preview', 8),
    (CloudPlatform.baidu, 'baidu_direct', 8),
  ]) {
    testWidgets(
      '${platform.name} ${profile ?? 'default'} download rows and live details show actual connections and configured limit',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(393, 864);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory root;
        late AppServices services;
        late String id;
        final native = _ConnectionNative()..finish = false;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('aster-connection-ui-');
          services = AppServices(
            controlEnabled: false,
            store: StateStore.memory({
              'settings': {
                'downloadThreadOverrides': {'baidu_direct': 8},
              },
            }),
            dataDirectory: Directory('${root.path}/state'),
            cacheDirectory: Directory('${root.path}/cache'),
            transport: native,
            files: FakeFiles(Directory('${root.path}/saved')),
            http: FakeHttp(),
            transferHttp: _ConnectionHttp(),
            platformFeatures: false,
          );
          await services.downloads.initialize();
          id = await services.downloads.enqueue(
            DownloadSpec(
              url: 'https://example.com/connections',
              fileName: '连接数示例.bin',
              expectedSize: 4,
              source: {'platform': platform.key},
              profile: profile,
            ),
          );
          await until(() => services.downloads.httpConnections(id) != null);
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await services.close();
            await root.delete(recursive: true);
          });
        });
        await tester.pumpWidget(AsterLinkApp(services, initialTab: 3));
        await tester.pumpAndSettle();
        final badge = find.byKey(ValueKey('download-connections-$id'));
        expect(tester.widget<Text>(badge).data, '7 连接');
        await tester.tap(find.byKey(ValueKey('download-row-$id')));
        await tester.pumpAndSettle();
        expect(find.textContaining('工作连接 7 · 分段 16'), findsOneWidget);
        expect(find.textContaining('连接上限 $limit'), findsOneWidget);
        native.active = 3;
        await tester.runAsync(() async {
          await until(
            () => services.downloads.httpConnections(id)?.active == 3,
          );
        });
        await tester.pump();
        expect(find.textContaining('工作连接 3 · 分段 16'), findsOneWidget);
        await tester.runAsync(() => services.downloads.pause(id));
        await tester.pumpAndSettle();
        expect(find.textContaining('工作连接'), findsNothing);
        expect(find.textContaining('连接上限 $limit'), findsOneWidget);
        expect(tester.widget<Text>(badge).data, 'HTTP');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
