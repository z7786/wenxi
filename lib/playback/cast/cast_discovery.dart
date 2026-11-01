import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/json.dart';
import '../../lan/lan_models.dart' show isLanAddress;
import 'cast_platform.dart';
import 'dlna.dart';

/// SSDP responses are untrusted datagrams, not URLs to blindly fetch.
Uri? castLocation(List<int> bytes, InternetAddress sender) {
  if (bytes.length > 16384 || !isLanAddress(sender.address)) return null;
  final lines = latin1.decode(bytes).split(RegExp(r'\r?\n'));
  if (lines.isEmpty ||
      !RegExp(r'^HTTP/1\.[01] 200(?:\s|$)').hasMatch(lines.first)) {
    return null;
  }
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers.putIfAbsent(
      line.substring(0, colon).trim().toLowerCase(),
      () => line.substring(colon + 1).trim(),
    );
  }
  final uri = Uri.tryParse(headers['location'] ?? '');
  return uri != null && castEndpoint(uri) && uri.host == sender.address
      ? uri
      : null;
}

class CastDiscovery extends ChangeNotifier {
  CastDiscovery({
    CastPlatform? platform,
    Future<List<InternetAddress>> Function()? addresses,
    InternetAddress? searchAddress,
    this.searchPort = 1900,
    this.scanDuration = const Duration(seconds: 8),
  }) : platform = platform ?? CastPlatform(),
       addresses = addresses ?? _addresses,
       searchAddress = searchAddress ?? InternetAddress('239.255.255.250');
  final CastPlatform platform;
  final Future<List<InternetAddress>> Function() addresses;
  final InternetAddress searchAddress;
  final int searchPort;
  final Duration scanDuration;
  static Future<List<InternetAddress>> _addresses() async => [
    for (final nic in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    ))
      for (final address in nic.addresses)
        if (!address.isLoopback && isLanAddress(address.address)) address,
  ];
  final _devices = <String, CastDevice>{};
  final _sockets = <RawDatagramSocket>[];
  DlnaClient? _client;
  Completer<void>? _done;
  int _revision = 0;
  bool _disposed = false, scanning = false;
  String error = '';
  List<CastDevice> get devices =>
      _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> scan() async {
    if (_disposed || scanning) return;
    final revision = ++_revision;
    bool current() => !_disposed && revision == _revision;
    scanning = true;
    error = '';
    _devices.clear();
    final seen = <Uri>{};
    var fetching = 0;
    final tasks = <Future<void>>{};
    final done = _done = Completer<void>();
    Timer? deadline, repeat;
    final client = _client = DlnaClient(timeout: const Duration(seconds: 4));
    _changed();
    try {
      await platform.network(true);
      if (!current()) return;
      final localAddresses = await addresses();
      if (!current()) return;
      for (final address in localAddresses) {
        RawDatagramSocket? socket;
        try {
          socket = await RawDatagramSocket.bind(address, 0);
          if (!current()) {
            socket.close();
            return;
          }
          socket.setRawOption(
            RawSocketOption(
              RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface,
              address.rawAddress,
            ),
          );
          socket.multicastHops = 2;
          socket.writeEventsEnabled = false;
          _sockets.add(socket);
          final currentSocket = socket;
          socket.listen((event) {
            if (event != RawSocketEvent.read || !current()) return;
            Datagram? packet;
            while ((packet = currentSocket.receive()) != null) {
              final location = castLocation(packet!.data, packet.address);
              if (location == null ||
                  fetching >= 8 ||
                  seen.length >= 128 ||
                  !seen.add(location)) {
                continue;
              }
              fetching++;
              final task = () async {
                try {
                  final device = await client.describe(location);
                  if (current() && device != null) {
                    _devices[device.id] = device;
                    _changed();
                  }
                } catch (_) {
                  // Other SSDP devices and disappearing TVs are normal.
                } finally {
                  fetching--;
                }
              }();
              tasks.add(task);
              unawaited(task.whenComplete(() => tasks.remove(task)));
            }
          }, onError: (Object _) {});
        } on SocketException {
          socket?.close();
        }
      }
      require(_sockets.isNotEmpty, '未连接局域网，请先连接与电视相同的 Wi-Fi 或有线网络');
      void search() {
        for (final socket in _sockets) {
          for (final target in [
            'urn:schemas-upnp-org:device:MediaRenderer:1',
            'urn:schemas-upnp-org:service:AVTransport:1',
            'ssdp:all',
          ]) {
            try {
              socket.send(
                ascii.encode(
                  'M-SEARCH * HTTP/1.1\r\n'
                  'HOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\n'
                  'MX: 2\r\nST: $target\r\n\r\n',
                ),
                searchAddress,
                searchPort,
              );
            } on SocketException {
              /* Try other interfaces. */
            }
          }
        }
      }

      search();
      repeat = Timer(const Duration(seconds: 2), search);
      deadline = Timer(scanDuration, () {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
    } catch (e) {
      if (current()) {
        error = e is AppException ? e.message : '搜索电视失败，请检查局域网权限后重试';
      }
    } finally {
      deadline?.cancel();
      repeat?.cancel();
      for (final socket in _sockets) {
        socket.close();
      }
      _sockets.clear();
      client.close();
      await Future.wait(tasks.toList());
      try {
        await platform.network(false);
      } catch (_) {}
      if (identical(_client, client)) _client = null;
      if (identical(_done, done)) _done = null;
      if (current()) {
        scanning = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    if (_done?.isCompleted == false) _done!.complete();
    for (final socket in _sockets) {
      socket.close();
    }
    _client?.close();
    super.dispose();
  }
}
