part of 'lan_service.dart';

extension _LanDiscovery on LanService {
  Future<void> _startDiscovery() async {
    networkHint = '';
    final server = _server;
    try {
      try {
        _discovery = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          requestedDiscoveryPort,
          reuseAddress: true,
          reusePort: !Platform.isWindows,
        );
      } on SocketException {
        _discovery = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      }
      final socket = _discovery!;
      if (!running || server != _server) {
        socket.close();
        if (_discovery == socket) _discovery = null;
        return;
      }
      final datagrams = LanDatagrams(socket);
      _datagrams = datagrams;
      socket.broadcastEnabled = true;
      socket.multicastHops = 1;
      for (final nic in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        try {
          socket.joinMulticast(InternetAddress('239.255.77.81'), nic);
        } catch (_) {}
      }
      socket.listen((event) {
        if (!running || socket != _discovery) return;
        if (event == RawSocketEvent.write) {
          datagrams.flush();
          return;
        }
        if (event != RawSocketEvent.read) return;
        for (
          var packet = socket.receive();
          packet != null;
          packet = socket.receive()
        ) {
          if (packet.data.length > 2048 ||
              !isLanAddress(packet.address.address)) {
            continue;
          }
          try {
            final data = asJson(jsonDecode(utf8.decode(packet.data)));
            var peer = LanPeer.fromJson(data, packet.address.address, clock());
            if (peer.id == id) continue;
            final previous = _peers[peer.id];
            final fresh = previous == null;
            if (fresh && _peers.length >= 128) continue;
            final paired = _peerSessions[peer.id];
            if (paired != null && paired.expires.isAfter(clock())) {
              if (peer.address != paired.base.host) {
                // Broadcasts may leave through a different NIC from the one
                // selected by QR/manual pairing. Keep that authenticated
                // endpoint rather than making the device appear disconnected
                // whenever another interface announces the same device ID.
                peer = LanPeer(
                  id: peer.id,
                  name: peer.name,
                  address: paired.base.host,
                  port: paired.base.port,
                  lastSeen: peer.lastSeen,
                );
              } else if (peer.port != paired.base.port) {
                // A port change on the paired address means the old listener
                // has gone. Let discovery expose the new endpoint for pairing.
                _peerSessions.remove(peer.id);
              }
            }
            _peers[peer.id] = peer;
            if (data.boolean('discover')) {
              datagrams.send(_discoveryPacket(), packet.address, packet.port);
            }
            if (fresh ||
                previous.name != peer.name ||
                previous.base != peer.base) {
              _changed();
            }
          } catch (_) {}
        }
      }, onError: (Object _) {});
      _announce(discover: true);
    } catch (_) {
      _discovery?.close();
      _discovery = null;
      _datagrams?.close();
      _datagrams = null;
      networkHint = '自动发现暂不可用，可输入对方显示的设备地址连接';
    }
  }

  List<int> _discoveryPacket({bool discover = false}) => utf8.encode(
    jsonEncode({
      'protocol': lanProtocol,
      'id': id,
      'name': name,
      'port': port,
      'discover': discover,
    }),
  );
  void _announce({bool discover = false}) {
    if (!running || _discovery == null || _datagrams == null) return;
    final targetPort = requestedDiscoveryPort == 0
        ? lanDiscoveryPort
        : requestedDiscoveryPort;
    // A fallback port cannot hear unsolicited broadcasts on the well-known
    // port. Ask peers to reply to it on every heartbeat as well as on refresh.
    final packet = _discoveryPacket(
      discover: discover || _discovery!.port != targetPort,
    );
    final targets = <String>{
      if (addresses.any((address) => !address.startsWith('127.'))) ...[
        '255.255.255.255',
        '239.255.77.81',
      ],
    };
    for (final address in addresses) {
      if (address.startsWith('127.')) continue;
      final parts = address.split('.');
      targets.add('${parts.take(3).join('.')}.255');
    }
    for (final target in targets) {
      try {
        _datagrams!.send(packet, InternetAddress(target), targetPort);
      } catch (_) {}
    }
  }

  Future<void> _refreshDevices() async {
    await start();
    await _updateAddresses();
    if (!running) return;
    if (discoveryEnabled && _discovery == null) await _startDiscovery();
    _announce(discover: true);
    _changed();
  }

  Future<void> _updateAddresses() async {
    final server = _server;
    final current = (await _addresses()).where(isLanAddress).toSet().toList();
    if (!running || server != _server) return;
    if (listEquals(current, addresses)) return;
    addresses = current;
    _announce(discover: true);
    _changed();
  }
}
