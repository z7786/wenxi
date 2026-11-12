import 'dart:async';
import '../core/json.dart';
import '../domain/models.dart';
import '../diagnostics/app_log.dart';
import 'desktop_browser_ua.dart';
import 'http.dart';
import 'state_store.dart';

/// Replaces ordinary browser identities only. Provider client identities and
/// parser-supplied download headers are deliberately outside this policy.
class CloudBrowserUa {
  CloudBrowserUa(this.store, {DesktopBrowserUaPool? pool})
    : pool = pool ?? DesktopBrowserUaPool();

  final CredentialStore store;
  final DesktopBrowserUaPool pool;
  final _zoneKey = Object();
  final _identities = <(CloudPlatform, String), String>{};
  static const credentialField = 'browserUserAgent';
  static const sessionField = 'browserUserAgent';

  static bool supports(CloudPlatform platform) => !{
    CloudPlatform.baidu,
    CloudPlatform.quark,
    CloudPlatform.github,
    // These connectors already manage their own per-parse identities.
    CloudPlatform.feijipan,
  }.contains(platform);

  static bool ordinary(String value) => RegExp(
    r'^Mozilla/5\.0 \(Windows NT 10\.0; Win64; x64\) '
    r'AppleWebKit/537\.36 \(KHTML, like Gecko\) '
    r'Chrome/(120|124|127|131)\.0\.0\.0 Safari/537\.36$',
  ).hasMatch(value);

  static bool pooled(String value) =>
      DesktopBrowserUa.builtIn.any((identity) => identity.value == value);

  static String secretKey(CloudPlatform platform) =>
      '${platform.name}.browser_user_agent';

  _BrowserScope? get _scope => Zone.current[_zoneKey] as _BrowserScope?;
  String _owner(CloudPlatform platform) => store is Vault
      ? (store as Vault).accountId(platform) ?? ''
      : '${store.credential(platform)?.updatedAt ?? 0}';

  String selected(CloudPlatform platform) {
    final scope = _scope;
    if (scope?.platform == platform && scope?.owner == _owner(platform)) {
      return scope!.userAgent;
    }
    final saved = store.credential(platform)?.field(credentialField) ?? '';
    final secret = store.secret(secretKey(platform)) ?? '';
    if (pooled(saved)) return saved;
    if (pooled(secret)) return secret;
    return _identities.putIfAbsent((
      platform,
      _owner(platform),
    ), () => pool.next().value);
  }

  String? get current => _scope?.userAgent;

  T run<T>(
    CloudPlatform platform,
    T Function() action, {
    String? userAgent,
    bool fresh = false,
    bool locked = false,
  }) {
    if (!supports(platform)) return action();
    if (_scope?.platform == platform &&
        _scope?.owner == _owner(platform) &&
        userAgent == null &&
        !fresh) {
      return action();
    }
    final pinned = pooled(userAgent ?? '');
    final scope = _BrowserScope(
      platform,
      _owner(platform),
      pooled(userAgent ?? '')
          ? userAgent!
          : fresh
          ? pool.next().value
          : selected(platform),
      locked: locked || pinned,
    );
    return runZoned(action, zoneValues: {_zoneKey: scope});
  }

  Credential bindCredential(CloudPlatform platform, Credential credential) =>
      supports(platform)
      ? credential.withFields({
          credentialField: selected(platform),
        }, preserveRevision: true)
      : credential;

  Map<String, String> headers(
    CloudPlatform platform,
    Map<String, String> source,
  ) => {
    for (final entry in source.entries)
      entry.key:
          supports(platform) &&
              entry.key.toLowerCase() == 'user-agent' &&
              ordinary(entry.value)
          ? selected(platform)
          : entry.value,
  };

  Future<void> _remember(CloudPlatform platform, String userAgent) async {
    if (_scope?.locked == true) return;
    final credential = store.credential(platform);
    if (credential == null) return;
    final key = secretKey(platform);
    if (store.secret(key) == userAgent) return;
    await store.putSecretForCredential(platform, credential, key, userAgent);
  }

  static bool browserBlocked(HttpResult response) {
    if (response.status != 403) return false;
    // JSON permission/login failures and empty responses are not evidence of
    // browser filtering. Retry only a recognizable HTML edge-security page.
    final body = response.body
        .substring(0, response.body.length.clamp(0, 32768))
        .trimLeft()
        .toLowerCase();
    return (body.startsWith('<!doctype html') || body.startsWith('<html')) &&
        RegExp(
          r'cloudflare|\besa\b|access denied|request blocked|browser|'
          r'浏览器|请求被拦截|访问被拦截',
        ).hasMatch(body);
  }

