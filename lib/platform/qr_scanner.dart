import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import 'native_engine.dart';

bool get canScanQr =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<String?> scanParseQr() async {
  require(canScanQr, '请从图片识别二维码');
  try {
    return await nativeChannel.invokeMethod<String>('scanQr');
  } on MissingPluginException {
    throw const AppException('当前版本不支持相机扫码，请从图片识别二维码');
  } on PlatformException catch (error) {
    throw AppException(error.message ?? '无法打开相机，请从图片识别二维码');
  }
}

Future<String?> scanLanQr() async {
  require(canScanQr, '请使用手机扫描连接二维码，或手动输入设备地址');
  try {
    return await nativeChannel.invokeMethod<String>('lanScanQr');
  } on MissingPluginException {
    throw const AppException('当前版本不支持扫码，请使用连接码或设备地址');
  }
}
