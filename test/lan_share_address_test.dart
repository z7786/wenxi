import 'dart:convert';
import 'dart:io';

import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Model two devices with distinct source IPs on one host. Production uses the
// OS route; this override makes both directions deterministic on loopback.
class _DeviceIo extends HttpOverrides {
  final sourceByPort = <int, String>{};

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = ((uri, _, _) => Socket.startConnect(
          uri.host,
          uri.port,
          sourceAddress: sourceByPort[uri.port] ?? '127.0.0.1',
        ))
        ..findProxy = (_) => 'DIRECT';
}

void main() {
  late Directory root;
  late _DeviceIo io;
  late LanService sender, receiver;
  late LanFiles files;
  late List<String> senderAddresses, receiverAddresses;

  Future<LanShare> share(LanService device) async {
    final file = await File(
      p.join(root.path, '${device.id}.txt'),
    ).writeAsString('LAN payload from ${device.id}');
    return device.createShare(await files.scan([file.path]));
  }

  Future<LanPeer> pair() async {
    final peer = await sender.findDevice(receiver.base('127.0.0.2').toString());
    await sender.connect(peer, receiver.connectionCode);
    return peer;
  }

  setUp(() async {
    io = _DeviceIo();
    HttpOverrides.global = io;
    root = await Directory.systemTemp.createTemp('aster-lan-share-address-');
    files = LanFiles(android: false);
    // Put another interface first to catch fixes that pick addresses.first.
    senderAddresses = ['127.0.0.3', '127.0.0.1'];
    receiverAddresses = ['127.0.0.4', '127.0.0.2'];
    sender = LanService(
      store: StateStore.memory({'lanDeviceName': '发送电脑'}),
      files: files,
      discoveryEnabled: false,
      requestedPort: 0,
      bindAddress: InternetAddress('127.0.0.1'),
      addresses: () async => senderAddresses,
    );
    receiver = LanService(
      store: StateStore.memory({'lanDeviceName': '接收手机'}),
      files: LanFiles(android: false),
      discoveryEnabled: false,
      requestedPort: 0,
      bindAddress: InternetAddress('127.0.0.2'),
      addresses: () async => receiverAddresses,
    );
    await sender.start();
    await receiver.start();
    io.sourceByPort[receiver.port] = '127.0.0.1';
    io.sourceByPort[sender.port] = '127.0.0.2';
  });

  tearDown(() async {
    await sender.close();
    await receiver.close();
    await root.delete(recursive: true);
    HttpOverrides.global = null;
  });

  test(
    'Different IP devices send verified file invitations both ways',
    () async {
      final peer = await pair();
      final published = await share(sender);
      await sender.sendShare(peer, published);
      final received = receiver.inbox.single;
      expect(received.kind, 'share');
      expect(received.senderId, sender.id);
      final url = Uri.parse(received.value);
      expect(url.host, '127.0.0.1');
      expect(url.port, sender.port);
      final manifest = await receiver.readShare(received.value);
      expect(manifest.token, published.manifest.token);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          Uri.parse(manifest.downloads(url).single.url),
        )).close();
        expect(response.statusCode, 200);
        expect(
          await utf8.decoder.bind(response).join(),
          'LAN payload from ${sender.id}',
        );
      } finally {
        client.close(force: true);
      }

      final reply = await share(receiver);
      await receiver.sendShare(receiver.peers.single, reply);
      final reverse = sender.inbox.single;
      expect(reverse.senderId, receiver.id);
      expect(Uri.parse(reverse.value).host, '127.0.0.2');
      expect(
        (await sender.readShare(reverse.value)).token,
        reply.manifest.token,
      );
    },
  );

  test('Network changes require re-pairing before file delivery', () async {
    final peer = await pair();
    final published = await share(sender);
    io.sourceByPort[receiver.port] = '127.0.0.3';
    senderAddresses = ['127.0.0.3'];
    await expectLater(
      sender.sendShare(peer, published),
      throwsA(isA<AppException>()),
    );
    expect(sender.connected(peer), isFalse);
    expect(receiver.inbox, isEmpty);
    senderAddresses = ['127.0.0.3', '127.0.0.1'];
    io.sourceByPort[receiver.port] = '127.0.0.1';
    await sender.connect(peer, receiver.connectionCode);
    await sender.sendShare(peer, published);
    expect(receiver.inbox.single.kind, 'share');
  });

  test('Share invitations cannot point at an unrelated source IP', () async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        receiver.base('127.0.0.2').replace(path: '/v1/pair'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'code': receiver.connectionCode,
          'id': sender.id,
          'name': sender.name,
        }),
      );
      final paired = asJson(
        jsonDecode(await utf8.decoder.bind(await request.close()).join()),
      );
      final message = await client.postUrl(
        receiver.base('127.0.0.2').replace(path: '/v1/inbox'),
      );
      message.headers.contentType = ContentType.json;
      message.headers.set('Authorization', 'Bearer ${paired.str('session')}');
      message.write(
        jsonEncode({
          'id': lanId(),
          'kind': 'share',
          'value': 'http://127.0.0.2:${sender.port}/s/${lanId()}',
        }),
      );
      final rejected = await message.close();
      expect(rejected.statusCode, 400);
      expect(
        await utf8.decoder.bind(rejected).join(),
        contains('分享来源与发送设备不一致'),
      );
      expect(receiver.inbox, isEmpty);
    } finally {
      client.close(force: true);
    }
  });

  test(
    'Foreign and ended shares are rejected before invitation delivery',
    () async {
      final peer = await pair();
      final foreign = await share(receiver);
      await expectLater(
        sender.sendShare(peer, foreign),
        throwsA(isA<AppException>()),
      );
      final ended = await share(sender);
      sender.stopShare(ended);
      await expectLater(
        sender.sendShare(peer, ended),
        throwsA(isA<AppException>()),
      );
      expect(receiver.inbox, isEmpty);
    },
  );

  test(
    'Older receiver confirms the paired source despite multiple interfaces',
    () async {
      final legacy = await HttpServer.bind(InternetAddress('127.0.0.2'), 0);
      io.sourceByPort[legacy.port] = '127.0.0.1';
      final legacyId = lanId(), token = lanId();
      String pairedSource = '', invitation = '';
      final probedSources = <String>[];
      legacy.listen((request) async {
        final response = request.response;
        response.headers.contentType = ContentType.json;
        final remote = request.connectionInfo!.remoteAddress.address;
        try {
          final body = request.method == 'POST'
              ? asJson(jsonDecode(await utf8.decoder.bind(request).join()))
              : <String, dynamic>{};
          if (request.uri.path == '/v1/info') {
            response.write(
              jsonEncode({
                'protocol': lanProtocol,
                'id': legacyId,
                'name': '旧版接收端',
                'port': legacy.port,
              }),
            );
          } else if (request.uri.path == '/v1/pair') {
            pairedSource = remote;
            response.write(jsonEncode({'session': token, 'id': legacyId}));
          } else if (request.uri.path == '/v1/shares') {
            probedSources.add(remote);
            if (remote != pairedSource ||
                request.headers.value('Authorization') != 'Bearer $token') {
              response.statusCode = 401;
              response.write(jsonEncode({'error': '连接已失效，请重新输入对方的连接码'}));
            } else {
              response.write(jsonEncode({'shares': []}));
            }
          } else if (request.uri.path == '/v1/inbox') {
            invitation = body.str('value');
            if (Uri.parse(invitation).host != remote ||
                remote != pairedSource) {
              response.statusCode = 400;
              response.write(jsonEncode({'error': '分享来源与发送设备不一致'}));
            } else {
              response.write(jsonEncode({'delivered': true}));
            }
          } else {
            response.statusCode = 404;
            response.write(jsonEncode({'error': 'not found'}));
          }
        } finally {
          await response.close();
        }
      });
      try {
        final peer = await sender.findDevice('http://127.0.0.2:${legacy.port}');
        await sender.connect(peer, '123456');
        final published = await share(sender);
        await sender.sendShare(peer, published);
        expect(probedSources, contains('127.0.0.3'));
        expect(Uri.parse(invitation).host, '127.0.0.1');
        expect(Uri.parse(invitation).port, sender.port);
        expect(sender.connected(peer), isTrue);
      } finally {
        await legacy.close(force: true);
      }
    },
  );
}
