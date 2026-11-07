import 'dart:io';
// Exercise the locked iOS plugin's UTI validation, which differs from Android.
// ignore: depend_on_referenced_packages
import 'package:file_selector_ios/file_selector_ios.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:file_selector_ios/src/messages.g.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/document_actions.dart';

class _PickerApi extends FileSelectorApi {
  final configs = <FileSelectorConfig>[];
  @override
  Future<List<String>> openFile(FileSelectorConfig config) async {
    configs.add(config);
    return [];
  }
}

class _SavePicker extends FileSelectorPlatform {
  String? path;
  SaveDialogOptions? options;
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    this.options = options;
    return path == null ? null : FileSaveLocation(path!);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/apple-documents');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'iOS accepts backups, unregistered torrent files and image imports',
    () async {
      final api = _PickerApi();
      final realPicker = FileSelectorIOS(api: api);
      for (final type in [
        backupFileType,
        torrentFileType,
        backgroundImageFileType,
      ]) {
        expect(await realPicker.openFile(acceptedTypeGroups: [type]), isNull);
      }
      expect(api.configs.map((c) => c.utis).toList(), [
        ['public.data'],
        ['public.data'],
        ['public.image'],
      ]);
      expect(
        await realPicker.openFiles(acceptedTypeGroups: [torrentFileType]),
        isEmpty,
      );
      expect(torrentFileType.mimeTypes, contains('application/octet-stream'));
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test(
      '$platform export uses the native picker and preserves cancellation',
      () async {
        final calls = <MethodCall>[];
        String? result = '/selected/backup.bak';
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return result;
        });
        final actions = DocumentActions(platform: platform, channel: channel);
        final bytes = Uint8List.fromList([1, 2, 3]);
        expect(
          await actions.saveBytes(
            bytes,
            'backup.bak',
            mime: 'application/octet-stream',
          ),
          result,
        );
        expect(calls.single.method, 'saveDocument');
        expect(calls.single.arguments['name'], 'backup.bak');
        expect(calls.single.arguments['bytes'], bytes);
        result = null;
        expect(
          await actions.saveBytes(
            bytes,
            '../unsafe?.bak',
            mime: 'application/octet-stream',
          ),
          isNull,
        );
        expect(calls.last.arguments['name'], '.._unsafe_.bak');
        messenger.setMockMethodCallHandler(
          channel,
          (_) async =>
              throw PlatformException(code: 'permission', message: '目录访问失败'),
        );
        await expectLater(
          actions.saveBytes(
            bytes,
            'test.bak',
            mime: 'application/octet-stream',
          ),
          throwsA(
            isA<AppException>().having((e) => e.message, 'message', '目录访问失败'),
          ),
        );
      },
    );
  }

  test(
    'desktop export writes selected bytes and a cancelled save writes nothing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aster-document-save-',
      );
      final original = FileSelectorPlatform.instance;
      final picker = _SavePicker()..path = p.join(directory.path, 'backup.bak');
      FileSelectorPlatform.instance = picker;
      addTearDown(() async {
        FileSelectorPlatform.instance = original;
        final resolved = await directory.resolveSymbolicLinks();
        expect(
          p.isWithin(
            await Directory.systemTemp.resolveSymbolicLinks(),
            resolved,
          ),
          isTrue,
        );
        expect(p.basename(resolved), startsWith('aster-document-save-'));
        await directory.delete(recursive: true);
      });
      const actions = DocumentActions(
        platform: TargetPlatform.macOS,
        channel: channel,
      );
      final bytes = Uint8List.fromList([4, 5, 6]);
      final path = await actions.saveBytes(
        bytes,
        'backup.bak',
        mime: 'application/octet-stream',
        acceptedTypeGroups: [backupFileType],
      );
      expect(await File(path!).readAsBytes(), bytes);
      expect(picker.options?.suggestedName, 'backup.bak');
      picker.path = null;
      expect(
        await actions.saveBytes(
          bytes,
          'cancelled.bak',
          mime: 'application/octet-stream',
        ),
        isNull,
      );
      expect(await directory.list().length, 1);
      await expectLater(
        actions.saveBytes(
          Uint8List(0),
          'empty.bak',
          mime: 'application/octet-stream',
        ),
        throwsA(isA<AppException>()),
      );
    },
  );
}
