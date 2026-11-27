import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

class WindowsProxyException implements Exception {
  const WindowsProxyException(this.reason, [this.systemCode]) : cause = null;
  const WindowsProxyException.connection(this.cause)
    : reason = 'connection',
      systemCode = null;
  final String reason;
  final int? systemCode;
  final Object? cause;
  String get message => switch (reason) {
    'unsupported' => 'Windows 系统代理类型不支持，请使用代理软件的 HTTP 或混合端口',
    'connection' => '通过 Windows 系统代理连接失败，请检查代理软件后重试',
    _ => 'Windows 系统代理读取失败，请检查代理软件的系统代理设置后重试',
  };

  // Never include a PAC URL or proxy credentials in exceptions/diagnostics.
  @override
  String toString() => 'WindowsProxyException($reason, $systemCode)';
}

class WindowsProxyConfig {
  const WindowsProxyConfig({
    this.proxy = '',
    this.bypass = '',
    this.autoConfigUrl = '',
    this.autoDetect = false,
  });
  final String proxy, bypass, autoConfigUrl;
  final bool autoDetect;

  bool bypasses(Uri uri) {
    final host = uri.host.toLowerCase();
    final formattedHost = host.contains(':') ? '[$host]' : host;
    for (var item in bypass.toLowerCase().split(RegExp(r'[;\s]+'))) {
      if (item.isEmpty) continue;
      if (item == '<local>') {
        if (!host.contains('.') && !host.contains(':')) return true;
        continue;
      }
      if (item.contains('://')) {
        final parts = item.split('://');
        if (parts.length != 2 || parts.first != uri.scheme) continue;
        item = parts.last;
      }
      final pattern = RegExp(
        '^${item.split('*').map(RegExp.escape).join('.*')}\$',
      );
      if (pattern.hasMatch(host) ||
          pattern.hasMatch(formattedHost) ||
          pattern.hasMatch('$formattedHost:${uri.port}')) {
        return true;
      }
    }
    return false;
  }

  String routeFor(Uri uri) {
    if (proxy.trim().isEmpty || bypasses(uri)) return 'DIRECT';
    var selected = proxy.trim();
    if (RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*=').hasMatch(selected)) {
      final protocols = <String, String>{};
      for (final entry in selected.split(RegExp(r'[;\s]+'))) {
        final index = entry.indexOf('=');
        if (index > 0) {
          final scheme = entry.substring(0, index).toLowerCase();
          if (!{'http', 'https', 'ftp', 'socks'}.contains(scheme)) {
            throw const WindowsProxyException('unsupported');
          }
          protocols[scheme] = entry.substring(index + 1);
        }
      }
      selected = protocols[uri.scheme] ?? '';
      if (selected.isEmpty) {
        if (protocols.containsKey('socks')) {
          throw const WindowsProxyException('unsupported');
        }
        return 'DIRECT';
      }
    }
    final routes = <String>[];
    for (var item in selected.split(';')) {
      item = item.trim();
      if (item.isEmpty) continue;
      if (item.toUpperCase() == 'DIRECT') {
        routes.add('DIRECT');
        continue;
      }
      item = item.replaceFirst(RegExp(r'^PROXY\s+', caseSensitive: false), '');
      final address = Uri.tryParse(
        item.contains('://') ? item : 'http://$item',
      );
      if (address == null ||
          address.scheme != 'http' ||
          address.host.isEmpty ||
          address.userInfo.isNotEmpty ||
          address.hasQuery ||
          address.hasFragment ||
          address.path.isNotEmpty && address.path != '/' ||
          RegExp(r'[\x00-\x20\x7f]').hasMatch(item) ||
          address.port < 1 ||
          address.port > 65535) {
        throw const WindowsProxyException('unsupported');
      }
      final host = address.host.contains(':')
          ? '[${address.host}]'
          : address.host;
      routes.add('PROXY $host:${address.port}');
    }
    if (routes.isEmpty) throw const WindowsProxyException('invalid');
    // A configured proxy is never given an implicit DIRECT fallback.
    return routes.join('; ');
  }
}

