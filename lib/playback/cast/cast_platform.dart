import 'dart:io';
import 'package:flutter/services.dart';
import '../../domain/models.dart' show newId;

/// Each owner has a token, so a late scan cleanup cannot release another scan
/// or the independent LAN-sharing feature's Android multicast lock.
class CastPlatform {
  final _token = newId();
  static const _channel = MethodChannel('com.asterlink.app/cast');
  Future<void> network(bool enabled) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('network', {
        'token': _token,
        'enabled': enabled,
      });
    }
  }

  Future<void> active(bool enabled) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('active', {
        'token': _token,
        'enabled': enabled,
      });
    }
  }
}