  Future<HttpResult> send(
    CloudPlatform platform,
    String method,
    String url,
    Map<String, String> source,
    Future<HttpResult> Function(String, Map<String, String>) request,
  ) async {
    final entry = source.entries
        .where((entry) => entry.key.toLowerCase() == 'user-agent')
        .firstOrNull;
    if (!supports(platform) || entry == null || !ordinary(entry.value)) {
      return request(url, source);
    }
    return run(platform, () async {
      final scope = _scope!;
      for (var attempt = 0; ; attempt++) {
        RequestScope.checkpoint();
        final ua = scope.userAgent;
        final sent = headers(platform, source);
        if (platform == CloudPlatform.c139) {
          final identity = DesktopBrowserUa.builtIn.firstWhere(
            (identity) => identity.value == ua,
          );
          final os = ua.contains('Windows NT')
              ? 'windows 10'
              : ua.contains('Macintosh')
              ? 'mac os'
              : 'linux';
          for (final key in ['X-Deviceinfo', 'x-yun-client-info']) {
            final value = sent[key];
            if (value != null) {
              sent[key] = value
                  .replaceFirst(
                    '|chrome|116.0.0.0|',
                    '|${identity.model}|${identity.version}.0.0.0|',
                  )
                  .replaceFirst('||windows 10||', '||$os||');
            }
          }
        }
        var address = url;
        if (platform == CloudPlatform.ilanzou &&
            Uri.tryParse(url)?.host == 'apis.ilanzou.com') {
          final identity = DesktopBrowserUa.builtIn.firstWhere(
            (identity) => identity.value == ua,
          );
          // Do not re-encode encrypted tokens or signed query values.
          address = address
              .replaceFirstMapped(
                RegExp(r'([?&]devModel=)[^&]*'),
                (match) => '${match[1]}${identity.model}',
              )
              .replaceFirstMapped(
                RegExp(r'([?&]devVersion=)[^&]*'),
                (match) => '${match[1]}${identity.version}',
              );
        }
        final credential = store.credential(platform);
        await _remember(platform, ua);
        RequestScope.checkpoint();
        if (credential != null &&
            !credential.sameAs(store.credential(platform))) {
          throw const AppException('账号已变化，请重新打开文件列表');
        }
        final response = await request(address, sent);
        RequestScope.checkpoint();
        final authenticated =
            store.credential(platform) != null ||
            source.entries.any(
              (entry) =>
                  {
                    'cookie',
                    'authorization',
                  }.contains(entry.key.toLowerCase()) &&
                  entry.value.isNotEmpty,
            );
        if (scope.locked ||
            authenticated ||
            !JsonHttp.isReadRequest(method, url) ||
            !browserBlocked(response) ||
            attempt >= 2 ||
            scope.used.length >= 3) {
          return response;
        }
        scope.userAgent = pool.next(excluding: scope.used).value;
        scope.used.add(scope.userAgent);
        DiagnosticLog.event(
          'cloud.browser_user_agent_retry',
          fields: {
            'platform': platform.key,
            'attempt': attempt + 2,
            'status': response.status,
          },
        );
      }
    });
  }
}

class _BrowserScope {
  _BrowserScope(
    this.platform,
    this.owner,
    this.userAgent, {
    required this.locked,
  }) {
    used.add(userAgent);
  }
  final CloudPlatform platform;
  final String owner;
  String userAgent;
  final bool locked;
  final used = <String>{};
}

class BrowserUaJsonHttp extends JsonHttp {
  BrowserUaJsonHttp(this.delegate, this.identities, this.platform);
  final JsonHttp delegate;
  final CloudBrowserUa identities;
  final CloudPlatform platform;

  Map<String, String> effectiveHeaders(Map<String, String> headers) =>
      identities.headers(platform, headers);
  T run<T>(T Function() action, {String? userAgent, bool locked = false}) =>
      identities.run(platform, action, userAgent: userAgent, locked: locked);

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) => identities.send(
    platform,
    method,
    url,
    headers,
    (address, sent) => delegate.request(
      method,
      address,
      body: body,
      headers: sent,
      followRedirects: followRedirects,
      contentType: contentType,
    ),
  );

  @override
  Future<HttpResult> peek(
    String url,
    Map<String, String> headers, {
    int maxBytes = 8192,
    bool followRedirects = true,
  }) => identities.send(
    platform,
    'GET',
    url,
    headers,
    (address, sent) => delegate.peek(
      address,
      sent,
      maxBytes: maxBytes,
      followRedirects: followRedirects,
    ),
  );
}