class WindowsProxyRoute {
  const WindowsProxyRoute(this.value, this.source);
  final String value, source;
  bool get usesProxy => value != 'DIRECT';
}

/// Reads the current user's Internet Settings (the same settings used by
/// Clash/v2rayN and WebView2). Native calls run away from the UI isolate.
class WindowsSystemProxy {
  WindowsSystemProxy({
    Future<WindowsProxyConfig> Function()? readConfig,
    Future<WindowsProxyConfig> Function(Uri, WindowsProxyConfig)? resolveAuto,
    DateTime Function()? clock,
  }) : _readConfig = readConfig ?? _readCurrentUser,
       _resolveAuto = resolveAuto ?? _evaluateAuto,
       _clock = clock ?? DateTime.now;

  final Future<WindowsProxyConfig> Function() _readConfig;
  final Future<WindowsProxyConfig> Function(Uri, WindowsProxyConfig)
  _resolveAuto;
  final DateTime Function() _clock;
  Future<WindowsProxyConfig>? _reading;
  final _auto =
      <
        (String, String, String, bool, String),
        (DateTime, Future<WindowsProxyRoute>)
      >{};

  static Future<WindowsProxyConfig> _readCurrentUser() => Platform.isWindows
      ? Isolate.run(_WinHttp.readConfig)
      : Future.value(const WindowsProxyConfig());

  static Future<WindowsProxyConfig> _evaluateAuto(
    Uri uri,
    WindowsProxyConfig config,
  ) {
    final url = uri.toString();
    final pac = config.autoConfigUrl;
    return Isolate.run(() => _WinHttp.evaluateAuto(url, pac));
  }

  Future<WindowsProxyRoute> resolve(Uri uri) async {
    // Only simultaneous reads are shared. Changing the system proxy is visible
    // to the next request, including an already open login dialog.
    final config = await (_reading ??= _readConfig().whenComplete(
      () => _reading = null,
    ));
    final manual = config.routeFor(uri);
    if (config.bypasses(uri)) {
      return const WindowsProxyRoute('DIRECT', 'bypass');
    }
    if (config.autoConfigUrl.isEmpty &&
        (config.proxy.isNotEmpty || !config.autoDetect)) {
      return WindowsProxyRoute(
        manual,
        config.proxy.isEmpty ? 'direct' : 'manual',
      );
    }
    final key = (
      config.autoConfigUrl,
      config.proxy,
      config.bypass,
      config.autoDetect,
      uri.toString(),
    );
    final now = _clock();
    _auto.removeWhere((_, value) => !now.isBefore(value.$1));
    if (_auto[key] case final cached?) return cached.$2;
    while (_auto.length >= 32) {
      _auto.remove(_auto.keys.first);
    }
    final result = _resolveAutoRoute(uri, config, manual);
    _auto[key] = (now.add(const Duration(seconds: 60)), result);
    return result;
  }

  Future<WindowsProxyRoute> _resolveAutoRoute(
    Uri uri,
    WindowsProxyConfig config,
    String manual,
  ) async {
    try {
      final resolved = await _resolveAuto(uri, config).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw const WindowsProxyException('pac_timeout'),
      );
      return WindowsProxyRoute(resolved.routeFor(uri), 'pac');
    } on WindowsProxyException {
      // Windows falls back to explicitly configured manual settings when PAC
      // discovery fails. With only automatic discovery, no WPAD means DIRECT.
      if (config.proxy.isNotEmpty) return WindowsProxyRoute(manual, 'manual');
      if (config.autoConfigUrl.isNotEmpty) rethrow;
      return const WindowsProxyRoute('DIRECT', 'direct');
    }
  }
}

final class _IEProxyConfig extends Struct {
  @Int32()
  external int autoDetect;
  external Pointer<Utf16> autoConfigUrl;
  external Pointer<Utf16> proxy;
  external Pointer<Utf16> bypass;
}

