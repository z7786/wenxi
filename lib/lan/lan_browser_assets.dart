import 'package:flutter/services.dart';

String lanBrowserHtml = '',
    lanBrowserCss = '',
    lanBrowserJs = '',
    lanBrowserSha256Js = '';
Future<void>? _loading;

/// Load on the first browser request. Static assets are bundled for every
/// platform, so the LAN webpage has no Internet dependency.
Future<void> loadLanBrowserAssets() =>
    _loading ??= _load().catchError((Object error) {
      _loading = null;
      throw error;
    });

Future<void> _load() async {
  final values = await Future.wait([
    rootBundle.loadString('assets/lan/index.html'),
    rootBundle.loadString('assets/lan/app.css'),
    rootBundle.loadString('assets/lan/app.js'),
    rootBundle.loadString('assets/lan/sha256.js'),
  ]);
  lanBrowserHtml = values[0];
  lanBrowserCss = values[1];
  lanBrowserJs = values[2];
  lanBrowserSha256Js = values[3];
}
