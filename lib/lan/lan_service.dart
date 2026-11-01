import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/state_store.dart';
import '../domain/links.dart';
import '../domain/models.dart' show LinkKind;
import '../download/download_activity.dart';
import 'lan_datagrams.dart';
import 'lan_files.dart';
import 'lan_models.dart';
import 'lan_qr.dart';

part 'lan_server.dart';
part 'lan_discovery.dart';

class LanShare {
  LanShare(this.manifest, this.sources);
  final LanManifest manifest;
  final Map<String, LanLocalFile> sources;
  final clients = <String>{};
  final clientRequests = <String, int>{};
  final responses = <HttpResponse>{};
  bool stopped = false, draining = false;
  int transferred = 0;
  DateTime lastActivity = DateTime.now();
  bool expired(DateTime now) =>
      manifest.expiresAt != null && !manifest.expiresAt!.isAfter(now);
  Json get summary => {
    'token': manifest.token,
    'name': manifest.name,
    'fileCount': manifest.files.length,
    'size': manifest.size,
  };
}

class _LanSession {
  _LanSession(this.id, this.address, this.name, this.expires);
  final String id, address, name;
  final DateTime expires;
}

class _LanRequestError extends AppException {
  const _LanRequestError(super.message, this.status);
  final int status;
}

class LanService extends ChangeNotifier {
  LanService({
    required this.store,
    required this.files,
    this.foreground,
    this.discoveryEnabled = true,
    this.requestedPort = lanHttpPort,
    this.requestedDiscoveryPort = lanDiscoveryPort,
    InternetAddress? bindAddress,
    Future<List<String>> Function()? addresses,
    DateTime Function()? clock,
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _addresses = addresses ?? _localAddresses,
       clock = clock ?? DateTime.now {
    _inbox.addAll(
      store.data.list('lanInbox').map(LanInboxItem.fromJson).take(100),
    );
  }
  final StateStore store;
  final LanFiles files;
  final Future<void> Function()? foreground;
  final bool discoveryEnabled;
  final int requestedPort;
  final int requestedDiscoveryPort;
  final InternetAddress bindAddress;
  final Future<List<String>> Function() _addresses;
  final DateTime Function() clock;
  final _lifecycle = AsyncGate(), _inboxGate = AsyncGate();
  final _serviceZone = Zone.current;
  final _shares = <String, LanShare>{}, _peers = <String, LanPeer>{};
  final _sessions = <String, _LanSession>{};
  final _peerSessions =
      <String, ({String token, Uri base, DateTime expires})>{};
  final _attempts = <String, List<DateTime>>{};
  final _inbox = <LanInboxItem>[];
  HttpServer? _server;
  HttpClient? _client;
  RawDatagramSocket? _discovery;
  LanDatagrams? _datagrams;
  Timer? _heartbeat, _notifyTimer;
  List<String> addresses = [];
  String id = '', name = '', connectionCode = '', networkHint = '';
  bool _disposed = false, _running = false;
  bool _refreshingNetwork = false;
  int _networkTicks = 0;
  int _activeRequests = 0;
  bool get running => _running;
  int get port => _server?.port ?? 0;
  int get discoveryPort => _discovery?.port ?? 0;
  int get unread => _inbox.where((item) => !item.read).length;
  int get activeConnections =>
      _shares.values.fold(0, (n, share) => n + share.responses.length);
  List<LanPeer> get peers =>
      _peers.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  List<LanInboxItem> get inbox => List.unmodifiable(_inbox);
  LanPeer? senderOf(LanInboxItem item) => _peers[item.senderId];
  List<LanShare> get shares =>
      _shares.values.where((s) => !s.stopped && !s.expired(clock())).toList();
  bool connected(LanPeer peer) {
    final session = _peerSessions[peer.id];
    return session != null &&
        session.base == peer.base &&
        session.expires.isAfter(clock());
  }

  Future<void> refreshDevices() => _refreshDevices();
  DownloadActivity get activity => !running
      ? const DownloadActivity.idle()
      : DownloadActivity(
          active: 1,
          text: activeConnections > 0
              ? '设备互联 · $activeConnections 个连接正在传输'
              : unread > 0
              ? '设备互联 · $unread 条待查看消息'
              : '设备互联已开启 · 等待接收',
        );

  Future<void> start() => _lifecycle.run(() async {
    require(!_disposed, '设备互联已关闭');
    if (running) return;
    addresses = (await _addresses()).where(isLanAddress).toSet().toList();
    require(addresses.isNotEmpty, '未连接局域网，请先连接 Wi-Fi 或有线网络');
    id = store.data.str('lanDeviceId');
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      id = lanId();
      await store.put('lanDeviceId', id);
    }
    name = store.data
        .str('lanDeviceName')
        .ifEmpty(Platform.isAndroid ? '我的手机' : '我的电脑');
    connectionCode = Random.secure()
        .nextInt(1000000)
        .toString()
        .padLeft(6, '0');
    try {
      try {
        _server = await HttpServer.bind(bindAddress, requestedPort);
      } on SocketException {
        if (requestedPort == 0) rethrow;
        _server = await HttpServer.bind(bindAddress, 0);
      }
      _server!.idleTimeout = const Duration(seconds: 20);
      _running = true;
      // A picker/preparation cancellation must not cancel future HTTP streams.
      _serviceZone.run(
        () => _server!.listen((request) {
          unawaited(_handle(request));
        }, onError: (Object _) {}),
      );
      try {
        await files.network(true);
      } catch (_) {
        networkHint = '自动发现受系统限制，可输入设备地址连接';
      }
      if (discoveryEnabled) await _startDiscovery();
      _heartbeat = _serviceZone.run(
        () => Timer.periodic(const Duration(seconds: 3), (_) {
          _tick();
        }),
      );
      await foreground?.call();
      notifyListeners();
    } catch (_) {
      await _stop();
      rethrow;
    }
  });

  static Future<List<String>> _localAddresses() async => [
    for (final nic in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    ))
      for (final address in nic.addresses)
        if (!address.isLoopback && isLanAddress(address.address))
          address.address,
  ];

