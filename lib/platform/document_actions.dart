import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import 'file_access.dart';

// Unknown extensions such as .bak and .torrent are not registered by every
// iOS document provider. Let the existing content validators check those files.
const backupFileType = XTypeGroup(
  label: '文析助手备份',
  extensions: ['json', 'bak'],
  mimeTypes: ['application/json', 'application/octet-stream'],
  uniformTypeIdentifiers: ['public.data'],
);
const torrentFileType = XTypeGroup(
  label: 'BT 种子',
  extensions: ['torrent'],
  mimeTypes: ['application/x-bittorrent', 'application/octet-stream'],
  uniformTypeIdentifiers: ['public.data'],
);
const backgroundImageFileType = XTypeGroup(
  label: '背景图片',
  extensions: ['jpg', 'jpeg', 'png', 'webp'],
  mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
  uniformTypeIdentifiers: ['public.image'],
);

class DocumentActions {
  const DocumentActions({
    TargetPlatform? platform,
    MethodChannel channel = const MethodChannel('com.asterlink.app/native'),
  }) : _platform = platform,
       _channel = channel;
  final TargetPlatform? _platform;
  final MethodChannel _channel;
  TargetPlatform get platform => _platform ?? defaultTargetPlatform;

  Future<String?> saveBytes(
    Uint8List bytes,
    String name, {
    required String mime,
    List<XTypeGroup> acceptedTypeGroups = const [],
  }) async {
    require(bytes.isNotEmpty, '保存内容为空');
    final fileName = safeFileName(name);
    if (platform == TargetPlatform.android || platform == TargetPlatform.iOS) {
      try {
        return await _channel.invokeMethod<String>('saveDocument', {
          'name': fileName,
          'bytes': bytes,
          'mime': mime,
        });
      } on PlatformException catch (error) {
        throw AppException(error.message ?? '保存未完成，请重新选择文件位置');
      }
    }
    final location = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: acceptedTypeGroups,
    );
    if (location == null) return null;
    await XFile.fromData(
      bytes,
      name: fileName,
      mimeType: mime,
    ).saveTo(location.path);
    return location.path;
  }
}
