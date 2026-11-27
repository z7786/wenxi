import 'dart:io';

import 'package:asterlink/core/json.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/lan/lan_addresses.dart';
import 'package:flutter_test/flutter_test.dart';

class _Interface implements NetworkInterface {
  _Interface(this.name, this.index, List<String> values)
    : addresses = values.map(InternetAddress.new).toList();
  @override
  final String name;
  @override
  final int index;
  @override
  final List<InternetAddress> addresses;
}

void main() {
  test(
    'A shared-address Wi-Fi interface is usable ahead of virtual adapters',
    () async {
      final found = [
        _Interface('Tailscale', 99, ['100.67.1.2']),
        _Interface('Ethernet', 6, ['192.168.2.8']),
        _Interface('Wi-Fi', 5, ['100.64.1.5', 'fe80::1', '127.0.0.1']),
        _Interface('Other', 8, ['8.8.8.8', '::1']),
        _Interface('Ethernet fallback', 2, ['169.254.12.2']),
      ];
      Future<List<String>> scan(int preferred) => localLanAddresses(
        listInterfaces: ({required includeLinkLocal, required type}) async =>
            found,
        preferredInterface: () async => preferred,
      );
      expect(await scan(5), [
        '100.64.1.5',
        '192.168.2.8',
        '100.67.1.2',
        '169.254.12.2',
      ]);
      // A VPN owning the default route must not displace the physical NICs.
      expect(await scan(99), [
        '100.64.1.5',
        '192.168.2.8',
        '100.67.1.2',
        '169.254.12.2',
      ]);
    },
  );

  test(
    'Link-local-only interfaces are requested and can enable interconnection',
    () async {
      final found = await localLanAddresses(
        listInterfaces: ({required includeLinkLocal, required type}) async => [
          _Interface('Ethernet', 3, [if (includeLinkLocal) '169.254.12.2']),
        ],
        preferredInterface: () async => null,
      );
      expect(found, ['169.254.12.2']);
    },
  );

  test(
    'No usable IPv4 logs address categories without IPs or interface names',
    () async {
      final previous = DiagnosticLog.active;
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        log.dispose();
        DiagnosticLog.active = previous;
      });
      final found = await localLanAddresses(
        listInterfaces: ({required includeLinkLocal, required type}) async => [
          _Interface('fixture-private-interface', 3, [
            if (type != InternetAddressType.IPv4) 'fe80::1',
            if (type != InternetAddressType.IPv4) '2001:db8::1',
            '8.8.8.8',
            '127.0.0.1',
          ]),
        ],
        preferredInterface: () async => null,
      );
      expect(found, isEmpty);
      final entry = log.entries().singleWhere(
        (e) => e.event == 'lan.network_unavailable',
      );
      expect(asJson(entry.data['fields']), {
        'interfaces': 1,
        'ipv4': 2,
        'ipv6': 2,
        'loopback': 1,
        'rejectedIpv4': 1,
      });
      for (final private in [
        'fixture-private-interface',
        '8.8.8.8',
        'fe80::1',
      ]) {
        expect(entry.detail, isNot(contains(private)));
      }
    },
  );
}
