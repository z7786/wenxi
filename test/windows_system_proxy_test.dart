import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/windows_system_proxy.dart';

void main() {
  final url = Uri.parse('https://user.mypikpak.com/v1/auth/signin');

  test(
    'Windows manual proxies retain HTTPS, IPv6 and explicit fallback rules',
    () {
      final cases = {
        '127.0.0.1:7890': 'PROXY 127.0.0.1:7890',
        'http://127.0.0.1:10809': 'PROXY 127.0.0.1:10809',
        'http=127.0.0.1:10809;https=127.0.0.1:10808': 'PROXY 127.0.0.1:10808',
        'http=127.0.0.1:10809': 'DIRECT',
        '[::1]:7890': 'PROXY [::1]:7890',
        'PROXY proxy.example:80; PROXY backup.example:81; DIRECT':
            'PROXY proxy.example:80; PROXY backup.example:81; DIRECT',
      };
      for (final entry in cases.entries) {
        expect(WindowsProxyConfig(proxy: entry.key).routeFor(url), entry.value);
      }
    },
  );

  test(
    'Bypass rules are anchored and preserve scheme and port restrictions',
    () {
      const config = WindowsProxyConfig(
        proxy: '127.0.0.1:7890',
        bypass:
            '<local>;*.internal.test;localhost;https://special.test:443;127.*',
      );
      for (final address in [
        'https://intranet/',
        'http://localhost/',
        'http://127.0.0.1/',
        'https://a.internal.test/',
        'https://special.test/',
      ]) {
        expect(config.routeFor(Uri.parse(address)), 'DIRECT', reason: address);
      }
      for (final address in [
        url.toString(),
        'https://a.internal.test.other/',
        'http://special.test/',
        'https://special.test:444/',
      ]) {
        expect(
          config.routeFor(Uri.parse(address)),
          'PROXY 127.0.0.1:7890',
          reason: address,
        );
      }
    },
  );

  test(
    'Unsupported proxy settings fail without exposing credentials or bypassing',
    () {
      for (final proxy in [
        'socks=127.0.0.1:10808',
        'unknown=127.0.0.1:10808',
        'SOCKS5 127.0.0.1:10808',
        'https://proxy.example:443',
        'http://private:secret@proxy.example:80',
        'proxy.example:99999',
        'http://proxy.example/a?private=secret',
      ]) {
        expect(
          () => WindowsProxyConfig(proxy: proxy).routeFor(url),
          throwsA(
            isA<WindowsProxyException>().having(
              (error) => error.toString(),
              'safe error',
              isNot(contains('secret')),
            ),
          ),
        );
      }
    },
  );

  test(
    'Manual proxy changes take effect without restarting the login dialog',
    () async {
      var config = const WindowsProxyConfig();
      var reads = 0;
      final resolver = WindowsSystemProxy(
        readConfig: () async {
          reads++;
          return config;
        },
        resolveAuto: (_, _) async => fail('manual proxy must not trigger WPAD'),
      );
      expect((await resolver.resolve(url)).value, 'DIRECT');
      config = const WindowsProxyConfig(
        proxy: '127.0.0.1:7890',
        autoDetect: true,
      );
      expect((await resolver.resolve(url)).value, 'PROXY 127.0.0.1:7890');
      config = const WindowsProxyConfig(proxy: '127.0.0.1:10808');
      expect((await resolver.resolve(url)).value, 'PROXY 127.0.0.1:10808');
      config = const WindowsProxyConfig();
      expect((await resolver.resolve(url)).value, 'DIRECT');
      expect(reads, 4);
    },
  );

  test(
    'PAC is cached per URL and invalidated by configuration changes',
    () async {
      var config = const WindowsProxyConfig(autoConfigUrl: 'http://pac.test/a');
      var now = DateTime(2026, 10, 19), evaluations = 0;
      final resolver = WindowsSystemProxy(
        readConfig: () async => config,
        clock: () => now,
        resolveAuto: (uri, _) async {
          evaluations++;
          return WindowsProxyConfig(
            proxy: uri.path.endsWith('/direct') ? '' : 'proxy.test:80',
          );
        },
      );
      expect((await resolver.resolve(url)).value, 'PROXY proxy.test:80');
      expect((await resolver.resolve(url)).value, 'PROXY proxy.test:80');
      expect(evaluations, 1);
      expect(
        (await resolver.resolve(url.replace(path: '/direct'))).value,
        'DIRECT',
      );
      config = const WindowsProxyConfig(autoConfigUrl: 'http://pac.test/b');
      await resolver.resolve(url);
      expect(evaluations, 3);
      now = now.add(const Duration(seconds: 61));
      await resolver.resolve(url);
      expect(evaluations, 4);
    },
  );

  test(
    'An explicit broken PAC never silently becomes a direct connection',
    () async {
      var config = const WindowsProxyConfig(
        autoConfigUrl: 'http://pac.test/failed',
      );
      final resolver = WindowsSystemProxy(
        readConfig: () async => config,
        resolveAuto: (_, _) async =>
            throw const WindowsProxyException('pac', 12167),
      );
      await expectLater(
        resolver.resolve(url),
        throwsA(isA<WindowsProxyException>()),
      );
      config = const WindowsProxyConfig(
        autoConfigUrl: 'http://pac.test/failed',
        proxy: '127.0.0.1:7890',
      );
      expect((await resolver.resolve(url)).value, 'PROXY 127.0.0.1:7890');
      config = const WindowsProxyConfig(autoDetect: true);
      expect((await resolver.resolve(url)).value, 'DIRECT');
    },
  );

  test(
    'Failed PAC evaluations are evicted so subsequent retries can succeed',
    () async {
      var attempts = 0;
      const config = WindowsProxyConfig(
        autoConfigUrl: 'http://pac.test/flaky',
      );
      final resolver = WindowsSystemProxy(
        readConfig: () async => config,
        resolveAuto: (_, _) async {
          attempts++;
          if (attempts == 1) {
            throw const WindowsProxyException('pac_timeout');
          }
          return const WindowsProxyConfig(proxy: '127.0.0.1:7890');
        },
      );
      await expectLater(
        resolver.resolve(url),
        throwsA(isA<WindowsProxyException>()),
      );
      expect((await resolver.resolve(url)).value, 'PROXY 127.0.0.1:7890');
      expect(attempts, 2);
    },
  );

  test('Short config TTL caches config reads and refreshes after expiry', () async {
    var now = DateTime(2026, 11, 26, 12, 0, 0);
    var reads = 0;
    var config = const WindowsProxyConfig(proxy: '127.0.0.1:7890');
    final resolver = WindowsSystemProxy(
      readConfig: () async {
        reads++;
        return config;
      },
      clock: () => now,
      configCacheTtl: const Duration(seconds: 3),
    );
    expect((await resolver.resolve(url)).value, 'PROXY 127.0.0.1:7890');
    config = const WindowsProxyConfig(proxy: '127.0.0.1:10808');
    now = now.add(const Duration(seconds: 2));
    expect((await resolver.resolve(url)).value, 'PROXY 127.0.0.1:7890');
    expect(reads, 1);
    now = now.add(const Duration(seconds: 2));
    expect((await resolver.resolve(url)).value, 'PROXY 127.0.0.1:10808');
    expect(reads, 2);
  });

  test(
    'WinHTTP evaluates a real local PAC away from the UI thread',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var reads = 0;
      server.listen((request) {
        reads++;
        request.response.headers.contentType = ContentType(
          'application',
          'x-ns-proxy-autoconfig',
        );
        request.response.write('''function FindProxyForURL(url, host) {
        if (host === 'direct.mypikpak.com' || url.indexOf('/direct') >= 0) return 'DIRECT';
        return 'PROXY 127.0.0.1:7890';
      }''');
        request.response.close();
      });
      final resolver = WindowsSystemProxy(
        readConfig: () async => WindowsProxyConfig(
          autoConfigUrl: 'http://127.0.0.1:${server.port}/fixture.pac',
        ),
      );
      expect((await resolver.resolve(url)).value, 'PROXY 127.0.0.1:7890');
      expect(
        (await resolver.resolve(
          url.replace(host: 'direct.mypikpak.com'),
        )).value,
        'DIRECT',
      );
      // Windows deliberately hides HTTPS paths from PAC; HTTP retains them.
      expect(
        (await resolver.resolve(
          url.replace(scheme: 'http', path: '/direct'),
        )).value,
        'DIRECT',
      );
      expect(reads, greaterThan(0));
    },
    skip: !Platform.isWindows,
  );
}
