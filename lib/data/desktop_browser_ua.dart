import 'dart:math';

/// Desktop identities kept separate from embedded login WebViews.
class DesktopBrowserUa {
  const DesktopBrowserUa(this.value, this.model, this.version);
  final String value, model, version;

  static const _windows = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';
  static const _mac = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)';
  static const _linux = 'Mozilla/5.0 (X11; Linux x86_64)';
  static const _webkit = 'AppleWebKit/537.36 (KHTML, like Gecko)';

  static const builtIn = [
    DesktopBrowserUa(
      '$_windows $_webkit Chrome/153.0.0.0 Safari/537.36',
      'chrome',
      '153',
    ),
    DesktopBrowserUa(
      '$_windows $_webkit Chrome/152.0.0.0 Safari/537.36',
      'chrome',
      '152',
    ),
    DesktopBrowserUa(
      '$_mac $_webkit Chrome/153.0.0.0 Safari/537.36',
      'chrome',
      '153',
    ),
    DesktopBrowserUa(
      '$_mac $_webkit Chrome/152.0.0.0 Safari/537.36',
      'chrome',
      '152',
    ),
    DesktopBrowserUa(
      '$_linux $_webkit Chrome/153.0.0.0 Safari/537.36',
      'chrome',
      '153',
    ),
    DesktopBrowserUa(
      '$_linux $_webkit Chrome/152.0.0.0 Safari/537.36',
      'chrome',
      '152',
    ),
    DesktopBrowserUa(
      '$_windows $_webkit Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0',
      'edge',
      '153',
    ),
    DesktopBrowserUa(
      '$_windows $_webkit Chrome/152.0.0.0 Safari/537.36 Edg/152.0.0.0',
      'edge',
      '152',
    ),
    DesktopBrowserUa(
      '$_mac $_webkit Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0',
      'edge',
      '153',
    ),
    DesktopBrowserUa(
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:145.0) Gecko/20100101 Firefox/145.0',
      'firefox',
      '145',
    ),
    DesktopBrowserUa(
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:145.0) Gecko/20100101 Firefox/145.0',
      'firefox',
      '145',
    ),
    DesktopBrowserUa(
      'Mozilla/5.0 (X11; Linux x86_64; rv:145.0) Gecko/20100101 Firefox/145.0',
      'firefox',
      '145',
    ),
  ];
}

/// Draw without replacement, then reshuffle when the pool is exhausted.
class DesktopBrowserUaPool {
  DesktopBrowserUaPool({Random? random}) : _random = random ?? Random();
  final Random _random;
  final _remaining = <DesktopBrowserUa>[];

  DesktopBrowserUa next({Set<String> excluding = const {}}) {
    if (!_remaining.any((ua) => !excluding.contains(ua.value))) {
      _remaining
        ..clear()
        ..addAll(DesktopBrowserUa.builtIn)
        ..shuffle(_random);
    }
    final index = _remaining.lastIndexWhere(
      (ua) => !excluding.contains(ua.value),
    );
    return _remaining.removeAt(index);
  }

  DesktopBrowserUaSession start() => DesktopBrowserUaSession(this);
}

/// The selected identity stays fixed through a successful request chain.
class DesktopBrowserUaSession {
  DesktopBrowserUaSession(this.pool) : current = pool.next() {
    _used.add(current.value);
  }
  final DesktopBrowserUaPool pool;
  DesktopBrowserUa current;
  final _used = <String>{};
  static const maxAttempts = 3;

  bool rotate() {
    if (_used.length >= maxAttempts) return false;
    current = pool.next(excluding: _used);
    _used.add(current.value);
    return true;
  }
}
