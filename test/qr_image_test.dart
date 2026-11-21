import 'dart:typed_data';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/qr_image.dart';
import 'qr_image_support.dart';
import 'background_support.dart';

class _QrPicker extends FileSelectorPlatform {
  XFile? file;
  List<XTypeGroup>? types;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    types = acceptedTypeGroups;
    return file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const text = '我分享了视频 https://pan.quark.cn/s/Abcd 提取码：a123';
  test(
    'reads the complete UTF-8 share text and cloud command from images',
    () async {
      for (final value in [text, '/*391R8TRNLu2U:/', '蕧郅岱等遥温琴扣炩']) {
        expect(await readQrImage(await qrImageFixture([value])), [value]);
      }
    },
  );
  test('reads rotated, inverted and transparent screenshots', () async {
    for (final angle in [90, 180, 270]) {
      expect(await readQrImage(await qrImageFixture([text], rotation: angle)), [
        text,
      ]);
    }
    expect(await readQrImage(await qrImageFixture([text], inverted: true)), [
      text,
    ]);
    expect(await readQrImage(await qrImageFixture([text], transparent: true)), [
      text,
    ]);
    expect(
      await readQrImage(await qrImageFixture([text], screenshotHeight: 2400)),
      [text],
    );
  });
  test(
    'detects multiple QR codes, including different contrast polarities, without duplicates',
    () async {
      const second = 'https://pan.baidu.com/s/1fixture?pwd=b234';
      expect(
        await readQrImage(await qrImageFixture([text, second])),
        unorderedEquals([text, second]),
      );
      expect(
        await readQrImage(
          await qrImageFixture([text, second], invertedIndices: {1}),
        ),
        unorderedEquals([text, second]),
      );
      expect(await readQrImage(await qrImageFixture([text, text])), [text]);
    },
  );
  test('no QR and damaged images have actionable errors', () async {
    await expectLater(
      readQrImage(await backgroundFixture(width: 240, height: 320)),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('没有识别到二维码'),
        ),
      ),
    );
    await expectLater(
      readQrImage(Uint8List.fromList([1, 2, 3])),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('无法读取'),
        ),
      ),
    );
    await expectLater(
      readQrImage(Uint8List(qrImageMaxBytes + 1)),
      throwsA(isA<AppException>()),
    );
  });
  test('picker cancellation and image selection use image filters', () async {
    final previous = FileSelectorPlatform.instance;
    final picker = _QrPicker();
    FileSelectorPlatform.instance = picker;
    addTearDown(() => FileSelectorPlatform.instance = previous);
    expect(await pickQrImage(), isNull);
    expect(picker.types!.single.uniformTypeIdentifiers, ['public.image']);
    picker.file = XFile.fromData(
      await qrImageFixture([text]),
      name: '分享截图.png',
    );
    expect(await pickQrImage(), [text]);
  });
}