  Uri base([String? address]) {
    require(running && addresses.isNotEmpty, '请先开启设备互联');
    require(address == null || addresses.contains(address), '局域网地址已变化，请刷新');
    return Uri(scheme: 'http', host: address ?? addresses.first, port: port);
  }

  Uri shareUrl(LanShare share, [String? address]) =>
      base(address).replace(path: '/s/${share.manifest.token}');

  String connectionQr([String? address]) => LanConnectionQr(
    address: base(address),
    deviceId: id,
    code: connectionCode,
  ).encode();

  Future<void> rename(String value) async {
    final next = value.trim();
    require(
      next.isNotEmpty &&
          next.length <= 64 &&
          !RegExp(r'[\x00-\x1f]').hasMatch(next),
      '设备名称需要 1–64 个字符',
    );
    await store.put('lanDeviceName', next);
    name = next;
    _announce();
    _changed();
  }

  Future<LanShare> createShare(
    LanFileSelection selection, {
    Duration? lifetime = const Duration(hours: 1),
    void Function(int, int)? preparing,
  }) async {
    await start();
    require(shares.length < 32, '正在分享的项目过多，请先结束部分分享');
    final entries = <LanFileEntry>[], sources = <String, LanLocalFile>{};
    for (final file in selection.files) {
      RequestScope.checkpoint();
      preparing?.call(entries.length, selection.files.length);
      final digest = await files.digest(file);
      final key = lanId();
      entries.add(
        LanFileEntry(id: key, path: file.path, size: file.size, sha256: digest),
      );
      sources[key] = file;
    }
    require(running, '设备互联已关闭');
    RequestScope.checkpoint();
    final roots = {
      ...selection.directories.map((d) => d.split('/').first),
      ...selection.files.map((f) => f.path.split('/').first),
    };
    final manifest = LanManifest.fromJson(
      LanManifest(
        token: lanId(),
        name: roots.length == 1 ? roots.single : '${roots.length} 个文件和文件夹',
        files: entries,
        directories: selection.directories,
        expiresAt: lifetime == null ? null : clock().add(lifetime),
      ).toJson(),
    );
    final share = LanShare(manifest, sources);
    require(
      utf8.encode(jsonEncode(manifest.toJson())).length <= 8 * 1024 * 1024,
      '分享文件信息过多，请分批发送',
    );
    _shares[manifest.token] = share;
    _changed();
    return share;
  }

