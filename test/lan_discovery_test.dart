import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/lan/lan_datagrams.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:asterlink/lan/lan_unicast_discovery.dart';
import 'support.dart';

void main() {
  test(
    'iOS unicast targets cover local subnets without broadcast or duplicate addresses',
    () {
      final targets = lanUnicastTargets([
        '192.168.2.5',
        '192.168.2.6',
        '10.0.0.3',
        '127.0.0.1',
        '8.8.8.8',
      ]).map((address) => address.address).toList();
      expect(targets.length, 505);
      expect(targets.toSet().length, targets.length);
      for (final excluded in [
        '192.168.2.5',
        '192.168.2.6',
        '10.0.0.3',
        '192.168.2.255',
        '127.0.0.1',
        '8.8.8.8',
      ]) {
        expect(targets, isNot(contains(excluded)));
      }
      expect(targets, contains('192.168.2.254'));
      expect(targets, contains('10.0.0.1'));
    },
  );
  test(
    'unicast-only heartbeats request replies and keep legacy peers visible',
    () async {
      final store = StateStore.memory();
      final remote = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: false,
        reusePort: false,
      );
      final datagrams = LanDatagrams(remote);
      final peer = lanId(), received = <Json>[];
      final local = LanService(
        store: store,
        files: LanFiles(android: false),
        unicastDiscovery: true,
        requestedPort: 0,
        requestedDiscoveryPort: remote.port,
        bindAddress: InternetAddress.loopbackIPv4,
        addresses: () async => ['127.0.0.1'],
      );
      final subscription = remote.listen((event) {
        if (event == RawSocketEvent.write) {
          datagrams.flush();
          return;
        }
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = remote.receive()) != null) {
          final value = asJson(jsonDecode(utf8.decode(packet!.data)));
          received.add(value);
          if (value.boolean('discover')) {
            datagrams.send(
              utf8.encode(
                jsonEncode({
                  'protocol': lanProtocol,
                  'id': peer,
                  'name': '旧版电脑',
                  'port': 32123,
                }),
              ),
              packet.address,
              packet.port,
            );
          }
        }
      });
      try {
        await local.start();
        expect(
          local.discoveryPort,
          isNot(remote.port),
          reason: 'An occupied UDP port must use the fallback listener',
        );
        datagrams.send(
          utf8.encode(
            jsonEncode({
              'protocol': lanProtocol,
              'id': peer,
              'name': '旧版电脑',
              'port': 32123,
            }),
          ),
          InternetAddress.loopbackIPv4,
          local.discoveryPort,
        );
        await until(() => local.peers.isNotEmpty);
        final before = local.peers.single.lastSeen;
        await local.rename('已更新手机');
        await until(
          () =>
              received.isNotEmpty &&
              local.peers.single.lastSeen.isAfter(before),
        );
        expect(received.last.boolean('discover'), isTrue);
        expect(local.peers.single.id, peer);
        expect(received.last.str('name'), '已更新手机');
        await local.stop();
        expect(local.peers, isEmpty);
      } finally {
        await local.close();
        await subscription.cancel();
        datagrams.close();
        remote.close();
        store.dispose();
      }
    },
  );
  test(
    'UDP discovery exchanges only device identity and the current HTTP port',
    () async {
      final local = LanService(
        store: StateStore.memory(),
        files: LanFiles(android: false),
        requestedPort: 0,
        requestedDiscoveryPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        addresses: () async => ['127.0.0.1'],
      );
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final outgoing = LanDatagrams(probe);
      final reply = Completer<Json>();
      probe.listen((event) {
        if (event == RawSocketEvent.write) {
          outgoing.flush();
          return;
        }
        if (event != RawSocketEvent.read) return;
        final packet = probe.receive();
        if (packet != null && !reply.isCompleted) {
          reply.complete(asJson(jsonDecode(utf8.decode(packet.data))));
        }
      });
      try {
        await local.start();
        expect(local.discoveryPort, greaterThan(0));
        final peerId = lanId();
        void send(Json data) => outgoing.send(
          utf8.encode(jsonEncode(data)),
          InternetAddress.loopbackIPv4,
          local.discoveryPort,
        );
        send({
          'protocol': lanProtocol,
          'id': peerId,
          'name': '测试手机',
          'port': 32123,
          'discover': true,
        });
        final announced = await reply.future.timeout(
          const Duration(seconds: 6),
        );
        expect(announced.keys.toSet(), {
          'protocol',
          'id',
          'name',
          'port',
          'discover',
        });
        expect(announced.str('protocol'), lanProtocol);
        expect(announced.integer('port'), local.port);
        expect(announced.str('id'), local.id);
        expect(local.peers.single.id, peerId);
        expect(local.peers.single.port, 32123);
        send({
          'protocol': 'not-compatible',
          'id': lanId(),
          'name': 'unexpected',
          'port': 1,
        });
        send({
          'protocol': lanProtocol,
          'id': peerId,
          'name': '手机改名',
          'port': 32123,
        });
        await until(() => local.peers.single.name == '手机改名');
        expect(local.peers.length, 1);
        await local.stop();
        expect(local.discoveryPort, 0);
        expect(local.peers, isEmpty);
      } finally {
        outgoing.close();
        probe.close();
        await local.close();
      }
    },
  );
}
