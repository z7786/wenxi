import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/github_acceleration.dart';
import 'package:asterlink/ui/github_acceleration_page.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/core/json.dart';
import 'support.dart';

class _GitHubNative extends FakeNative {
  final probes = <Json>[];
  final stops = <String>[];
  bool brokenRange = false;
  bool noRange = false;
  bool errorPage = false;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'httpProbeStart') {
      probes.add(args);
      return null;
    }
    if (method == 'httpProbeStatus') {
      if (probes.last.str('url').endsWith('/COPYING')) {
        return brokenRange
            ? {'status': 'error', 'errorKind': 'content'}
            : {
                'status': 'done',
                'code': noRange ? 200 : 206,
                'body': base64Encode(
                  utf8.encode(
                    '\n Note that the only valid version of the GPL as far as this project',
                  ),
                ),
              };
      }
      return {
        'status': 'done',
        'code': 200,
        'body': base64Encode(
          utf8.encode(errorPage ? '<html>error</html>' : 'Hello World!\n'),
        ),
      };
    }
    if (method == 'httpProbeStop') {
      stops.add(args.str('id'));
      return null;
    }
    return super.call(method, args);
  }
}

void main() {
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    final watch = Stopwatch()..start();
    while (!ready() && watch.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(ready(), isTrue);
    await tester.pumpAndSettle();
  }

  Future<AppServices> render(
    WidgetTester tester, {
    Future<void> Function(GitHubAcceleration)? testConnection,
    NativeTransport? transport,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    late Directory directory;
    late AppServices services;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('aster-github-ui-');
      services = AppServices(
        store: StateStore.memory(),
        dataDirectory: directory,
        cacheDirectory: Directory(p.join(directory.path, 'cache')),
        transport: transport ?? FakeNative(),
        files: FakeFiles(Directory(p.join(directory.path, 'saved'))),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: GitHubAccelerationPage(services, testConnection: testConnection),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final closing = services.close().whenComplete(() => closed = true);
      await waitFor(tester, () => closed);
      await closing;
      await tester.runAsync(() async {
        expect(
          p.isWithin(
            Directory.systemTemp.absolute.path,
            directory.absolute.path,
          ),
          isTrue,
        );
        await directory.delete(recursive: true);
      });
    });
    return services;
  }

  testWidgets(
    'Choose a preset, edit a custom prefix and return to direct without losing it',
    (tester) async {
      final services = await render(tester);
      expect(services.settings.githubAcceleration.mode, 'gh-proxy.com');
      await tester.tap(
        find.byKey(const ValueKey('github-acceleration-ghproxy.net')),
      );
      await waitFor(
        tester,
        () => services.settings.githubAcceleration.mode == 'ghproxy.net',
      );
      await tester.tap(
        find.byKey(const ValueKey('github-acceleration-custom')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'mirror.example/github');
      await tester.tap(find.widgetWithText(TextButton, '确定'));
      await waitFor(
        tester,
        () => services.settings.githubAcceleration.mode == 'custom',
      );
      expect(
        services.settings.githubAcceleration.customUrl,
        'https://mirror.example/github/',
      );
      expect(find.text('https://mirror.example/github/'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('github-acceleration-direct')),
      );
      await waitFor(
        tester,
        () => services.settings.githubAcceleration.mode == 'direct',
      );
      expect(
        services.settings.githubAcceleration.customUrl,
        'https://mirror.example/github/',
      );
      await services.updateSettings({'speedLimit': 1024});
      expect(services.settings.githubAcceleration.mode, 'direct');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A connection test uses the default proxy without changing settings',
    (tester) async {
      GitHubAcceleration? tested;
      final services = await render(
        tester,
        testConnection: (settings) async => tested = settings,
      );
      expect(services.settings.githubAcceleration.mode, 'gh-proxy.com');
      final button = find.byKey(const Key('github-acceleration-test'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tested?.mode, 'gh-proxy.com');
      expect(find.textContaining('连接成功'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Changing proxy while a test is pending discards its stale result',
    (tester) async {
      final pending = Completer<void>();
      final services = await render(
        tester,
        testConnection: (_) => pending.future,
      );
      final button = find.byKey(const Key('github-acceleration-test'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      final preset = find.byKey(
        const ValueKey('github-acceleration-ghproxy.net'),
      );
      await tester.ensureVisible(preset);
      await tester.tap(preset);
      await tester.pump();
      pending.complete();
      await waitFor(
        tester,
        () => services.settings.githubAcceleration.mode == 'ghproxy.net',
      );
      expect(find.byKey(const Key('github-acceleration-result')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brokenRange in [false, true]) {
    testWidgets(
      'Native file and range tests ${brokenRange ? 'reject a broken mirror' : 'pass with correct downloaded contents'}',
      (tester) async {
        final native = _GitHubNative()..brokenRange = brokenRange;
        final services = await render(tester, transport: native);
        final button = find.byKey(const Key('github-acceleration-test'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await waitFor(
          tester,
          () => find
              .byKey(const Key('github-acceleration-result'))
              .evaluate()
              .isNotEmpty,
        );
        expect(native.probes.map((p) => p.str('url')), [
          services.settings.githubAcceleration.urlFor(
            GitHubAcceleration.testUrl,
          ),
          services.settings.githubAcceleration.urlFor(
            GitHubAcceleration.rangeTestUrl,
          ),
        ]);
        expect(native.stops.length, 2);
        expect(native.begins, isEmpty);
        expect(
          find.textContaining(brokenRange ? '测试失败' : '分段校验通过'),
          findsOneWidget,
        );
        if (brokenRange) expect(find.textContaining('连接成功'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'A mirror ignoring Range reports file availability without claiming range support',
    (tester) async {
      final native = _GitHubNative()..noRange = true;
      await render(tester, transport: native);
      final button = find.byKey(const Key('github-acceleration-test'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await waitFor(
        tester,
        () => find
            .byKey(const Key('github-acceleration-result'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.textContaining('文件可下载；当前地址未返回分段响应'), findsOneWidget);
      expect(find.textContaining('分段校验通过'), findsNothing);
      expect(native.stops.length, 2);
      expect(native.begins, isEmpty);
    },
  );

  testWidgets('An HTTP 200 error page still fails the file test', (
    tester,
  ) async {
    final native = _GitHubNative()..errorPage = true;
    await render(tester, transport: native);
    final button = find.byKey(const Key('github-acceleration-test'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await waitFor(
      tester,
      () => find
          .byKey(const Key('github-acceleration-result'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('返回内容不是测试文件'), findsOneWidget);
    expect(find.textContaining('连接成功'), findsNothing);
    expect(native.stops.length, 1);
    expect(native.begins, isEmpty);
  });
}
