import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/mobile_data_download_guard.dart';
import 'package:asterlink/ui/download_location_picker.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'support.dart';

class _PickerFiles extends FakeFiles {
  _PickerFiles() : super(Directory('unused'));
  String? choice = r'E:\Videos';
  Completer<String?>? pending;
  @override
  Future<String?> chooseDirectory() async => pending?.future ?? choice;
}

class _Queue extends Fake implements DownloadManager {
  final locations = <DownloadDestinationSelection?>[];
  @override
  Future<String> enqueue(
    DownloadSpec spec, {
    int? connections,
    String? destination,
    DownloadDestinationSelection? location,
  }) async {
    locations.add(location);
    return 'task-${locations.length}';
  }
}

class _Services extends Fake implements AppServices {
  @override
  final store = StateStore.memory({
    'settings': {
      'destination': r'D:\Downloads',
      'askDownloadDestination': true,
    },
    'recentDownloadDestinations': [r'E:\Videos', r'F:\Music'],
  });
  @override
  AppSettings get settings => AppSettings.fromJson(store.data.obj('settings'));
  @override
  final _PickerFiles files = _PickerFiles();
  @override
  final _Queue downloads = _Queue();
  @override
  void requestDownloadManager() {}
}

void main() {
  void locationTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    locationTest('$platform always uses the configured folder', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final services = _Services();
      addTearDown(services.store.dispose);
      DownloadDestinationSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await chooseDownloadLocation(
                  context,
                  services,
                  alwaysAsk: true,
                );
              },
              child: const Text('download'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('download'));
      await tester.pumpAndSettle();
      expect(find.text('下载保存位置'), findsNothing);
      expect(selected?.path, r'D:\Downloads');
      expect(selected?.makeDefault, isFalse);
    });
  }
  test('old settings default off and preserve explicit choice', () {
    expect(AppSettings.fromJson({}).askDownloadDestination, isFalse);
    expect(
      AppSettings.fromJson({
        'askDownloadDestination': true,
      }).update({'threads': 8}).askDownloadDestination,
      isTrue,
    );
  });
  test(
    'recent locations are ordered, deduplicated, bounded and tolerate bad data',
    () {
      final data = <String, dynamic>{'recentDownloadDestinations': 'invalid'};
      expect(DownloadDestinationSelection.recent(data), isEmpty);
      for (var i = 0; i < 8; i++) {
        DownloadDestinationSelection('directory-$i').remember(data);
      }
      const DownloadDestinationSelection('directory-5').remember(data);
      expect(DownloadDestinationSelection.recent(data), [
        'directory-5',
        'directory-7',
        'directory-6',
        'directory-4',
        'directory-3',
      ]);
    },
  );

  for (final mode in [
    'cancel',
    'confirm',
    'default',
    'picker-cancel',
    'disabled',
    'force',
    'system',
  ]) {
    locationTest('download location: $mode', (tester) async {
      final services = _Services();
      addTearDown(services.store.dispose);
      if (mode == 'disabled' || mode == 'force') {
        await services.store.put('settings', {'destination': r'D:\Downloads'});
      }
      if (mode == 'picker-cancel') services.files.choice = null;
      DownloadDestinationSelection? result;
      var returned = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await chooseDownloadLocation(
                    context,
                    services,
                    alwaysAsk: mode == 'force',
                  );
                  returned = true;
                },
                child: const Text('download'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('download'));
      await tester.pumpAndSettle();
      if (mode == 'disabled') {
        expect(find.text('下载保存位置'), findsNothing);
        expect(result?.path, r'D:\Downloads');
        return;
      }
      expect(find.text('下载保存位置'), findsOneWidget);
      if (mode == 'system') {
        await tester.tap(find.byKey(const Key('download-location-recent')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('系统下载目录'));
      } else {
        await tester.tap(find.byKey(const Key('download-location-browse')));
      }
      await tester.pumpAndSettle();
      if (mode == 'default' || mode == 'cancel') {
        await tester.tap(find.text('设为默认目录'));
        await tester.pumpAndSettle();
      }
      expect(services.settings.destination, r'D:\Downloads');
      expect(services.downloads.locations, isEmpty);
      await tester.tap(
        mode == 'cancel'
            ? find.text('取消')
            : find.byKey(const Key('download-location-confirm')),
      );
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      if (mode == 'cancel') {
        expect(result, isNull);
      } else {
        expect(
          result?.path,
          mode == 'system'
              ? null
              : mode == 'picker-cancel'
              ? r'D:\Downloads'
              : r'E:\Videos',
        );
        expect(result?.makeDefault, mode == 'default');
      }
      expect(services.settings.destination, r'D:\Downloads');
      expect(tester.takeException(), isNull);
    });
  }

  locationTest(
    'native picker holds confirmation; cancellation queues nothing',
    (tester) async {
      final services = _Services();
      addTearDown(services.store.dispose);
      services.files.pending = Completer<String?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => chooseDownloadLocation(context, services),
                child: const Text('download'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('download'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('download-location-browse')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('download-location-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      services.files.pending!.complete(r'F:\Late');
      await tester.pumpAndSettle();
      expect(services.downloads.locations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    locationTest('$platform direct download selects a folder only on desktop', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final desktop =
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.macOS;
      final services = _Services();
      addTearDown(services.store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => directDownloadDialog(
                  context,
                  services,
                  initial: 'https://example.com/file.bin',
                ),
                child: const Text('direct'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('direct'));
      await tester.pumpAndSettle();
      if (desktop) {
        expect(
          find.byKey(const Key('download-location-browse')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('download-location-browse')));
        await tester.pumpAndSettle();
      } else {
        expect(find.byKey(const Key('download-location-browse')), findsNothing);
      }
      await tester.ensureVisible(
        find.byKey(const Key('direct-download-submit')),
      );
      await tester.tap(find.byKey(const Key('direct-download-submit')));
      await tester.pumpAndSettle();
      expect(find.text('下载保存位置'), findsNothing);
      expect(
        services.downloads.locations.single?.path,
        desktop ? r'E:\Videos' : r'D:\Downloads',
      );
      expect(tester.takeException(), isNull);
    });
  }

  locationTest('Escape cancels player download and a new attempt can confirm', (
    tester,
  ) async {
    final services = _Services();
    addTearDown(services.store.dispose);
    var cancelled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                try {
                  await enqueueDownloadFromUi(
                    context,
                    services,
                    const DownloadSpec(
                      url: 'https://example.com/movie.mp4',
                      fileName: 'movie.mp4',
                    ),
                  );
                } on DownloadConfirmationCancelled {
                  cancelled++;
                }
              },
              child: const Text('download'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('download'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(cancelled, 1);
    expect(services.downloads.locations, isEmpty);
    await tester.tap(find.text('download'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('download-location-confirm')));
    await tester.pumpAndSettle();
    expect(services.downloads.locations.single?.path, r'D:\Downloads');
  });

  for (final size in [const Size(320, 700), const Size(900, 430)]) {
    locationTest('location picker fits $size with large text', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final services = _Services();
      addTearDown(services.store.dispose);
      await services.store.put('settings', {
        'askDownloadDestination': true,
        'destination': 'D:\\${List.filled(12, '长文件夹名称').join('\\')}',
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => chooseDownloadLocation(context, services),
                child: const Text('download'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('download'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('download-location-confirm')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
