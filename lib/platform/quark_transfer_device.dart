import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../core/json.dart';

/// Read a fresh phone environment for each transfer; never persist the values.
class QuarkTransferDevice {
  QuarkTransferDevice({
    String? platform,
    Future<Json> Function()? readEnvironment,
  }) : platform = platform ?? Platform.operatingSystem,
       _readEnvironment = readEnvironment ?? _nativeEnvironment;

  final String platform;
  final Future<Json> Function() _readEnvironment;
  static const _channel = MethodChannel('com.asterlink.app/native');

  // The verified signing/profile protocol is Android. Other platforms keep
  // their web route rather than impersonating an Android phone.
  bool get supported => platform == 'android';

  Future<QuarkTransferDeviceInfo?> read() async {
    if (!supported) return null;
    try {
      final environment = await _readEnvironment().timeout(
        const Duration(seconds: 2),
      );
      if (environment.str('deviceType') != 'phone') return null;
      final model = environment.str('model').trim();
      final release = environment.str('osVersion').trim();
      final width = environment.integer('screenWidth');
      final height = environment.integer('screenHeight');
      if (model.isEmpty ||
          model.length > 128 ||
          RegExp(r'[\x00-\x1f\x7f;()]').hasMatch(model) ||
          !RegExp(r'^[0-9A-Za-z._-]{1,32}$').hasMatch(release) ||
          width <= 0 ||
          height <= 0 ||
          width > 10000 ||
          height > 10000) {
        return null;
      }
      final locale = environment.str('locale').trim();
      return QuarkTransferDeviceInfo(
        model,
        release,
        width,
        height,
        locale:
            RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$').hasMatch(locale)
            ? locale
            : '',
        networkTransport: environment.str('networkTransport').toLowerCase(),
        cellularSubtype: environment.integer('cellularSubtype'),
      );
    } catch (_) {
      // Missing/old native bridges and unavailable data select the web route.
      return null;
    }
  }

  static Future<Json> _nativeEnvironment() async =>
      asJson(await _channel.invokeMethod<Object?>('clientEnvironment'));
}

class QuarkTransferDeviceInfo {
  const QuarkTransferDeviceInfo(
    this.model,
    this.osVersion,
    this.screenWidth,
    this.screenHeight, {
    this.locale = '',
    this.networkTransport = '',
    this.cellularSubtype = 0,
  });
  final String model, osVersion;
  final String locale, networkTransport;
  final int screenWidth, screenHeight;
  final int cellularSubtype;
  // This identifies the verified Quark wire protocol, not AsterLink's version
  // or an installed Quark app. Keep the query and User-Agent consistent.
  static const clientVersion = '7.4.5.680';
  static const product = 'ucpro';

  String get language =>
      locale.isEmpty ? '' : locale.split('-').first.toLowerCase();

  Map<String, String> get _networkParameters => switch (networkTransport) {
    'wifi' => const {'nt': '5', 'nw': '0'},
    // Android NETWORK_TYPE_LTE=13, NETWORK_TYPE_NR=20. An APN or a generic
    // "cellular" connection cannot establish the current radio generation.
    'cellular' when cellularSubtype == 13 => const {'nt': '6', 'nw': '4G'},
    'cellular' when cellularSubtype == 20 => const {'nt': '7', 'nw': '5G'},
    _ => const {},
  };

  Map<String, String> get parameters => {
    'device_model': model,
    'mi': model,
    'ss': '${screenWidth}x$screenHeight',
    if (language.isNotEmpty) 'la': language,
    ..._networkParameters,
  };

  String get userAgent =>
      'Mozilla/5.0 (Linux; Android $osVersion; ${Uri.encodeComponent(model)}) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Quark/$clientVersion Mobile Safari/537.36';
}
