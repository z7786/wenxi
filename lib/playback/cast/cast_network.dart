import 'dart:async';
import 'dart:io';

import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../diagnostics/redaction.dart';
import '../../lan/lan_addresses.dart' show lanInterfacePriority;
import 'dlna.dart';

/// A connected Socket.address is the address passed to connect, not the local
/// source IP. Choose an assigned interface and explicitly bind the probe to it.
/// Prefix similarity only orders candidates; a successful probe selects one.
class CastNetworkRoute {
  CastNetworkRoute({
    Future<List<InternetAddress>> Function(InternetAddress)? addresses,
    Future<void> Function(Uri, InternetAddress, Duration)? probe,
    this.timeout = const Duration(seconds: 5),
  }) : addresses = addresses ?? _addresses,
       probe = probe ?? _probe;

  final Future<List<InternetAddress>> Function(InternetAddress) addresses;
  final Future<void> Function(Uri, InternetAddress, Duration) probe;
  final Duration timeout;

  static int _prefix(InternetAddress a, InternetAddress b) {
    var bits = 0;
    for (var i = 0; i < a.rawAddress.length; i++) {
      final difference = a.rawAddress[i] ^ b.rawAddress[i];
      if (difference != 0) return bits + 8 - difference.bitLength;
      bits += 8;
    }
    return bits;
  }

  static Future<List<InternetAddress>> _addresses(InternetAddress peer) async {
    if (peer.isLoopback) {
      return [
        peer.type == InternetAddressType.IPv4
            ? InternetAddress.loopbackIPv4
            : InternetAddress.loopbackIPv6,
      ];
    }
    final interfaces = await NetworkInterface.list(type: peer.type);
    final candidates = [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback && isCastAddress(address.address))
            (
              address: address,
              priority: lanInterfacePriority(interface.name),
              prefix: _prefix(address, peer),
              index: interface.index,
            ),
    ];
    candidates.sort((a, b) {
      final prefix = b.prefix.compareTo(a.prefix);
      if (prefix != 0) return prefix;
      final priority = a.priority.compareTo(b.priority);
      return priority != 0 ? priority : a.index.compareTo(b.index);
    });
    return candidates.map((candidate) => candidate.address).toList();
  }

  static Future<void> _probe(
    Uri endpoint,
    InternetAddress address,
    Duration timeout,
  ) async {
    final socket = await Socket.connect(
      endpoint.host,
      endpoint.port,
      sourceAddress: address,
      timeout: timeout,
    );
    socket.destroy();
  }

  Future<InternetAddress> localAddress(CastDevice device) async {
    final endpoint = device.transport.control;
    require(castEndpoint(endpoint), '电视地址无效，请刷新设备列表');
    final peer = InternetAddress(endpoint.host);
    final candidates = (await addresses(peer))
        .where(
          (address) =>
              address.type == peer.type &&
              isCastAddress(address.address) &&
              (peer.isLoopback || !address.isLoopback),
        )
        .toSet()
        .take(8);
    require(candidates.isNotEmpty, '没有可用的局域网地址，请连接 Wi-Fi 后重试');
    final elapsed = Stopwatch()..start();
    Object? failure;
    for (final address in candidates) {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      try {
        await probe(
          endpoint,
          address,
          remaining < const Duration(seconds: 2)
              ? remaining
              : const Duration(seconds: 2),
        );
        return address;
      } on SocketException catch (error) {
        failure = error;
      } on TimeoutException catch (error) {
        failure = error;
      }
      DiagnosticLog.event(
        'cast.route_probe_failed',
        fields: {
          'device': DiagnosticLog.reference(device.id),
          'local': DiagnosticLog.reference(address.address),
          ...castFailureFields(failure, stage: 'route'),
        },
      );
    }
    throw CastNetworkException(
      'route',
      failure ?? TimeoutException('LAN connection timed out', timeout),
    );
  }
}

class CastNetworkException extends AppException {
  CastNetworkException(this.stage, this.cause) : super(_message(stage));
  final String stage;
  final Object cause;

  static String _message(String stage) => switch (stage) {
    'route' => '无法建立与电视的局域网连接，请检查 Wi-Fi 或刷新设备列表',
    'bind' => '无法启动本机投屏服务，请检查网络状态后重试',
    'source_prepare' => '无法读取投屏视频，请检查网络或重新获取播放链接',
    _ => '无法连接或控制电视，请确认设备在同一局域网且电视已开启 DLNA 投屏',
  };
}

Map<String, Object?> castFailureFields(Object failure, {String? stage}) {
  final control = failure is CastNetworkException ? failure.cause : failure;
  final cause = control is CastControlException
      ? control.cause ?? control
      : control;
  return {
    'stage': failure is CastNetworkException ? failure.stage : stage,
    'code': cause is CastSoapException ? cause.code : null,
    'error_type': cause.runtimeType.toString(),
    if (control is CastControlException) ...{
      'action': control.action,
      'request_stage': control.phase,
      'http_status': control.status,
    },
    if (cause is HttpException)
      'http_error': LogRedactor.text(cause.message, limit: 512),
    if (cause is TimeoutException) 'timed_out': true,
    if (cause is SocketException) ...{
      'errno': cause.osError?.errorCode,
      'os_error': cause.osError == null
          ? null
          : LogRedactor.text(cause.osError!.message, limit: 512),
    },
  };
}
