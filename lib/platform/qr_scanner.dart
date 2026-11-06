import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import 'native_engine.dart';

bool get canScanQr =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<String?> scanLanQr() async {
  require(canScanQr, '请使用手机扫描连接二维码，或手动输入设备地址');
  try {
    return await nativeChannel.invokeMethod<String>('lanScanQr');
  } on MissingPluginException {
    throw const AppException('当前版本不支持扫码，请使用连接码或设备地址');
  }
}
