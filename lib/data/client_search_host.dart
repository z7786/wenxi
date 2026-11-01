import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../core/json.dart';
import 'http.dart';
import 'sources/host.dart';
import 'sources/package.dart';

typedef SearchBrowserEnvironment = Future<WebViewEnvironment?> Function();

class ClientSearchSession {
  final cookies = <String, List<io.Cookie>>{};
  final pages = <String, (DateTime, Json)>{};
  final results = <String, (DateTime, List<Json>)>{};
  DateTime? readyUntil;
  String visitor = '';
}

class ClientSearchHost {
  ClientSearchHost(
    this.source, {
    this.fetch,
    this.environment,
    ClientSearchSession? session,
  }) : session = session ?? ClientSearchSession();
  final SourcePackage source;
  final SourceFetch? fetch;
  final SearchBrowserEnvironment? environment;
  final ClientSearchSession session;
  Map<String, List<io.Cookie>> get cookies => session.cookies;
  late final host = SourceHost(source, fetch: _request);
  HeadlessInAppWebView? _browser;
  Map<String, (DateTime, Json)> get _pages => session.pages;
  bool browserTransport = false;
  int failedRequests = 0;
  static const _androidBrowser = MethodChannel(
    'com.asterlink.app/search_browser',
  );
  String? _androidSession;
  WebViewEnvironment? _ownedEnvironment;
  io.Directory? _browserDirectory;

  Future<Json> _request(SourcePackage package, Json raw) async {
    final options = {...raw};
    final uri = package.checkedUrl(options.str('url'));
    final headers = strings(options['headers']);
    final jar = cookies[uri.host] ?? [];
    final applicable = jar.where(
      (c) =>
          (!c.secure || uri.scheme == 'https') &&
          uri.path.startsWith(c.path ?? '/') &&
          (c.expires == null || c.expires!.isAfter(DateTime.now())),
    );
    if (applicable.isNotEmpty) {
      headers['Cookie'] = applicable
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
    }
    options['headers'] = headers;
    final key = jsonEncode(options);
    final cached = _pages[key];
    if (cached != null && DateTime.now().isBefore(cached.$1)) return cached.$2;
    headers.putIfAbsent('Accept', () => '*/*');
    headers.putIfAbsent('Accept-Language', () => 'zh-CN,zh;q=0.9');
    headers.putIfAbsent(
      'User-Agent',
      () =>
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36',
    );
    Json result;
    try {
      result = fetch != null
          ? await fetch!(package, options)
          : browserTransport
          ? await _browserRequest(options)
          : await SourceHost.request(package, options);
      if (result.integer('status') >= 400) failedRequests++;
    } catch (_) {
      failedRequests++;
      rethrow;
    }
    for (final value
        in (asJson(result['headers'])['set-cookie'] as List? ?? [])) {
      try {
        final cookie = io.Cookie.fromSetCookieValue(value.toString());
        final domain =
            cookie.domain?.replaceFirst(RegExp(r'^\.'), '') ?? uri.host;
        if (domain != uri.host && !uri.host.endsWith('.$domain')) continue;
        final target = cookies.putIfAbsent(uri.host, () => []);
        target.removeWhere(
          (c) => c.name == cookie.name && c.path == cookie.path,
        );
        target.add(cookie);
      } catch (_) {}
    }
    if (options.integer('cache_ttl') > 0 && result.integer('status') < 400) {
      while (_pages.length >= 64) {
        _pages.remove(_pages.keys.first);
      }
      _pages[key] = (
        DateTime.now().add(
          Duration(seconds: options.integer('cache_ttl').clamp(0, 3600)),
        ),
        result,
      );
    }
    return result;
  }

  Future<Object?> call(String method, Json args) async {
    if (method == 'request') return host.call(method, args);
    if (method == 'requestBatch') {
      final requests = args.list('requests');
      require(requests.length <= 3, '并行请求过多');
      return Future.wait(
        requests.map((request) async {
          try {
            return {
              'ok': true,
              'response': await host.call('request', request),
            };
          } catch (_) {
            return {'ok': false};
          }
        }),
      );
    }
    if (method == 'browser') {
      if (fetch != null) return null;
      // Android browser searches use a separate process and WebView profile.
      if (io.Platform.isAndroid) {
        browserTransport = true;
        if (_androidSession == null) {
          _androidSession = (await host.call('crypto', {
            'op': 'randomHex',
            'args': [16],
          })).toString();
          final value = await RequestScope.cancellable(
            _androidBrowser.invokeMethod<String>('open', {
              'session': _androidSession,
              'url': args.str('url'),
              'hosts': source.permissions['hosts'],
              'wait_ms': args.integer('wait_ms', 1500),
              'wait_selector': args.str('wait_selector'),
            }),
          );
          require(value != null, '网页搜索环境不可用');
        }
        return null;
      }
      require(io.Platform.isWindows, '此来源需要独立网页搜索环境');
      browserTransport = args.str('transport') == 'curl';
      if (!browserTransport &&
          session.readyUntil?.isAfter(DateTime.now()) == true) {
        return null;
      }
      await _initializeBrowser(args);
      session.readyUntil = DateTime.now().add(
        Duration(seconds: args.integer('ttl', 600).clamp(1, 3600)),
      );
      return null;
    }
    if (method == 'visitor') {
      if (session.visitor.isEmpty) {
        session.visitor = (await host.call('crypto', {
          'op': 'randomHex',
          'args': [16],
        })).toString();
      }
      return session.visitor;
    }
    if ({
      'htmlNodes',
      'plain',
      'unescape',
      'jsString',
      'telegram',
    }.contains(method)) {
      require(utf8.encode(jsonEncode(args)).length <= 1048576, '搜索内容过大');
      final port = ReceivePort();
      Isolate? worker;
      try {
        worker = await Isolate.spawn(_parse, [
          port.sendPort,
          method,
          args,
        ], onError: port.sendPort);
        final packet = await RequestScope.cancellable(
          port.first,
        ).timeout(const Duration(seconds: 5));
        require(packet is Map && packet['ok'] == true, '搜索内容提取失败');
        return packet['value'];
      } finally {
        worker?.kill(priority: Isolate.immediate);
        port.close();
      }
    }
    return host.call(method, args);
  }

