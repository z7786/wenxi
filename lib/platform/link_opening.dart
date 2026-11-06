import 'dart:io';
import 'package:flutter/services.dart';
import '../core/json.dart';
import 'native_engine.dart';

class LinkOpeningTarget {
  const LinkOpeningTarget({
    required this.id,
    required this.label,
    required this.sample,
    required this.enabled,
  });
  final String id, label, sample;
  final bool enabled;

  factory LinkOpeningTarget.fromPlatform(Object? value) {
    final json = asJson(value);
    return LinkOpeningTarget(
      id: json.str('id'),
      label: json.str('label'),
      sample: json.str('sample'),
      enabled: json['enabled'] == true,
    );
  }
}

class LinkOpeningPlatform {
  const LinkOpeningPlatform({
    MethodChannel channel = nativeChannel,
    bool? android,
    String? operatingSystem,
  }) : _channel = channel,
       _android = android,
       _operatingSystem = operatingSystem;
  final MethodChannel _channel;
  final bool? _android;
  final String? _operatingSystem;
  bool get android => _android ?? Platform.isAndroid;
  String get operatingSystem => _operatingSystem ?? Platform.operatingSystem;

  Future<List<LinkOpeningTarget>> status() async {
    if (!android) return const [];
    final rows = await _channel.invokeListMethod<Object?>('linkOpeningStatus');
    return (rows ?? const []).map(LinkOpeningTarget.fromPlatform).toList();
  }

  Future<List<LinkOpeningTarget>> setEnabled(String id, bool enabled) async {
    final rows = await _channel.invokeListMethod<Object?>('linkOpeningSet', {
      'id': id,
      'enabled': enabled,
    });
    return (rows ?? const []).map(LinkOpeningTarget.fromPlatform).toList();
  }

  Future<void> openSettings() =>
      _channel.invokeMethod<void>('linkOpeningSettings');
}
