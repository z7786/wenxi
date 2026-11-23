import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/ui/backup_page.dart';
import 'package:asterlink/ui/app_switch.dart';
import 'support.dart';

void main() {
  for (final size in [const Size(320, 720), const Size(1280, 900)]) {
    testWidgets(
      'backup page encryption, category selection and restore at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory root;
        late AppServices services;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('backup-widget-');
          services = AppServices(
            store: StateStore.memory(),
            dataDirectory: root,
            cacheDirectory: Directory('${root.path}/cache'),
            transport: FakeNative(),
            files: FakeFiles(root),
            http: FakeHttp(),
            platformFeatures: false,
            controlEnabled: false,
            clipboardReader: () async => null,
          );
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await services.close();
            await root.delete(recursive: true);
          });
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: size.width < 400 ? Brightness.dark : Brightness.light,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(size.width < 400 ? 1.4 : 1),
              ),
              child: BackupPage(services),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('本地文件'), findsOneWidget);
        expect(find.text('备份密码（至少 6 位）'), findsNothing);
        await tester.scrollUntilVisible(
          find.byType(AppSwitch),
          150,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 50,
        );
        await tester.drag(find.byType(ListView).first, const Offset(0, -160));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(AppSwitch));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('再次输入备份密码'),
          150,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 50,
        );
        expect(find.text('备份密码（至少 6 位）'), findsOneWidget);
        final password = find.widgetWithText(TextField, '备份密码（至少 6 位）');
        await tester.enterText(password, '123');
        await tester.ensureVisible(find.text('立即备份'));
        await tester.tap(find.text('立即备份'));
        await tester.pumpAndSettle();
        expect(find.text('备份密码至少需要 6 位'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView).first, const Offset(0, 2600));
        await tester.pumpAndSettle();
        await tester.tap(find.text('恢复').first);
        await tester.pumpAndSettle();
        expect(find.text('选择备份并预览'), findsOneWidget);
        expect(find.text('备份密码（至少 6 位）'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
