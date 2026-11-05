import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'windows_external_player.dart';

class MacOSExternalPlayer extends WindowsExternalPlayer {
  static const _channel = MethodChannel('com.asterlink.app/native');
  @override
  Future<bool> open(String url) async {
    final path = executable;
    require(
      path != null && p.posix.isAbsolute(path) && path.endsWith('.app'),
      '请先选择外部播放器应用',
    );
    require(await Directory(path!).exists(), '播放器应用不存在，请重新选择');
    require(url.isNotEmpty, '播放地址为空');
    try {
      return await _channel.invokeMethod<bool>('openExternalPlayer', {
            'application': path,
            'url': url,
          }) ??
          false;
    } on PlatformException catch (error) {
      throw AppException(error.message ?? '无法启动所选播放器');
    }
  }
}
