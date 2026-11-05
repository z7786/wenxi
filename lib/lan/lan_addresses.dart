import 'dart:io';

import '../platform/windows_lan.dart';
import 'lan_models.dart';

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

Future<List<String>> localLanAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  final preferred = await windowsLanInterface();
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
  return entries.map((entry) => entry.address).toSet().toList();
}
