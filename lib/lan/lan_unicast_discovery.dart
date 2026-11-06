import 'dart:io';
import 'lan_models.dart';

// Existing clients already answer "discover" packets sent to their UDP port.
// Unicast works on iOS without the restricted broadcast/multicast entitlement.
List<InternetAddress> lanUnicastTargets(List<String> addresses) {
  final subnets = <String>{};
  final local = addresses.toSet();
  for (final address in addresses) {
    if (!isLanAddress(address) || address.startsWith('127.')) continue;
    subnets.add(address.split('.').take(3).join('.'));
    if (subnets.length >= 4) break;
  }
  return [
    for (final subnet in subnets)
      for (var host = 1; host < 255; host++)
        if (!local.contains('$subnet.$host')) InternetAddress('$subnet.$host'),
  ];
}
