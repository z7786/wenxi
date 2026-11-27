import 'dart:io';

import '../diagnostics/app_log.dart';
import '../platform/windows_lan.dart';
import 'lan_models.dart';

typedef LanInterfaceReader =
    Future<List<NetworkInterface>> Function({
      required bool includeLinkLocal,
      required InternetAddressType type,
    });

int lanInterfacePriority(String name) {
  final value = name.toLowerCase();
  if (RegExp(
    r'virtual|vethernet|vmware|vbox|hyper-v|wsl|docker|loopback|tunnel|vpn|\btun\d*|\btap\d*|tailscale|zerotier',
  ).hasMatch(value)) {
    return 2;
  }
  return RegExp(r'wi-?fi|wlan|ethernet|\beth\d*|\ben\d*|以太|无线').hasMatch(value)
      ? 0
      : 1;
}

Future<List<String>> localLanAddresses({
  LanInterfaceReader listInterfaces = NetworkInterface.list,
  Future<int?> Function() preferredInterface = windowsLanInterface,
}) async {
  final interfaces = await listInterfaces(
    includeLinkLocal: true,
    type: InternetAddressType.any,
  );
  final preferred = await preferredInterface();
  final entries = [
    for (final nic in interfaces)
      for (final address in nic.addresses)
        if (!address.isLoopback && isLanAddress(address.address))
          (address: address.address, index: nic.index, name: nic.name),
  ];
  int priority(({String address, int index, String name}) entry) {
    if (entry.address.startsWith('169.254.')) return 10;
    final kind = lanInterfacePriority(entry.name);
    return entry.index == preferred && kind < 2 ? -1 : kind;
  }

  entries.sort((a, b) {
    final order = priority(a).compareTo(priority(b));
    if (order != 0) return order;
    final index = a.index.compareTo(b.index);
    return index != 0 ? index : a.address.compareTo(b.address);
  });
  if (entries.isEmpty) {
    final found = interfaces.expand((nic) => nic.addresses).toList();
    DiagnosticLog.event(
      'lan.network_unavailable',
      fields: {
        'interfaces': interfaces.length,
        'ipv4': found.where((a) => a.type == InternetAddressType.IPv4).length,
        'ipv6': found.where((a) => a.type == InternetAddressType.IPv6).length,
        'loopback': found.where((a) => a.isLoopback).length,
        'rejectedIpv4': found
            .where(
              (a) =>
                  a.type == InternetAddressType.IPv4 &&
                  !a.isLoopback &&
                  !isLanAddress(a.address),
            )
            .length,
      },
    );
  }
  return entries.map((entry) => entry.address).toSet().toList();
}
