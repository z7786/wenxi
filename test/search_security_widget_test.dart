import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/search_security.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/search_security_dialog.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('CaptchaFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
    }
  });
  for (final (name, size, scale, dark) in [
    ('android', const Size(430, 932), 1.0, false),
    ('windows', const Size(1280, 900), 1.0, false),
    ('android-large-text', const Size(320, 568), 1.8, false),
    ('android-landscape', const Size(740, 360), 1.0, true),
  ]) {
    testWidgets(
      'captcha fits $name and continues only after server verification',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync(
          'asterlink-security-',
        );
        final fixture = asJson(
          jsonDecode(
            File('test/fixtures/search_captcha.json').readAsStringSync(),
          ),
        );
        var redeemed = 0;
        final http = FakeHttp((call) {
          if (call.uri.path.endsWith('/verify')) {
            expect(call.json['answer'], [0, 1, 2]);
            redeemed++;
            return jsonResponse({
              'success': true,
              'token': 'verified-test-session-with-32-characters',
              'expires_in': 1200,
            });
          }
          return jsonResponse(fixture);
        });
        final store = StateStore.memory();
        final services = AppServices(
          store: store,
          dataDirectory: directory,
          cacheDirectory: Directory('${directory.path}/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('${directory.path}/files')),
          http: http,
          platformFeatures: false,
          controlEnabled: false,
        );
        final client = SearchSecurityClient(http, 'http://search.test');
        final token = CancelToken();
        final boundary = GlobalKey();
        var continued = false;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appTheme(
                dark ? Brightness.dark : Brightness.light,
                fontFamily: 'CaptchaFixture',
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: FilledButton(
                      onPressed: () async {
                        continued =
                            await showDialog<bool>(
                              context: context,
                              barrierDismissible: false,
                              builder: (_) =>
                                  SearchSecurityDialog(services, client, token),
                            ) ??
                            false;
                      },
                      child: const Text('搜索资源'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('搜索资源'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          for (final element in find.byType(Image).evaluate()) {
            await precacheImage((element.widget as Image).image, element);
          }
        });
        await tester.pumpAndSettle();
        expect(find.text('安全验证'), findsOneWidget);
        expect(redeemed, 0);
        expect(continued, isFalse);
        if (name == 'android' || name == 'windows') {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final path = File('${directory.path}/app-verification-$name.png');
            await path.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        for (var i = 0; i < 3; i++) {
          final cell = find.byKey(ValueKey('search-captcha-cell-$i'));
          await tester.ensureVisible(cell);
          await tester.tap(cell);
          await tester.pump();
        }
        await tester.ensureVisible(find.text('确认验证'));
        await tester.tap(find.text('确认验证'));
        await tester.pumpAndSettle();
        expect(continued, isTrue);
        expect(redeemed, 1);
        expect(find.text('安全验证'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        services.dispose();
        store.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      },
    );
  }
}
