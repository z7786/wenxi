import 'dart:convert';
import 'dart:io';

import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/lan/lan_addresses.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_qr.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _LocalIo extends HttpOverrides {}

void main() {
  test('Physical Wi-Fi and Ethernet precede virtual and tunnel interfaces', () {
    for (final name in ['Wi-Fi', 'wlan0', '以太网', 'en0', 'Ethernet']) {
      expect(lanInterfacePriority(name), 0, reason: name);
    }
    for (final name in [
      'vEthernet (WSL)',
      'VMware Network Adapter',
      'tun0',
      'Tailscale',
      'VirtualBox',
    ]) {
      expect(lanInterfacePriority(name), 2, reason: name);
    }
  });

  for (final qrMode in [true, false]) {
    test(
      '${qrMode ? 'Scanning QR' : 'Selecting a discovered device'} tries another endpoint with the same device ID',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          LanService device(String name) => LanService(
            store: StateStore.memory({'lanDeviceName': name}),
            files: LanFiles(android: false),
            requestedPort: 0,
            requestedDiscoveryPort: 0,
            bindAddress: InternetAddress.loopbackIPv4,
            addresses: () async => ['127.0.0.1'],
          );
          final computer = device('Computer'), phone = device('Phone');
          final alternate = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final offline = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final oldPort = offline.port;
          await offline.close(force: true);
          try {
            await computer.start();
            await phone.start();
            alternate.send(
              utf8.encode(
                jsonEncode({
                  'protocol': lanProtocol,
                  'id': computer.id,
                  'name': computer.name,
                  'port': computer.port,
                  'discover': true,
                }),
              ),
              InternetAddress.loopbackIPv4,
              phone.discoveryPort,
            );
            await until(() => phone.peers.isNotEmpty);
            final peer = qrMode
                ? await phone.connectQr(
                    LanConnectionQr(
                      address: Uri(
                        scheme: 'http',
                        host: '127.0.0.1',
                        port: oldPort,
                      ),
                      deviceId: computer.id,
                      code: computer.connectionCode,
                    ),
                  )
                : await (() async {
                    await phone.connect(
                      LanPeer(
                        id: computer.id,
                        name: computer.name,
                        address: '127.0.0.1',
                        port: oldPort,
                        lastSeen: DateTime.now(),
                      ),
                      computer.connectionCode,
                    );
                    return phone.peers.single;
                  })();
            expect(peer.base, computer.base());
            expect(phone.connected(peer), isTrue);
            await phone.sendMessage(peer, 'Phone connected to computer');
            expect(computer.inbox.single.value, 'Phone connected to computer');
            await computer.sendMessage(
              computer.peers.single,
              'Computer replied',
            );
            expect(phone.inbox.single.value, 'Computer replied');
          } finally {
            alternate.close();
            await phone.close();
            await computer.close();
          }
        }, _LocalIo());
      },
    );
  }

  test(
    'A QR fallback never sends the connection code to a different device',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var pairCalls = 0;
        server.listen((request) async {
          if (request.uri.path == '/v1/pair') pairCalls++;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'protocol': lanProtocol,
              'id': lanId(),
              'name': 'Other computer',
              'port': server.port,
            }),
          );
          await request.response.close();
        });
        final phone = LanService(
          store: StateStore.memory(),
          files: LanFiles(android: false),
          requestedPort: 0,
          discoveryEnabled: false,
          bindAddress: InternetAddress.loopbackIPv4,
          addresses: () async => ['127.0.0.1'],
        );
        try {
          await expectLater(
            phone.connectQr(
              LanConnectionQr(
                address: Uri(
                  scheme: 'http',
                  host: '127.0.0.1',
                  port: server.port,
                ),
                deviceId: lanId(),
                code: '123456',
              ),
            ),
            throwsA(isA<AppException>()),
          );
          expect(pairCalls, 0);
          expect(phone.peers.where(phone.connected), isEmpty);
        } finally {
          await phone.close();
          await server.close(force: true);
        }
      }, _LocalIo());
    },
  );
}
