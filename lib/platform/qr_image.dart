import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/multi.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';
import '../core/json.dart';
import 'native_engine.dart';

const qrImageMaxBytes = 24 * 1024 * 1024;
const qrImageFileType = XTypeGroup(
  label: '二维码图片',
  extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'heic', 'heif'],
  mimeTypes: ['image/*'],
  uniformTypeIdentifiers: ['public.image'],
);

/// Read selected documents through XFile so platform picker access is retained.
Future<List<String>?> pickQrImage() async {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      final bytes = await nativeChannel.invokeMethod<Uint8List>('pickQrImage');
      return bytes == null ? null : readQrImage(bytes);
    } on MissingPluginException {
      // Older platform bridges can still select images from Files.
    } on PlatformException catch (error) {
      throw AppException(error.message ?? '无法选择图片，请稍后重试');
    }
  }
  final file = await openFile(acceptedTypeGroups: const [qrImageFileType]);
  if (file == null) return null;
  require(await file.length() <= qrImageMaxBytes, '请选择不超过 24 MB 的二维码图片');
  return readQrImage(await file.readAsBytes());
}

/// Bound decoded pixels before allocation, then detect codes off the UI thread.
/// Neither the source image nor its contents are stored or sent over the network.
Future<List<String>> readQrImage(Uint8List bytes) async {
  require(
    bytes.isNotEmpty && bytes.length <= qrImageMaxBytes,
    '请选择不超过 24 MB 的二维码图片',
  );
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  late int width, height;
  late TransferableTypedData pixels;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    width = descriptor.width;
    height = descriptor.height;
    require(
      width > 0 &&
          height > 0 &&
          width <= 32768 &&
          height <= 32768 &&
          width * height <= 80000000,
      '图片尺寸过大，请先裁剪二维码后再选择',
    );
    var scale = math.min(1.0, 4096 / math.max(width, height));
    scale = math.min(scale, math.sqrt(4000000 / (width * height)));
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (width * scale).floor()),
      targetHeight: math.max(1, (height * scale).floor()),
    );
    image = (await codec.getNextFrame()).image;
    width = image.width;
    height = image.height;
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    require(data != null, '无法读取图片，请换一张重试');
    pixels = TransferableTypedData.fromList([
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    ]);
  } on AppException {
    rethrow;
  } catch (_) {
    throw const AppException('无法读取这张图片，请选择 JPG、PNG 或 WebP 图片');
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }

  final port = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
      _qrImageWorker,
      (port.sendPort, width, height, pixels),
      onError: port.sendPort,
      onExit: port.sendPort,
      debugName: 'qr-image',
    );
    final reply = await port.first.timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw const AppException('识别超时，请裁剪二维码后重试'),
    );
    require(reply is Map && reply['texts'] is List<String>, '二维码识别失败，请换一张图片重试');
    final texts = (reply as Map)['texts'] as List<String>;
    require(texts.isNotEmpty, '没有识别到二维码，请选择更清晰的图片或裁剪二维码后重试');
    return texts;
  } finally {
    worker?.kill(priority: Isolate.immediate);
    port.close();
  }
}

void _qrImageWorker((SendPort, int, int, TransferableTypedData) task) {
  final (port, width, height, data) = task;
  final rgba = data.materialize().asUint8List();
  final luminances = Uint8List(width * height);
  for (var i = 0; i < luminances.length; i++) {
    final offset = i * 4, alpha = rgba[offset + 3];
    final grey = (rgba[offset] + 2 * rgba[offset + 1] + rgba[offset + 2]) ~/ 4;
    // Transparent screenshot/QR backgrounds must behave like white paper.
    luminances[i] = (grey * alpha + 255 * (255 - alpha) + 127) ~/ 255;
  }
  final source = RGBLuminanceSource.orig(width, height, luminances);
  final texts = <String>{};
  const hints = DecodeHint(tryHarder: true);
  for (final candidate in [source, source.invert()]) {
    final bitmap = BinaryBitmap(HybridBinarizer(candidate));
    try {
      for (final result in QRCodeMultiReader().decodeMultiple(bitmap, hints)) {
        _addQrText(texts, result.text);
      }
    } on ReaderException {
      // A code can be found by the single-code detector even if multi fails.
    }
    if (texts.isEmpty) {
      try {
        _addQrText(texts, QRCodeReader().decode(bitmap, hints).text);
      } on ReaderException {
        try {
          final global = BinaryBitmap(GlobalHistogramBinarizer(candidate));
          _addQrText(texts, QRCodeReader().decode(global, hints).text);
        } on ReaderException {
          // Try the other contrast polarity before reporting no QR codes.
        }
      }
    }
  }
  port.send({'texts': texts.toList()});
}

void _addQrText(Set<String> texts, String value) {
  final text = value.trim();
  if (text.isNotEmpty && text.length <= 16384 && texts.length < 16) {
    texts.add(text);
  }
}