  void stopShare(LanShare share, {bool afterTransfers = false}) {
    if (afterTransfers && share.clients.isNotEmpty) {
      share.draining = true;
      share.lastActivity = clock();
    } else {
      share.stopped = true;
      _shares.remove(share.manifest.token);
      for (final response in share.responses.toList()) {
        unawaited(
          response.close().then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
      }
    }
    _changed();
  }

  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 10)
    ..maxConnectionsPerHost = 4
    ..autoUncompress = false
    ..findProxy = (_) => 'DIRECT';

  Future<Json> _json(
    Uri uri, {
    String method = 'GET',
    Json? body,
    String? session,
    HttpClient? client,
    bool invalidateSession = true,
  }) async {
    require(!_disposed, '设备互联已关闭');
    RequestScope.checkpoint();
    lanAddress(uri.toString());
    HttpClientRequest? request;
    final cancellation = RequestScope.current;
    var finished = false;
    unawaited(
      cancellation?.whenCancel.then<void>((_) {
        if (!finished) request?.abort();
      }),
    );
    try {
      request = await (client ?? _http)
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 6));
      RequestScope.checkpoint();
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (session != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $session');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.timeout(const Duration(seconds: 12))) {
        require(bytes.length + part.length <= 8 * 1024 * 1024, '设备返回的数据过大');
        bytes.add(part);
      }
      final data = asJson(jsonDecode(utf8.decode(bytes.takeBytes())));
      if ((response.statusCode == 401 || response.statusCode == 403) &&
          session != null &&
          invalidateSession) {
        _peerSessions.removeWhere((key, value) => value.token == session);
        _changed();
      }
      RequestScope.checkpoint();
      if (response.statusCode != 200) {
        throw _LanRequestError(
          data.str('error').ifEmpty('设备请求失败（${response.statusCode}）'),
          response.statusCode,
        );
      }
      return data;
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException('无法连接对方，请检查是否处于同一局域网且已开启设备互联');
    } finally {
      finished = true;
      request?.abort();
    }
  }

  Future<LanPeer> findDevice(String address) async {
    await start();
    final url = lanAddress(
      address,
    ).replace(path: '/v1/info', query: '', fragment: '');
    final peer = LanPeer.fromJson(await _json(url), url.host, clock());
    require(peer.id != id, '这是当前设备，请输入另一台设备的地址');
    require(peer.port == url.port, '设备地址发生变化，请重新连接');
    _peers[peer.id] = peer;
    _changed();
    return peer;
  }

  Future<void> connect(LanPeer peer, String code) async {
    await start();
    require(RegExp(r'^\d{6}$').hasMatch(code), '请输入对方设备显示的 6 位连接码');
    final replySession = lanId();
    final result = await _json(
      peer.base.replace(path: '/v1/pair'),
      method: 'POST',
      body: {
        'code': code,
        'id': id,
        'name': name,
        'port': port,
        'replySession': replySession,
      },
    );
    final token = result.str('session');
    require(RegExp(r'^[a-f0-9]{32}$').hasMatch(token), '设备返回的连接凭据无效');
    require(result.str('id') == peer.id, '对方设备已变化，请重新发现设备');
    require(running, '设备互联已关闭');
    final expires = clock().add(const Duration(hours: 4));
    if (result.boolean('bidirectional')) {
      _sessions.removeWhere(
        (key, value) =>
            !value.expires.isAfter(clock()) ||
            value.id == peer.id && value.address == peer.address,
      );
      require(_sessions.length < 64, '连接设备过多，请先关闭部分连接');
      _sessions[replySession] = _LanSession(
        peer.id,
        peer.address,
        peer.name,
        expires,
      );
    }
    _peerSessions[peer.id] = (token: token, base: peer.base, expires: expires);
    _peers[peer.id] = peer;
    _changed();
  }

  Future<LanPeer> connectQr(LanConnectionQr qr) async {
    final peer = await findDevice(qr.address.toString());
    require(peer.id == qr.deviceId, '二维码对应的设备已变化，请重新扫描对方的连接二维码');
    await connect(peer, qr.code);
    return peer;
  }

  Future<LanPeer> connectCode(String code) async {
    await start();
    require(RegExp(r'^\d{6}$').hasMatch(code), '请输入 6 位连接码');
    require(peers.isNotEmpty, '暂未发现设备，可使用“输入设备地址”连接');
    require(peers.length == 1, '发现多台设备，请先选择要连接的设备');
    // Submit a pairing code only to the selected device.
    final peer = peers.single;
    await connect(peer, code);
    return peer;
  }

  String _session(LanPeer peer) {
    require(connected(peer), '连接已失效，请重新输入对方的连接码');
    return _peerSessions[peer.id]!.token;
  }

  Future<List<LanShareSummary>> remoteShares(LanPeer peer) async {
    final data = await _json(
      peer.base.replace(path: '/v1/shares'),
      session: _session(peer),
    );
    return data.list('shares').map(LanShareSummary.fromJson).toList();
  }

  Future<LanManifest> readShare(String address) async {
    final uri = lanAddress(address);
    final match = RegExp(r'^/s/([a-f0-9]{32})/?$').firstMatch(uri.path);
    require(match != null, '请输入完整的设备互联分享链接');
    final result = LanManifest.fromJson(
      await _json(
        uri.replace(
          path: '/v1/manifests/${match![1]}',
          query: '',
          fragment: '',
        ),
      ),
    );
    require(result.token == match[1], '分享信息不匹配');
    return result;
  }

  Future<void> sendLink(LanPeer peer, String text) async {
    final value = text.trim();
    require(
      value.isNotEmpty &&
          value.length <= lanMaxMessageLength &&
          LinkParser.parse(value).isNotEmpty,
      '请粘贴网盘分享链接或完整分享文案',
    );
    await _sendInbox(peer, 'link', value);
  }

  Future<void> sendMessage(LanPeer peer, String text) async {
    final value = text.trim();
    require(value.isNotEmpty, '请输入要发送的消息');
    require(value.length <= lanMaxMessageLength, '消息过长，请缩短后再发送');
    final downloadable = LinkParser.parse(
      value,
    ).any((link) => link.kind != LinkKind.direct);
    final kind = downloadable ? 'link' : 'text';
    try {
      await _sendInbox(peer, kind, value);
    } on _LanRequestError catch (error) {
      if (kind == 'text' && error.status == 400 && error.message == '消息格式无效') {
        throw const AppException('对方版本暂不支持文字消息，请更新对方的文析助手后再发送');
      }
      rethrow;
    }
  }

  Future<void> _sendInbox(
    LanPeer peer,
    String kind,
    String value, {
    HttpClient? client,
  }) async {
    final result = await _json(
      peer.base.replace(path: '/v1/inbox'),
      method: 'POST',
      session: _session(peer),
      client: client,
      body: {'id': lanId(), 'kind': kind, 'value': value},
    );
    require(result.boolean('delivered'), '对方未确认收到消息，请稍后重试');
  }

  Future<void> sendShare(LanPeer peer, LanShare share) async {
    require(
      running &&
          identical(_shares[share.manifest.token], share) &&
          !share.stopped &&
          !share.draining &&
          !share.expired(clock()),
      '分享已结束，请重新选择文件',
    );
    final session = _session(peer);
    final address = await _shareAddress(peer, session);
    RequestScope.checkpoint();
    require(
      running &&
          identical(_shares[share.manifest.token], share) &&
          !share.stopped &&
          !share.draining &&
          !share.expired(clock()),
      '分享已结束，请重新选择文件',
    );
    final url = Uri(
      scheme: 'http',
      host: address,
      port: port,
      path: '/s/${share.manifest.token}',
    );
    lanAddress(url.toString());
    // Keep the invitation's source IP equal to the address confirmed by the
    // receiver, even when the device has several interfaces or routes.
    final client = _shareClient(address);
    try {
      await _sendInbox(peer, 'share', url.toString(), client: client);
    } finally {
      client.close(force: true);
    }
  }

  HttpClient _shareClient(String address) => HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..autoUncompress = false
    ..connectionFactory = ((uri, _, _) =>
        Socket.startConnect(uri.host, uri.port, sourceAddress: address))
    ..findProxy = (_) => 'DIRECT';

  Future<String> _shareAddress(LanPeer peer, String session) async {
    final endpoint = peer.base.replace(path: '/v1/shares');
    final info = await _json(endpoint, session: session);
    await _updateAddresses();
    RequestScope.checkpoint();
    require(running && addresses.isNotEmpty, '网络地址已变化，请刷新设备地址并重新连接');
    final observed = info.str('senderAddress');
    if (observed.isNotEmpty) {
      require(isLanAddress(observed), '对方返回的发送地址无效');
      if (!addresses.contains(observed)) {
        if (_peerSessions[peer.id]?.token == session) {
          _peerSessions.remove(peer.id);
          _changed();
        }
        throw const AppException('网络地址已变化，请刷新设备地址并重新连接');
      }
      return observed;
    }

    // Older receivers do not echo the observed address. An authenticated
    // probe bound to a local IP succeeds only if it matches the paired source.
    // A rejected candidate must not invalidate the otherwise valid session.
    for (final address in addresses.toList()) {
      final client = _shareClient(address);
      try {
        await _json(
          endpoint,
          session: session,
          client: client,
          invalidateSession: false,
        );
        return address;
      } on _LanRequestError catch (error) {
        if (error.status != 401 && error.status != 403) rethrow;
      } on AppException {
        RequestScope.checkpoint();
      } finally {
        client.close(force: true);
      }
    }
    throw const AppException('无法确认发送设备地址，请刷新设备地址并重新连接');
  }

  Future<void> markRead(LanInboxItem item, {bool remove = false}) =>
      _inboxGate.run(() async {
        final index = _inbox.indexWhere((m) => m.id == item.id);
        if (index < 0) return;
        final next = [..._inbox];
        if (remove) {
          next.removeAt(index);
        } else {
          next[index] = LanInboxItem.fromJson({...item.toJson(), 'read': true});
        }
        await store.put('lanInbox', next.map((m) => m.toJson()).toList());
        _inbox
          ..clear()
          ..addAll(next);
        _changed();
      });

  void _changed({bool progress = false}) {
    if (_disposed) return;
    if (progress) {
      _notifyTimer ??= Timer(const Duration(milliseconds: 200), () {
        _notifyTimer = null;
        _changed();
      });
      return;
    }
    notifyListeners();
    final callback = foreground;
    if (callback != null) unawaited(callback().catchError((_) {}));
  }

  void _tick() {
    if (!running) return;
    if (++_networkTicks % 5 == 0 && !_refreshingNetwork) {
      _refreshingNetwork = true;
      unawaited(
        _updateAddresses().catchError((_) {}).whenComplete(() {
          _refreshingNetwork = false;
        }),
      );
    }
    final now = clock();
    _peers.removeWhere(
      (key, peer) =>
          now.difference(peer.lastSeen).inSeconds > 15 && !connected(peer),
    );
    _sessions.removeWhere((key, session) => session.expires.isBefore(now));
    _peerSessions.removeWhere((key, session) => !session.expires.isAfter(now));
    _attempts.removeWhere(
      (key, times) =>
          times.isEmpty || now.difference(times.last).inMinutes >= 1,
    );
    for (final share in _shares.values.toList()) {
      if (share.expired(now)) stopShare(share);
    }
    _announce();
    _changed();
  }

  Future<void> stop() => _lifecycle.run(_stop);
  Future<void> _stop() async {
    _running = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _discovery?.close();
    _discovery = null;
    _datagrams?.close();
    _datagrams = null;
    for (final share in _shares.values) {
      share.stopped = true;
    }
    _shares.clear();
    _peers.clear();
    _peerSessions.clear();
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
    _client?.close(force: true);
    _client = null;
    try {
      await files.network(false);
    } catch (_) {}
    _changed();
  }

  Future<void> close() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    dispose();
  }
}