final class _AutoProxyOptions extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int autoDetectFlags;
  external Pointer<Utf16> autoConfigUrl;
  external Pointer<Void> reserved;
  @Uint32()
  external int reservedFlags;
  @Int32()
  external int autoLogon;
}

final class _ProxyInfo extends Struct {
  @Uint32()
  external int accessType;
  external Pointer<Utf16> proxy;
  external Pointer<Utf16> bypass;
}

class _WinHttp {
  static final _http = DynamicLibrary.open('winhttp.dll');
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _getConfig = _http
      .lookupFunction<
        Int32 Function(Pointer<_IEProxyConfig>),
        int Function(Pointer<_IEProxyConfig>)
      >('WinHttpGetIEProxyConfigForCurrentUser');
  static final _open = _http
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
        )
      >('WinHttpOpen');
  static final _timeouts = _http
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int32),
        int Function(Pointer<Void>, int, int, int, int)
      >('WinHttpSetTimeouts');
  static final _getProxy = _http
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<_AutoProxyOptions>,
          Pointer<_ProxyInfo>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<_AutoProxyOptions>,
          Pointer<_ProxyInfo>,
        )
      >('WinHttpGetProxyForUrl');
  static final _close = _http
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('WinHttpCloseHandle');
  static final _free = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('GlobalFree');
  static final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  static String _text(Pointer<Utf16> value) =>
      value == nullptr ? '' : value.toDartString();
  static void _release(Pointer<Utf16> value) {
    if (value != nullptr) _free(value.cast());
  }

  static WindowsProxyConfig readConfig() {
    final buffer = calloc<_IEProxyConfig>();
    try {
      if (_getConfig(buffer) == 0) {
        final error = _lastError();
        if (error == 2) return const WindowsProxyConfig();
        throw WindowsProxyException('settings', error);
      }
      return WindowsProxyConfig(
        proxy: _text(buffer.ref.proxy),
        bypass: _text(buffer.ref.bypass),
        autoConfigUrl: _text(buffer.ref.autoConfigUrl),
        autoDetect: buffer.ref.autoDetect != 0,
      );
    } finally {
      _release(buffer.ref.autoConfigUrl);
      _release(buffer.ref.proxy);
      _release(buffer.ref.bypass);
      calloc.free(buffer);
    }
  }

  static WindowsProxyConfig evaluateAuto(String url, String pac) {
    final agent = 'AsterLink'.toNativeUtf16();
    final address = url.toNativeUtf16();
    final pacUrl = pac.toNativeUtf16();
    final options = calloc<_AutoProxyOptions>();
    final result = calloc<_ProxyInfo>();
    Pointer<Void> handle = nullptr;
    try {
      handle = _open(agent, 1, nullptr, nullptr, 0);
      if (handle == nullptr) {
        throw WindowsProxyException('session', _lastError());
      }
      if (_timeouts(handle, 2000, 3000, 3000, 5000) == 0) {
        throw WindowsProxyException('timeouts', _lastError());
      }
      options.ref
        // Our bounded cache is per URL and settings. Do not reuse WinHTTP's
        // service cache after switching PAC settings or changing the URL.
        ..flags = (pac.isEmpty ? 1 : 2) | 0x00080000 | 0x00100000
        ..autoDetectFlags = pac.isEmpty ? 3 : 0
        ..autoConfigUrl = pac.isEmpty ? nullptr : pacUrl;
      if (_getProxy(handle, address, options, result) == 0) {
        throw WindowsProxyException('pac', _lastError());
      }
      return result.ref.accessType == 1
          ? const WindowsProxyConfig()
          : WindowsProxyConfig(
              proxy: _text(result.ref.proxy),
              bypass: _text(result.ref.bypass),
            );
    } finally {
      if (handle != nullptr) _close(handle);
      _release(result.ref.proxy);
      _release(result.ref.bypass);
      calloc.free(result);
      calloc.free(options);
      malloc.free(pacUrl);
      malloc.free(address);
      malloc.free(agent);
    }
  }
}
