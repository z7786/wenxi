part of 'lan_service.dart';

extension _LanHttpDiscovery on LanService {
  void _rememberPeerEndpoint(LanPeer peer, {bool persist = false}) {
    final endpoints = _peerEndpoints.putIfAbsent(peer.id, () => []);
    endpoints.remove(peer.base);
    endpoints.insert(0, peer.base);
    if (endpoints.length > 8) endpoints.removeLast();
    if (!persist || peer.id == id) return;
    // Only public numeric LAN endpoints are kept, never codes or sessions.
    final saved = store.data.list('lanKnownDevices');
    final value = {
      'id': peer.id,
      'name': peer.name,
      'address': peer.base.toString(),
    };
    if (saved.any(
      (entry) =>
          entry.str('id') == peer.id &&
          entry.str('name') == peer.name &&
          entry.str('address') == peer.base.toString(),
    )) {
      return;
    }
    final next = [
      value,
      ...saved.where((entry) => entry.str('id') != peer.id),
    ].take(32).toList();
    unawaited(store.put('lanKnownDevices', next).catchError((_) {}));
  }

  void _observePeer(LanPeer peer, {bool persist = false}) {
    if (!running ||
        peer.id == id ||
        !_peers.containsKey(peer.id) && _peers.length >= 128) {
      return;
    }
    _rememberPeerEndpoint(peer, persist: persist);
    _httpSeen[peer.id] = clock();
    final previous = _peers[peer.id];
    final paired = _peerSessions[peer.id];
    if (paired != null && paired.expires.isAfter(clock())) {
      if (peer.address != paired.base.host) {
        peer = LanPeer(
          id: peer.id,
          name: peer.name,
          address: paired.base.host,
          port: paired.base.port,
          lastSeen: peer.lastSeen,
        );
      } else if (peer.port != paired.base.port) {
        _disconnectPeer(peer.id);
      }
    }
    _peers[peer.id] = peer;
    if (previous == null ||
        previous.name != peer.name ||
        previous.base != peer.base) {
      _changed();
    }
  }

  void _scheduleHttpDiscovery({bool immediate = false}) {
    if (!running || !discoveryEnabled) return;
    _httpDiscoveryTimer?.cancel();
    _httpDiscoveryTimer = _serviceZone.run(
      () => Timer(Duration(milliseconds: immediate ? 0 : 900), () {
        _httpDiscoveryTimer = null;
        if (!running || _httpDiscoveryScope != null) return;
        final scope = RequestScope();
        _httpDiscoveryScope = scope;
        _lastHttpDiscovery = clock();
        unawaited(
          _serviceZone.run(
            () => scope.run(() async {
              final elapsed = Stopwatch()..start();
              var subnetScanned = false;
              try {
                final known = <Uri>{
                  for (final peer in peers) peer.base,
                  for (final endpoints in _peerEndpoints.values) ...endpoints,
                };
                for (final entry
                    in store.data.list('lanKnownDevices').take(32)) {
                  try {
                    known.add(lanAddress(entry.str('address')));
                  } catch (_) {}
                }
                final reachable = await _probeHttpBatch(known.take(64), scope);
                // Broadcasts get a chance first. Scan only a bounded set of local
                // /24 subnets when they have not found a reachable device.
                if ((immediate || !reachable) &&
                    (immediate ||
                        _lastHttpSubnetScan == null ||
                        clock().difference(_lastHttpSubnetScan!).inSeconds >=
                            60)) {
                  _lastHttpSubnetScan = clock();
                  subnetScanned = true;
                  final targets = lanUnicastTargets(addresses)
                      .take(508)
                      .map(
                        (address) => Uri(
                          scheme: 'http',
                          host: address.address,
                          port: lanHttpPort,
                        ),
                      );
                  await _probeHttpBatch(targets, scope);
                }
              } catch (_) {
                // Discovery is best effort; manual addresses remain available.
              } finally {
                if (_httpDiscoveryScope == scope) _httpDiscoveryScope = null;
                if (!scope.token.isCancelled && running) {
                  DiagnosticLog.event(
                    'lan.discovery',
                    fields: {
                      'peers': _peers.length,
                      'subnetScan': subnetScanned,
                      'durationMs': elapsed.elapsedMilliseconds,
                    },
                  );
                }
              }
            }),
          ),
        );
      }),
    );
  }

  Future<bool> _probeHttpBatch(
    Iterable<Uri> endpoints,
    RequestScope scope,
  ) async {
    final pending = Queue<Uri>.from(
      endpoints.where(
        (endpoint) =>
            !(addresses.contains(endpoint.host) && endpoint.port == port),
      ),
    );
    final workers = min(12, pending.length);
    var reachable = false;
    await Future.wait([
      for (var i = 0; i < workers; i++)
        () async {
          while (running && !scope.token.isCancelled && pending.isNotEmpty) {
            reachable =
                await _probeHttpPeer(pending.removeFirst(), scope) || reachable;
          }
        }(),
    ]);
    return reachable;
  }

  Future<bool> _probeHttpPeer(
    Uri endpoint,
    RequestScope scope, {
    String? expectedId,
  }) async {
    if (!running || _httpProbes.containsKey(endpoint)) return false;
    _httpProbes[endpoint] = scope;
    final server = _server;
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(milliseconds: 650)
      ..autoUncompress = false;
    final cancelled = scope.token.whenCancel.asStream().listen(
      (_) => client.close(force: true),
    );
    try {
      final info = await _json(
        endpoint.replace(path: '/v1/info', query: '', fragment: ''),
        client: client,
        retry: false,
        timeout: const Duration(milliseconds: 650),
        maxBytes: 8192,
      );
      final peer = LanPeer.fromJson(info, endpoint.host, clock());
      require(
        peer.port == endpoint.port &&
            (expectedId == null || expectedId == peer.id),
        '设备地址已变化',
      );
      if (!running || _server != server || scope.token.isCancelled) {
        return false;
      }
      _observePeer(peer, persist: true);
      _httpSeen[peer.id] = clock();
      // HTTP confirmation also lets the other side see us when UDP is blocked.
      try {
        await _json(
          endpoint.replace(path: '/v1/discover', query: '', fragment: ''),
          method: 'POST',
          body: {'protocol': lanProtocol, 'id': id, 'name': name, 'port': port},
          client: client,
          retry: false,
          timeout: const Duration(milliseconds: 650),
          maxBytes: 8192,
        );
      } catch (_) {}
      return true;
    } catch (_) {
      // Unreachable and unrelated LAN hosts are normal during discovery.
      return false;
    } finally {
      client.close(force: true);
      await cancelled.cancel();
      if (_httpProbes[endpoint] == scope) _httpProbes.remove(endpoint);
    }
  }
}
