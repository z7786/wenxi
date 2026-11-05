import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../core/json.dart';
import '../domain/playback.dart';
import 'file_access.dart';

String playerScreenshotName(
  String video,
  Duration position,
  DateTime captured,
) {
  final stem = video.replaceFirst(RegExp(r'\.[^.]{1,10}$'), '');
  final short = stem.length > 100 ? stem.substring(0, 100) : stem;
  return safeFileName(
    '${short}_${playbackTime(position).replaceAll(':', '-')}'
    '_${captured.millisecondsSinceEpoch}.png',
  );
}

/// Kept injectable so player UI tests do not open system save/share dialogs.
class PlayerScreenshotActions {
  const PlayerScreenshotActions();
  static const _native = MethodChannel('com.asterlink.app/native');
  static const _clipboard = MethodChannel('com.asterlink.app/player_images');
  bool get canShare => Platform.isAndroid || Platform.isIOS;
  bool get canCopy => Platform.isWindows || Platform.isMacOS;

  Future<String?> save(Uint8List bytes, String name) async {
    _check(bytes);
    if (Platform.isAndroid) {
      final saved = await _native.invokeMethod<String>('savePlayerScreenshot', {
        'bytes': bytes,
        'name': name,
      });
      if (saved != null) return '相册 / 文析助手';
      // Older Android versions use the system picker without requesting broad
      // storage access. A cancelled picker must remain a cancellation.
      return await _native.invokeMethod<String>('saveDocument', {
                'bytes': bytes,
                'name': name,
                'mime': 'image/png',
              }) ==
              null
          ? null
          : '所选位置';
    }
    final target = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG 图片', extensions: ['png']),
      ],
    );
    if (target == null) return null;
    await XFile.fromData(
      bytes,
      mimeType: 'image/png',
      name: name,
    ).saveTo(target.path);
    return target.path;
  }

  Future<void> share(Uint8List bytes, String name, ui.Rect origin) async {
    _check(bytes);
    require(canShare, '当前系统不支持图片分享');
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'image/png')],
        fileNameOverrides: [name],
        sharePositionOrigin: origin,
      ),
    );
  }

  Future<void> copy(Uint8List bytes) async {
    _check(bytes);
    require(canCopy, '当前系统不支持复制图片');
    final codec = await ui.instantiateImageCodec(bytes);
    ui.Image? frame;
    try {
      frame = (await codec.getNextFrame()).image;
      require(frame.width * frame.height <= 16 * 1024 * 1024, '图片尺寸过大');
      final pixels = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      require(pixels != null, '无法读取截图');
      await _clipboard.invokeMethod<void>('copyImage', {
        'width': frame.width,
        'height': frame.height,
        'rgba': pixels!.buffer.asUint8List(
          pixels.offsetInBytes,
          pixels.lengthInBytes,
        ),
      });
    } finally {
      frame?.dispose();
      codec.dispose();
    }
  }

  static void _check(Uint8List bytes) => require(
    bytes.isNotEmpty && bytes.length <= 32 * 1024 * 1024,
    '截图为空或过大，请重试',
  );
}
