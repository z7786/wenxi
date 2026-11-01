import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/main.dart';
import 'support.dart';

class _LifecycleServices extends AppServices {
  _LifecycleServices()
    : super(
        store: StateStore.memory(),
        dataDirectory: Directory('test-fixture'),
        cacheDirectory: Directory('test-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('test-fixture/saved')),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
        announcementsUrl: '',
      );

  int prefetches = 0;

  @override
  void refreshEntryData() => prefetches++;
}

void main() {
  for (final initial in [AppLifecycleState.resumed, AppLifecycleState.paused]) {
    testWidgets(
      'entry prefetch follows opening, resume and Windows focus: $initial',
      (tester) async {
        final services = _LifecycleServices();
        tester.binding.handleAppLifecycleStateChanged(initial);
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(Brightness.light),
              home: MainShell(services),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            services.prefetches,
            initial == AppLifecycleState.resumed ? 1 : 0,
          );
          final before = services.prefetches;
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          await tester.pump();
          expect(services.prefetches, before);
          for (final state in [
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          await tester.pump();
          expect(services.prefetches, before + 1);
          (tester.state(find.byType(MainShell)) as WindowListener)
              .onWindowFocus();
          expect(services.prefetches, before + 2);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          var closed = false;
          services.close().then((_) => closed = true);
          for (var i = 0; i < 50 && !closed; i++) {
            await tester.pump();
          }
          expect(closed, isTrue);
          services.store.dispose();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      },
    );
  }
}
