import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/completed_file_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('com.asterlink.app/native');
  const windows = MethodChannel('com.asterlink.app/file_actions');
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<(String, MethodCall)> calls;
  setUp(() {
    calls = [];
    for (final channel in [native, windows, shareChannel]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add((channel.name, call));
        return null;
      });
    }
  });
  tearDown(() {
    for (final channel in [native, windows, shareChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test(
    'Android shares SAF URI without installation or copying a large file',
    () async {
      final actions = CompletedFileActions(platform: 'android');
      const path = 'content://downloads.test/document/large.apk';
      await actions.share(path, '安装包.apk');
      expect(calls.single.$1, native.name);
      expect(calls.single.$2.method, 'shareFile');
      expect(calls.single.$2.arguments, {'path': path, 'name': '安装包.apk'});
    },
  );

  test('Android explicitly chooses an application for APK and video', () async {
    final actions = CompletedFileActions(platform: 'android');
    for (final name in ['app.apk', 'movie.mp4']) {
      await actions.openWith('content://downloads.test/$name', name);
      expect(calls.last.$2.method, 'openFile');
      expect(calls.last.$2.arguments, {
        'path': 'content://downloads.test/$name',
        'name': name,
        'chooseApp': true,
      });
    }
    expect(calls, hasLength(2));
  });

  test(
    'Desktop opens the system application selector with the original path',
    () async {
      for (final platform in ['windows', 'macos']) {
        final path = platform == 'windows'
            ? r'C:\Downloads\视频 & (1).mp4'
            : '/Downloads/视频 & (1).mp4';
        await CompletedFileActions(
          platform: platform,
        ).openWith(path, '视频 & (1).mp4');
        expect(
          calls.last.$1,
          platform == 'windows' ? windows.name : native.name,
        );
        expect(calls.last.$2.method, 'openWith');
        expect(calls.last.$2.arguments, {'path': path});
      }
    },
  );

  test(
    'iPad opens apps from the file share sheet with a valid popover origin',
    () async {
      const origin = Rect.fromLTWH(20, 40, 44, 44);
      final actions = CompletedFileActions(platform: 'ios');
      await actions.openWith('/Documents/视频.mp4', '视频.mp4', origin: origin);
      final call = calls.single.$2;
      expect(calls.single.$1, shareChannel.name);
      expect(call.method, 'share');
      expect(call.arguments['paths'], ['/Documents/视频.mp4']);
      expect(call.arguments['mimeTypes'], ['video/mp4']);
      expect(call.arguments['originX'], 20);
      expect(call.arguments['originY'], 40);
      expect(call.arguments['originWidth'], 44);
      expect(call.arguments['originHeight'], 44);
    },
  );

  test(
    'Cancellation leaves the action reusable and permission errors are visible',
    () async {
      final actions = CompletedFileActions(platform: 'android');
      await actions.openWith('content://downloads.test/1', 'video.mp4');
      messenger.setMockMethodCallHandler(native, (_) async {
        throw PlatformException(code: 'permission', message: '无法读取文件');
      });
      await expectLater(
        actions.share('content://downloads.test/1', 'video.mp4'),
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '无法读取文件'),
        ),
      );
      messenger.setMockMethodCallHandler(native, (_) async => null);
      await actions.openWith('content://downloads.test/1', 'video.mp4');
    },
  );
}
