import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../core/json.dart';

Future<int?> windowsLanInterface() async {
  if (!Platform.isWindows) return null;
  return Isolate.run(() {
    final index = calloc<Uint32>();
    try {
      final getBestInterface = DynamicLibrary.open('iphlpapi.dll')
          .lookupFunction<
            Uint32 Function(Uint32, Pointer<Uint32>),
            int Function(int, Pointer<Uint32>)
          >('GetBestInterface');
      // Query the routing table only; no Internet request is sent.
      return getBestInterface(0x01010101, index) == 0 ? index.value : null;
    } catch (_) {
      return null;
    } finally {
      calloc.free(index);
    }
  });
}

String _psQuote(String text) => "'${text.replaceAll("'", "''")}'";

String _encodedScript(String text) => base64Encode([
  for (final unit in text.codeUnits) ...[unit & 255, unit >> 8],
]);

/// Install rules for this executable and the active LAN listener only.
/// Windows asks for elevation when the user chooses the repair action.
Future<void> allowWindowsLanConnections(int httpPort, int discoveryPort) async {
  require(Platform.isWindows, '此操作仅适用于 Windows');
  require(
    httpPort > 0 &&
        httpPort <= 65535 &&
        discoveryPort > 0 &&
        discoveryPort <= 65535,
    '请先开启设备互联',
  );
  final executable = Platform.resolvedExecutable;
  final identity = sha256
      .convert(utf8.encode(executable.toLowerCase()))
      .toString()
      .substring(0, 16);
  final script =
      '''
\$ErrorActionPreference = 'Stop'
try {
  Get-NetFirewallApplicationFilter -Program ${_psQuote(executable)} -ErrorAction SilentlyContinue | Get-NetFirewallRule | Where-Object { \$_.Direction -eq 'Inbound' -and \$_.Action -eq 'Block' -and \$_.Name -match '^(TCP|UDP) Query User' } | Remove-NetFirewallRule
  foreach (\$entry in @(@('TCP', $httpPort), @('UDP', $discoveryPort))) {
    \$name = 'AsterLink-LAN-$identity-' + \$entry[0]
    Get-NetFirewallRule -Name \$name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name \$name -DisplayName ('文析助手设备互联 ' + \$entry[0]) -Direction Inbound -Action Allow -Profile Any -Program ${_psQuote(executable)} -Protocol \$entry[0] -LocalPort \$entry[1] -RemoteAddress LocalSubnet | Out-Null
  }
  exit 0
} catch { exit 1 }
''';
  final elevation =
      '''
try {
  \$process = Start-Process -FilePath (Join-Path \$PSHOME 'powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', '${_encodedScript(script)}') -Wait -PassThru -ErrorAction Stop
  exit \$process.ExitCode
} catch { exit 1 }
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-EncodedCommand',
    _encodedScript(elevation),
  ]);
  require(result.exitCode == 0, '未能允许局域网连接，请完成 Windows 权限确认后重试');
}