  Future<void> _initializeBrowser(Json args) async {
    final uri = source.checkedUrl(args.str('url'));
    if (_browser != null) return;
    final ready = Completer<InAppWebViewController>();
    require(io.Platform.isWindows, '此来源需要独立网页搜索环境');
    _browserDirectory = await io.Directory.systemTemp.createTemp(
      'asterlink-search-browser-',
    );
    final env = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: _browserDirectory!.path,
      ),
    );
    _ownedEnvironment = env;
    final browser = HeadlessInAppWebView(
      webViewEnvironment: env,
      initialUrlRequest: URLRequest(url: WebUri(uri.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        incognito: true,
      ),
      onLoadStop: (controller, _) {
        if (!ready.isCompleted) ready.complete(controller);
      },
    );
    _browser = browser;
    try {
      await browser.run();
      final controller = await RequestScope.cancellable(
        ready.future,
      ).timeout(const Duration(seconds: 10));
      final selector = args.str('wait_selector');
      if (selector.isNotEmpty) {
        for (var i = 0; i < 10; i++) {
          final found = await controller.evaluateJavascript(
            source: 'Boolean(document.querySelector(${jsonEncode(selector)}))',
          );
          if (found == true) break;
          await RequestScope.wait(const Duration(milliseconds: 200));
        }
      }
      await RequestScope.wait(
        Duration(milliseconds: args.integer('wait_ms', 1500).clamp(0, 5000)),
      );
      final values = await CookieManager.instance(
        webViewEnvironment: env,
      ).getCookies(url: WebUri(uri.toString()));
      final names = args['cookie_names'] as List?;
      cookies[uri.host] = [
        for (final value in values)
          if ((names == null && value.name == '__cf_bm') ||
              names?.contains(value.name) == true)
            (io.Cookie(value.name, value.value)
              ..path = value.path ?? '/'
              ..secure = value.isSecure ?? false),
      ];
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    final browser = _browser;
    _browser = null;
    await browser?.dispose();
    if (_androidSession != null) {
      final id = _androidSession;
      _androidSession = null;
      try {
        await _androidBrowser.invokeMethod<String>('close', {'session': id});
      } catch (_) {}
    }
    await _ownedEnvironment?.dispose();
    _ownedEnvironment = null;
    final directory = _browserDirectory;
    _browserDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<Json> _browserRequest(Json options) async {
    if (io.Platform.isAndroid) {
      require(_androidSession != null, '网页搜索环境不可用');
      final value = await RequestScope.cancellable(
        _androidBrowser.invokeMethod<String>('request', {
          'session': _androidSession,
          'options': options,
        }),
      );
      final response = asJson(jsonDecode(value ?? '{}'));
      require(
        response['error'] != true && response['status'] is int,
        '网页搜索请求失败',
      );
      return response;
    }
    final uri = source.checkedUrl(options.str('url'));
    if (_browser == null) {
      await _initializeBrowser({
        'url': '${uri.scheme}://${uri.host}/',
        'wait_ms': 0,
      });
    }
    final controller = _browser?.webViewController;
    require(controller != null, '网页搜索环境不可用');
    final headers = strings(options['headers'])
      ..removeWhere(
        (key, _) => {
          'cookie',
          'user-agent',
          'referer',
          'origin',
          'accept-language',
        }.contains(key.toLowerCase()),
      );
    String? body;
    if (options.containsKey('body')) {
      body = options.str('encoding') == 'form'
          ? Uri(queryParameters: strings(options['body'])).query
          : options.str('encoding') == 'text'
          ? options['body'].toString()
          : jsonEncode(options['body']);
      headers.putIfAbsent(
        'Content-Type',
        () => options.str('encoding') == 'form'
            ? 'application/x-www-form-urlencoded'
            : 'application/json',
      );
    }
    final result = await RequestScope.cancellable(
      controller!.callAsyncJavaScript(
        functionBody: '''
const abort = new AbortController(), timer = setTimeout(() => abort.abort(), timeout * 1000);
try {
  if (new URL(url).origin !== location.origin) throw new Error('origin');
  const response = await fetch(url, {method, headers, body: body || undefined, credentials: 'include', redirect: 'error', signal: abort.signal});
  const reader = response.body.getReader(); const decoder = new TextDecoder(); let size = 0, text = '';
  while (true) { const chunk = await reader.read(); if(chunk.done) break; size += chunk.value.length; if(size > 524288) {reader.cancel(); throw new Error('size');} text += decoder.decode(chunk.value, {stream:true}); }
  text += decoder.decode(); const resultHeaders = {}; response.headers.forEach((value, name) => resultHeaders[name] = [value]);
  return {status: response.status, url: response.url, headers: resultHeaders, text};
} finally { clearTimeout(timer); }
''',
        arguments: {
          'url': uri.toString(),
          'method': options.str('method', 'GET'),
          'headers': headers,
          'body': body,
          'timeout': options.integer('timeout', 8),
        },
      ),
    );
    require(result?.error == null && result?.value is Map, '网页搜索请求失败');
    return asJson(result!.value);
  }
}

void _parse(List<dynamic> input) {
  final port = input[0] as SendPort;
  try {
    final args = asJson(input[2]);
    final text = args.str('text');
    Object? value;
    if (input[1] == 'plain') {
      value =
          html.parse(text).body?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ??
          '';
    } else if (input[1] == 'unescape') {
      value = html.parseFragment('<textarea>$text</textarea>').text;
    } else if (input[1] == 'jsString') {
      value = text.replaceAllMapped(
        RegExp(r'\\(?:u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|\r\n|[\s\S])'),
        (m) {
          final s = m[0]!.substring(1);
          if (s.startsWith('u') || s.startsWith('x')) {
            return String.fromCharCode(int.parse(s.substring(1), radix: 16));
          }
          return {
                'n': '\n',
                'r': '\r',
                't': '\t',
                'b': '\b',
                'f': '\f',
                'v': '\u000b',
                '0': '\u0000',
                '\n': '',
                '\r': '',
                '\r\n': '',
              }[s] ??
              s;
        },
      );
    } else if (input[1] == 'telegram') {
      final doc = html.parse(text);
      final messages = doc.querySelectorAll('.tgme_widget_message');
      require(messages.isNotEmpty, '频道页面内容无效');
      value = [
        for (final message in messages.take(100)) _telegramMessage(message),
      ];
    } else {
      final doc = html.parse(text), selector = args.str('selector');
      final targets = selector.isEmpty
          ? [doc.documentElement!]
          : doc.querySelectorAll(selector).take(100).toList();
      Json node(Element e) => {
        'text': e.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
        ...e.attributes.map((k, v) => MapEntry(k.toString(), v)),
      };
      Json? selected(Element e, String selector) {
        final found = e.querySelector(selector);
        return found == null ? null : node(found);
      }

      value = [
        for (final e in targets)
          {
            '__html': e.outerHtml,
            '__text': e.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
            '__attrs': e.attributes.map((k, v) => MapEntry(k.toString(), v)),
            '__css': {
              for (final entry in args.obj('css').entries)
                entry.key: selected(e, entry.value.toString()),
            },
          },
      ];
    }
    require(utf8.encode(jsonEncode(value)).length <= 1000000, '搜索内容提取过大');
    port.send({'ok': true, 'value': value});
  } catch (_) {
    port.send({'ok': false});
  }
}

Json _telegramMessage(Element message) {
  final content = message.querySelector('.tgme_widget_message_text');
  String walk(Node node) {
    if (node is Text) return node.data;
    if (node is! Element) return '';
    if (node.localName == 'a') {
      final url = node.attributes['href'] ?? '';
      return '${node.text == url ? '' : node.text} $url ';
    }
    if (node.localName == 'br') return '\n';
    final children = node.nodes.map(walk).join();
    return {'div', 'p', 'blockquote'}.contains(node.localName)
        ? '\n$children\n'
        : children;
  }

  final lines = content == null ? '' : walk(content);
  final buttons = message
      .querySelectorAll('.tgme_widget_message_inline_button[href]')
      .map((a) => a.attributes['href'])
      .whereType<String>()
      .join('\n');
  final photo =
      message
          .querySelector('.tgme_widget_message_photo_wrap')
          ?.attributes['style'] ??
      '';
  return {
    'text': '$lines\n$buttons',
    'datetime': message.querySelector('time')?.attributes['datetime'] ?? '',
    'cover_url':
        RegExp(
          r'''url\(['"]?(https?://[^)'"\s]+)''',
        ).firstMatch(photo)?.group(1) ??
        '',
  };
}
