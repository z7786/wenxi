import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/upload/upload_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/upload-sources');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final android in [true, false]) {
    final platform = android ? 'Android' : 'iOS';
    test(
      '$platform preserves original names and streams picker files without a cache copy',
      () async {
        final calls = <MethodCall>[];
        final source = UploadSources(
          android: android,
          ios: !android,
          channel: channel,
        );
        final root = android ? 'content://test/tree/folder' : '/provider/资料';
        final location = android
            ? 'content://test/tree/folder/document/one'
            : '/provider/资料/子目录/a:b.txt';
        final bytes = Uint8List.fromList(List.generate(700000, (i) => i % 251));
        var offset = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'chooseUploadDirectory':
              return root;
            case 'uploadScan':
              expect(call.arguments, {'path': root});
              return {
                'name': '资料',
                'directories': ['', '子目录', '空目录'],
                'files': [
                  {
                    'location': location,
                    'relative': '子目录/a:b.txt',
                    'size': bytes.length,
                    'modifiedAt': 1234,
                  },
                ],
              };
            case 'uploadCheckDirectory':
              return null;
            case 'uploadStat':
              return {'size': bytes.length, 'modifiedAt': 1234};
            case 'uploadOpenRead':
              expect(call.arguments['path'], location);
              offset = call.arguments['offset'] as int;
              return 'handle';
            case 'uploadRead':
              if (!android) {
                expect(call.arguments['path'], location);
                offset = call.arguments['offset'] as int;
              } else {
                expect(call.arguments['id'], 'handle');
              }
              final length = call.arguments['length'] as int;
              expect(length, lessThanOrEqualTo(512 * 1024));
              final result = Uint8List.sublistView(
                bytes,
                offset,
                offset + length,
              );
              offset += length;
              return result;
            case 'uploadCloseRead':
              return null;
            default:
              throw StateError('Unexpected call ${call.method}');
          }
        });
        final selected = await source.pickFolder();
        final plan = await source.scanFolder(selected!);
        expect(plan.directories, ['', '子目录', '空目录']);
        expect(plan.files.single.name, 'a:b.txt');
        await source.validateFolder(plan);
        await source.validate(plan.files.single);
        final received = await source
            .read(plan.files.single, 19, bytes.length - 11)
            .expand((part) => part)
            .toList();
        expect(received, bytes.sublist(19, bytes.length - 11));
        expect(calls.where((c) => c.method == 'uploadRead'), hasLength(2));
        expect(
          calls.where((c) => c.method == 'uploadCloseRead').length,
          android ? 1 : 0,
        );
        expect(calls.any((c) => c.method.startsWith('lan')), isFalse);
      },
    );

    test('$platform modified source metadata fails validation', () async {
      final source = UploadSources(
        android: android,
        ios: !android,
        channel: channel,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'uploadScan') {
          return {
            'name': '资料',
            'directories': [''],
            'files': [
              {
                'location': 'local-source',
                'relative': 'one.txt',
                'size': 5,
                'modifiedAt': 1,
              },
            ],
          };
        }
        return {'size': 6, 'modifiedAt': 2};
      });
      final plan = await source.scanFolder('root');
      await expectLater(
        source.validate(plan.files.single),
        throwsA(isA<AppException>()),
      );
    });
  }

  test(
    'Android cancellation closes its reader and never uses the LAN reader',
    () async {
      final source = UploadSources(android: true, ios: false, channel: channel);
      final calls = <String>[];
      final scope = RequestScope();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'uploadScan':
            return {
              'name': '资料',
              'directories': [''],
              'files': [
                {
                  'location': 'content://test/file',
                  'relative': 'one.txt',
                  'size': 10,
                  'modifiedAt': 0,
                },
              ],
            };
          case 'uploadOpenRead':
            return 'handle';
          case 'uploadRead':
            scope.cancel();
            return Uint8List.fromList([1]);
          case 'uploadCloseRead':
            return null;
          default:
            throw StateError('Unexpected call ${call.method}');
        }
      });
      final file = (await source.scanFolder(
        'content://test/tree/root',
      )).files.single;
      await expectLater(
        scope.run(() => source.read(file, 0, 10).drain<void>()),
        throwsA(isA<AppException>()),
      );
      expect(calls, [
        'uploadScan',
        'uploadOpenRead',
        'uploadRead',
        'uploadCloseRead',
      ]);
    },
  );

  test('revoked directory permissions are a readable upload error', () async {
    final source = UploadSources(android: true, ios: false, channel: channel);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'permission',
        message: '上传目录权限已失效，请重新选择文件夹后重试',
      );
    });
    await expectLater(
      source.scanFolder('content://test/tree/root'),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('权限已失效'),
        ),
      ),
    );
  });

  test(
    'desktop directory scanning skips links and keeps empty directories',
    () async {
      final root = await Directory.systemTemp.createTemp('upload-sources-');
      addTearDown(() => root.delete(recursive: true));
      final selected = await Directory(p.join(root.path, '资料')).create();
      await Directory(p.join(selected.path, '空目录')).create();
      final file = File(p.join(selected.path, 'one.txt'));
      await file.writeAsBytes([4, 5]);
      final source = UploadSources(android: false, ios: false);
      final external = File(p.join(root.path, 'external.txt'));
      await external.writeAsBytes([9]);
      var linked = false;
      try {
        await Link(p.join(selected.path, 'linked.txt')).create(external.path);
        linked = true;
      } on FileSystemException {
        // Some Windows test runners do not grant symbolic-link creation.
      }
      final plan = await source.scanFolder(selected.path);
      expect(plan.directories, ['', '空目录']);
      expect(plan.files.single.relativePath, 'one.txt');
      expect(plan.skippedLinks, linked ? 1 : 0);
      await source.validate(plan.files.single);
      expect(
        await source.read(plan.files.single, 0, 2).expand((b) => b).toList(),
        [4, 5],
      );
    },
  );
}
