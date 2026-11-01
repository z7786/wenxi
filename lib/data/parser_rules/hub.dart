import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../core/login_crypto.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/models.dart';
import '../../domain/remote_control.dart' show parserHubUri;
import '../../domain/backend_endpoints.dart';
import '../http.dart';
import '../state_store.dart';
import 'engine.dart';
import 'http.dart';
import 'password_web_flow.dart';
import 'rule.dart';
import 'server.dart';

class ParserPasswordRequired extends AppException {
  const ParserPasswordRequired(this.siteId, [super.message = '当前通道需要补充解析密码']);
  final String siteId;
}

class ParserSharedPassword {
  const ParserSharedPassword(this.value, this.version, this.expiresAt);
  final String value;
  final int version;
  final DateTime expiresAt;
}

class ParserPasswordPrompt {
  const ParserPasswordPrompt({
    this.title = '',
    this.message = defaultMessage,
    this.buttonText = defaultButtonText,
    this.buttonEnabled = true,
    this.format = 'text',
    this.autoFill = true,
    this.webFlow,
  });
  static const defaultMessage = '当前没有可用的解析密码，请获取当前密码后填写。验证通过后，其他用户也能直接使用。';
  static const defaultButtonText = '获取密码';
  final String title, message, buttonText, format;
  final bool buttonEnabled, autoFill;
  final ParserPasswordWebFlow? webFlow;

  factory ParserPasswordPrompt.fromJson(Object? raw) {
    if (raw == null) return const ParserPasswordPrompt();
    if (raw is! Map<String, dynamic>) throw const FormatException();
    String text(String key, int limit, String fallback) {
      if (!raw.containsKey(key)) return fallback;
      final value = raw[key];
      if (value is! String ||
          value.runes.length > limit ||
          RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException();
      }
      return value.trim().isEmpty ? fallback : value.trim();
    }

    if (raw.containsKey('buttonEnabled') && raw['buttonEnabled'] is! bool) {
      throw const FormatException();
    }
    if (raw.containsKey('autoFill') && raw['autoFill'] is! bool ||
        raw.containsKey('format') &&
            !{'text', 'markdown'}.contains(raw['format'])) {
      throw const FormatException();
    }
    return ParserPasswordPrompt(
      title: text('title', 120, ''),
      message: text('message', 4000, defaultMessage),
      buttonText: text('buttonText', 32, defaultButtonText),
      buttonEnabled: raw['buttonEnabled'] as bool? ?? true,
      format: raw['format'] as String? ?? 'text',
      autoFill: raw['autoFill'] as bool? ?? true,
      webFlow: raw['webFlow'] == null
          ? null
          : ParserPasswordWebFlow.fromJson(raw['webFlow']),
    );
  }
}

class ParserSite {
  ParserSite({
    required this.bundleId,
    required this.version,
    required this.rule,
    this.guide = '',
    this.obtainUrl = '',
    this.guideImages = const [],
    this.passwordPrompt = const ParserPasswordPrompt(),
  });
  final String bundleId, guide, obtainUrl;
  final List<String> guideImages;
  final int version;
  final ParserRule rule;
  final ParserPasswordPrompt passwordPrompt;
  String get id => rule.siteId;
  String get name => rule.name;
}

class ParserBundle {
  ParserBundle._(
    this.id,
    this.revision,
    this.sites,
    this.envelope,
    this.publicParsing,
  );
  final String id;
  final int revision;
  final List<ParserSite> sites;
  final Json envelope;
  final Map<CloudPlatform, bool> publicParsing;

  static const backupKind = 'wenxi-parser-rules-backup';
  static const clientRevision = 2;

  static List<int> _verifiedPayload(
    Json envelope,
    String pinnedPublicKey, {
    int maxPayloadLength = 720000,
  }) {
    if (envelope['algorithm'] != 'RSA-SHA256' ||
        envelope.str('payload').length > maxPayloadLength ||
        envelope.str('signature').length > 1024 ||
        pinnedPublicKey.length > 12000) {
      throw const FormatException();
    }
    final pem = utf8.decode(base64Decode(pinnedPublicKey));
    final id = hashes.sha256
        .convert(utf8.encode(pem))
        .toString()
        .substring(0, 16);
    if (envelope['keyId'] != id) throw const FormatException();
    final key = LoginRsa(pem).key;
    if (key.modulus!.bitLength < 2048) throw const FormatException();
    final payload = base64Decode(envelope.str('payload'));
    final signature = base64Decode(envelope.str('signature'));
    final signer = Signer('SHA-256/RSA')
      ..init(false, PublicKeyParameter<RSAPublicKey>(key));
    if (!signer.verifySignature(payload, RSASignature(signature))) {
      throw const FormatException();
    }
    return payload;
  }

  static ParserBundle verifyBackup(
    Json document,
    String pinnedPublicKey, {
    required DateTime now,
  }) {
    try {
      for (var revision = clientRevision; revision >= 2; revision--) {
        if (document.obj('clients')['$revision'] != null) {
          document = document.obj('clients').obj('$revision');
          break;
        }
      }
      for (var engine = ParserRule.engine; engine >= 3; engine--) {
        if (document.obj('engines')['$engine'] != null) {
          document = document.obj('engines').obj('$engine');
          break;
        }
      }
      if (document['schema'] != 1 || document['kind'] != backupKind) {
        throw const FormatException();
      }
      final proof = asJson(
        jsonDecode(
          utf8.decode(
            _verifiedPayload(
              document.obj('attestation'),
              pinnedPublicKey,
              maxPayloadLength: 4096,
            ),
          ),
        ),
      );
      if (proof['schema'] != 1 ||
          proof['purpose'] != backupKind ||
          proof['issuedAt'] is! int ||
          proof['expiresAt'] is! int) {
        throw const FormatException();
      }
      final issued = proof.integer('issuedAt'),
          expiry = proof.integer('expiresAt');
      final seconds = now.millisecondsSinceEpoch ~/ 1000;
      if (issued < 1 ||
          expiry <= issued ||
          expiry - issued > 365 * 86400 ||
          issued > seconds + 300 ||
          expiry < seconds) {
        throw const FormatException();
      }
      // The signed export attests this exact archived bundle. Keep its original
      // identity so primary recovery never looks like a same-revision rewrite.
      final bundle = verify(
        document.obj('bundle'),
        pinnedPublicKey,
        now: now,
        archived: true,
      );
      if (proof['bundleId'] != bundle.id) throw const FormatException();
      return bundle;
    } catch (_) {
      throw const ParserRuleError(
        'RULE_BACKUP_SIGNATURE',
        '备用规则校验失败，继续使用上次可用规则',
      );
    }
  }

  static ParserBundle verify(
    Json envelope,
    String pinnedPublicKey, {
    required DateTime now,
    bool archived = false,
  }) {
    try {
      final payload = _verifiedPayload(envelope, pinnedPublicKey);
      final raw = asJson(jsonDecode(utf8.decode(payload)));
      if (raw['schema'] != 1 ||
          !{1, 2, 3, 4}.contains(raw['engine']) ||
          raw.containsKey('clientRevision') &&
              (raw['clientRevision'] is! int ||
                  raw.integer('clientRevision') < 1 ||
                  raw.integer('clientRevision') > clientRevision) ||
          raw['revision'] is! int ||
          raw.integer('revision') < 1 ||
          raw['issuedAt'] is! int ||
          raw['expiresAt'] is! int ||
          raw['rules'] is! List ||
          (raw['rules'] as List).length > 100) {
        throw const FormatException();
      }
      final issued = raw.integer('issuedAt'), expiry = raw.integer('expiresAt');
      final seconds = now.millisecondsSinceEpoch ~/ 1000;
      if (expiry <= issued ||
          expiry - issued > 7 * 86400 ||
          !archived && (issued > seconds + 300 || expiry < seconds)) {
        throw const FormatException();
      }
      final bundleId = hashes.sha256.convert(payload).toString();
      final publicParsing = raw['publicParsing'];
      if (publicParsing != null &&
          (publicParsing is! Map<String, dynamic> ||
              publicParsing.length > 32 ||
              publicParsing.values.any((value) => value is! bool))) {
        throw const FormatException();
      }
      final flags = asJson(publicParsing);
      final sites = <ParserSite>[], seen = <String>{};
      for (final entry in raw.list('rules')) {
        final rule = ParserRule.fromJson(entry.obj('rule'));
        final hash = hashes.sha256
            .convert(utf8.encode(jsonEncode(rule.json)))
            .toString();
        if (entry.str('siteId') != rule.siteId ||
            rule.json.integer('engine') > raw.integer('engine') ||
            !seen.add(rule.siteId) ||
            entry.integer('version') < 1 ||
            entry.str('ruleHash') != hash ||
            entry.str('guide').length > 12000 ||
            entry.str('obtainUrl').length > 2048) {
          throw const FormatException();
        }
        final images = entry['guideImages'];
        if (images is! List ||
            images.length > 6 ||
            images.any((v) => v is! String)) {
          throw const FormatException();
        }
        sites.add(
          ParserSite(
            bundleId: bundleId,
            version: entry.integer('version'),
            rule: rule,
            guide: entry.str('guide'),
            obtainUrl: entry.str('obtainUrl'),
            guideImages: images.cast<String>(),
            passwordPrompt: ParserPasswordPrompt.fromJson(
              entry['passwordPrompt'],
            ),
          ),
        );
      }
      return ParserBundle._(
        bundleId,
        raw.integer('revision'),
        List.unmodifiable(sites),
        envelope,
        Map.unmodifiable({
          for (final platform in CloudPlatform.values)
            if (flags.containsKey(platform.name))
              platform: flags[platform.name] as bool,
        }),
      );
    } catch (_) {
      throw const ParserRuleError('RULE_SIGNATURE', '远程规则校验失败，继续使用上次可用规则');
    }
  }
}

class ParserRuleHub extends ChangeNotifier {
  late final server = ParserServerClient(request: _api, device: device);
  ParserRuleHub({
    required this.store,
    required Directory directory,
    JsonHttp? http,
    JsonHttp? siteHttp,
    this.passwordDocumentHttp,
    String url = buildUrl,
    this.apiKey = buildKey,
    this.publicKey = buildPublicKey,
    this.backupUrl = buildBackupUrl,
    DateTime Function()? clock,
  }) : _url = BackendEndpoints.parserUrl(url),
       http = http ?? ParserRuleHttp(),
       clock = clock ?? DateTime.now,
       root = Directory('${directory.path}/parser-rules') {
    engine = ParserRuleEngine(siteHttp ?? this.http);
    // A relocated service keeps the same signing identity, archived rules and
    // device IDs. Older releases used the URL as part of their cache identity.
    _namespace = _cacheId('identity-v2|$publicKey');
    for (final legacy in {url, buildUrl, BackendEndpoints.legacyParser}) {
      if (legacy.isNotEmpty) {
        _legacyNamespaces.add(_cacheId('$legacy|$publicKey'));
      }
    }
  }
  static const buildUrl = String.fromEnvironment(
    'ASTERLINK_PARSER_HUB_URL',
    defaultValue: BackendEndpoints.parser,
  );
  static const buildKey = String.fromEnvironment('ASTERLINK_PARSER_HUB_KEY');
  static const buildPublicKey = String.fromEnvironment(
    'ASTERLINK_PARSER_HUB_PUBLIC_KEY',
  );
  static const buildBackupUrl = String.fromEnvironment(
    'ASTERLINK_PARSER_RULES_BACKUP_URL',
  );
  final CredentialStore store;
  final Directory root;
  final JsonHttp http;
  final JsonHttp? passwordDocumentHttp;
  final String apiKey, publicKey, backupUrl;
  String _url;
  String get url => _url;
  final DateTime Function() clock;
  late final String _namespace;
  final _legacyNamespaces = <String>{};
  late final ParserRuleEngine engine;
  RequestScope _scope = RequestScope();
  final _pendingWork = <Future<dynamic>>{};
  final _passwordGate = AsyncGate();
  final _grantGate = AsyncGate();
  final _deviceGate = AsyncGate();
  final _bundles = <String, ParserBundle>{};
  final _passwordReads = <String, Future<ParserSharedPassword>>{};
  final _passwordShares = <String, Future<void>>{};
  final _passwordShareRetryAt = <String, DateTime>{};
  final _metadata = <String, Json>{};
  Future<void>? _loading;
  Future<bool>? _refreshing;
  Timer? _timer;
  ParserBundle? _current;
  DateTime? _attempt, _lastForcedRefresh, _lastSuccess;
  String? _lastError;
  int _highestRevision = 0;
  int _endpointVersion = 0;
  bool _closed = false, _started = false, _loaded = false;
  bool get configured {
    if (apiKey.isEmpty || publicKey.isEmpty) return false;
    try {
      parserHubUri(url);
      return true;
    } on FormatException {
      return false;
    }
  }

  static String _cacheId(String value) =>
      hashes.sha256.convert(utf8.encode(value)).toString().substring(0, 24);

  /// A missing field in an older control file must not undo a working address.
  /// Cancel shared reads from the old endpoint; their late replies cannot
  /// replace the new manifest or password. Direct file transfers are untouched.
  bool updateEndpoint(Uri? endpoint) {
    if (_closed || endpoint == null) return false;
    final next = parserHubUri(
      BackendEndpoints.parserUrl(endpoint.toString()),
    ).toString();
    if (next == _url.replaceFirst(RegExp(r'/+$'), '')) return false;
    _url = next;
    _endpointVersion++;
    _scope.cancel();
    _scope = RequestScope();
    _refreshing = null;
    _passwordReads.clear();
    _passwordShares.clear();
    _passwordShareRetryAt.clear();
    _metadata.clear();
    _attempt = null;
    _lastForcedRefresh = null;
    _lastSuccess = null;
    _lastError = null;
    if (_started) {
      start();
      unawaited(refresh());
    }
    notifyListeners();
    return true;
  }

  Future<T> _track<T>(Future<T> work) {
    _pendingWork.add(work);
    unawaited(
      work.then<void>(
        (_) => _pendingWork.remove(work),
        onError: (Object _, StackTrace _) => _pendingWork.remove(work),
      ),
    );
    return work;
  }

  String get _prefix => 'parserHub.$_namespace';
  String? _secret(String suffix) {
    final current = store.secret('$_prefix.$suffix');
    if (current != null) return current;
    for (final namespace in _legacyNamespaces) {
      final legacy = store.secret('parserHub.$namespace.$suffix');
      if (legacy != null) return legacy;
    }
    return null;
  }

  String get selectedId =>
      _secret('selected')?.trim().ifEmpty('mf_dg22') ?? 'mf_dg22';
  String selectedFor(CloudPlatform platform) => platform == CloudPlatform.baidu
      ? selectedId
      : _secret('selected.${platform.key}') ?? '';
  List<ParserSite> sitesFor(CloudPlatform platform) =>
      sites.where((site) => site.rule.platform == platform).toList();
  bool publicParsingAllowed(CloudPlatform platform) =>
      _current?.publicParsing[platform] ?? true;
  void checkPublicParsing(CloudPlatform platform) {
    if (!publicParsingAllowed(platform)) {
      throw ParserRuleError(
        'PUBLIC_PARSING_CLOSED',
        '${platform.shortName}公益解析暂未开放，请使用常规解析',
      );
    }
  }

  Future<void> ensurePublicParsing(CloudPlatform platform) async {
    if (configured) await _load();
    checkPublicParsing(platform);
  }

  bool publicPreferred(CloudPlatform platform) =>
      _secret('public.${platform.key}') == 'true';
  Future<void> preferPublic(CloudPlatform platform, bool value) async {
    await store.putSecret('$_prefix.public.${platform.key}', '$value');
    if (!_closed) notifyListeners();
  }

  List<ParserSite> get sites =>
      _current?.sites
          .where((site) => publicParsingAllowed(site.rule.platform))
          .toList() ??
      const [];
  bool get hasManifest => _current != null;
  String? get lastError => _lastError;

  ParserSite? currentSite(String id) =>
      sites.where((site) => site.id == id).firstOrNull;

  // Approval belongs to one share. A new parse never reads these receipts
  // without the opaque token returned by its password dialog.
  Future<String> grantPassword(String id) => _grantGate.run(() async {
    final password = _cachedPassword(id);
    require(password != null, '请先验证当前解析密码');
    final now = clock().toUtc();
    final beijing = now.add(const Duration(hours: 8));
    final until = DateTime.utc(
      beijing.year,
      beijing.month,
      beijing.day + 1,
    ).subtract(const Duration(hours: 8));
    return _savePasswordGrant(id, password!, until);
  });

  /// Keeps the final password usable locally while the configured sharing
  /// service independently verifies it. Actual parsing stays on this device.
  Future<String> grantLocalPassword(
    String id,
    String value, {
    required String flowFingerprint,
  }) => _grantGate.run(() async {
    require(!_closed, '解析服务已关闭');
    final flow = currentSite(id)?.passwordPrompt.webFlow;
    require(
      flow != null && flow.fingerprint == flowFingerprint,
      '取密规则已更新，请重新获取密码',
    );
    require(ParserPasswordWebResult.validPassword(value), '请填写完整的当前解析密码');
    final now = clock().toUtc();
    final beijing = now.add(const Duration(hours: 8));
    final midnight = DateTime.utc(
      beijing.year,
      beijing.month,
      beijing.day + 1,
    ).subtract(const Duration(hours: 8));
    final expires = now.add(flow!.cacheDuration);
    final until = expires.isBefore(midnight) ? expires : midnight;
    return _savePasswordGrant(
      id,
      ParserSharedPassword(value, -1, until),
      until,
      flowFingerprint: flowFingerprint,
    );
  });

  Future<String> _savePasswordGrant(
    String id,
    ParserSharedPassword password,
    DateTime until, {
    String? flowFingerprint,
  }) async {
    final now = clock().toUtc();
    final grants = _passwordGrants();
    grants.removeWhere(
      (_, value) =>
          asJson(value).integer('until') <= now.millisecondsSinceEpoch,
    );
    while (grants.length >= 128) {
      grants.remove(grants.keys.first);
    }
    final token = _nonce(24);
    grants[token] = {
      'siteId': id,
      'value': password.value,
      'version': password.version,
      'until': until.millisecondsSinceEpoch,
      'webFlow': ?flowFingerprint,
    };
    await store.putSecret('$_prefix.passwordGrants', jsonEncode(grants));
    return token;
  }

  Json _passwordGrants() {
    try {
      return asJson(jsonDecode(_secret('passwordGrants') ?? '{}'));
    } catch (_) {
      return {};
    }
  }

  ParserSharedPassword? grantedPassword(String id, String? token) {
    if (token == null || !RegExp(r'^[a-f0-9]{48}$').hasMatch(token)) {
      return null;
    }
    final data = asJson(_passwordGrants()[token]);
    if (data.str('siteId') != id ||
        data.str('value').isEmpty ||
        data.integer('until') <= clock().millisecondsSinceEpoch) {
      return null;
    }
    if (data.containsKey('webFlow') &&
        (data.integer('version') != -1 ||
            currentSite(id)?.passwordPrompt.webFlow?.fingerprint !=
                data.str('webFlow'))) {
      return null;
    }
    final password = ParserSharedPassword(
      data.str('value'),
      data.integer('version'),
      DateTime.fromMillisecondsSinceEpoch(data.integer('until')),
    );
    return _isRejected(id, password) ? null : password;
  }

  Future<void> revokePasswordGrant(String? token) => _grantGate.run(() async {
    if (token == null || token.isEmpty) return;
    final grants = _passwordGrants();
    if (grants.remove(token) != null) {
      await store.putSecret('$_prefix.passwordGrants', jsonEncode(grants));
    }
  });

  /// Submits a final password captured from the signed page or confirmed by a
  /// parser request. The server independently verifies it before publishing;
  /// UC access passwords never enter this path. Local parsing does not wait.
  Future<void> shareGrantedPassword(String id, String? token) {
    final approved = grantedPassword(id, token);
    final flow = currentSite(id)?.passwordPrompt.webFlow;
    if (_closed ||
        !configured ||
        approved == null ||
        approved.version != -1 ||
        flow?.sharePassword != true) {
      return Future.value();
    }
    final key = '$id|${flow!.fingerprint}|${_passwordHash(approved.value)}';
    final existing = _passwordShares[key];
    if (existing != null) return existing;
    final now = clock().toUtc();
    _passwordShareRetryAt.removeWhere((_, until) => !until.isAfter(now));
    if (_passwordShareRetryAt.containsKey(key)) return Future.value();
    final endpoint = _endpointVersion;
    final work = _scope
        .run(() async {
          var status = 'unavailable';
          try {
            // Always get a fresh version, including after another client published.
            await passwordMetadata(id);
            RequestScope.checkpoint();
            if (currentSite(id)?.passwordPrompt.webFlow?.fingerprint !=
                    flow.fingerprint ||
                grantedPassword(id, token)?.value != approved.value) {
              return;
            }
            final result = await submitPassword(id, approved.value);
            status = result.str('status');
            if (!{
              'accepted',
              'rejected',
              'pending',
              'verifying',
              'superseded',
            }.contains(status)) {
              status = 'unavailable';
            }
          } catch (_) {
            // The user can continue with the already working local password.
          }
          if (_closed || endpoint != _endpointVersion) return;
          while (_passwordShareRetryAt.length >= 64) {
            _passwordShareRetryAt.remove(_passwordShareRetryAt.keys.first);
          }
          _passwordShareRetryAt[key] =
              status == 'accepted' || status == 'pending'
              ? approved.expiresAt
              : clock().toUtc().add(const Duration(minutes: 1));
          DiagnosticLog.event(
            'parser.password_share',
            fields: {'siteId': id, 'stage': status},
          );
        }, inheritGuard: false)
        .whenComplete(() {
          if (endpoint == _endpointVersion) _passwordShares.remove(key);
        });
    _passwordShares[key] = _track(work);
    return work;
  }

  // The manual dialog needs a submission version, not an automatically filled
  // password. This read must not populate the password cache or grant access.
  Future<void> passwordMetadata(String id) async {
    final response = await _api('/v1/sites');
    final data = response
        .list('sites')
        .where((site) => site.str('id') == id)
        .firstOrNull;
    if (data == null) {
      throw const ParserRuleError('RULE_UNAVAILABLE', '解析通道已停用或暂不可用，请切换通道');
    }
    _metadata[id] = data;
  }

  void start() {
    if (_closed) return;
    _started = true;
    if (!configured || _closed || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> select(String id) async {
    final site = currentSite(id);
    require(site != null, '解析通道尚未发布或已停用');
    final suffix = site!.rule.platform == CloudPlatform.baidu
        ? ''
        : '.${site.rule.platform.key}';
    await store.putSecret('$_prefix.selected$suffix', id);
    if (!_closed) notifyListeners();
  }

  String _path(String id, {String? namespace}) {
    require(RegExp(r'^[a-f0-9]{64}$').hasMatch(id), '解析规则缓存编号无效');
    return '${root.path}/${namespace ?? _namespace}/$id.json';
  }

  Future<void> _load() {
    if (_loaded) return Future.value();
    return _loading ??= _restoreCache()
        .then<void>((_) {
          _loaded = true;
        })
        .whenComplete(() => _loading = null);
  }

  Future<void> _restoreCache() async {
    if (publicKey.isEmpty) return;
    final namespaces = <String>{_namespace, ..._legacyNamespaces};
    // The old URL need not be embedded in the next installation. Discover old
    // cache directories, but trust their state only after verifying the bundle
    // with this service's public key. No files are moved or removed on upgrade.
    try {
      if (await root.exists()) {
        await for (final entry in root.list(followLinks: false)) {
          if (namespaces.length >= 64) break;
          final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (entry is Directory && RegExp(r'^[a-f0-9]{24}$').hasMatch(name)) {
            namespaces.add(name);
          }
        }
      }
    } on FileSystemException {
      // A known cache remains usable even if its parent cannot be enumerated.
    }
    var invalidCache = false;
    for (final namespace in namespaces) {
      if (_closed) return;
      final raw = store.secret('parserHub.$namespace.current');
      if (raw == null || raw.isEmpty) continue;
      try {
        final index = asJson(jsonDecode(raw));
        final bundle = await _readArchiveFile(index.str('id'), namespace);
        if (bundle.revision != index.integer('revision')) continue;
        if (namespace != _namespace) _legacyNamespaces.add(namespace);
        if (_current == null || bundle.revision > _highestRevision) {
          _current = bundle;
          _highestRevision = bundle.revision;
        }
      } catch (_) {
        if (namespace == _namespace || _legacyNamespaces.contains(namespace)) {
          invalidCache = true;
        }
      }
    }
    if (_closed) return;
    if (_current != null) {
      _rememberBundle(_current!);
      notifyListeners();
    } else if (invalidCache) {
      _lastError = 'cache_unavailable';
    }
  }

  Future<ParserBundle> _readArchive(
    String id, {
    bool verifyDisk = false,
  }) async {
    final existing = verifyDisk ? null : _bundles[id];
    if (existing != null) return existing;
    for (final namespace in [
      _namespace,
      if (!verifyDisk) ..._legacyNamespaces,
    ]) {
      try {
        final bundle = await _readArchiveFile(id, namespace);
        _rememberBundle(bundle);
        return bundle;
      } catch (_) {
        // A verified legacy archive can still restore an existing download.
      }
    }
    throw const ParserRuleError('RULE_CACHE', '解析规则缓存缺失或校验失败');
  }

  Future<ParserBundle> _readArchiveFile(String id, String namespace) async {
    final file = File(_path(id, namespace: namespace));
    if (await file.length() > 1048576) {
      throw const ParserRuleError('RULE_CACHE', '解析规则缓存过大');
    }
    final envelope = asJson(jsonDecode(await file.readAsString()));
    final bundle = ParserBundle.verify(
      envelope,
      publicKey,
      now: clock(),
      archived: true,
    );
    if (bundle.id != id) {
      throw const ParserRuleError('RULE_CACHE', '解析规则缓存校验失败');
    }
    return bundle;
  }

  void _rememberBundle(ParserBundle bundle) {
    _bundles[bundle.id] = bundle;
    while (_bundles.length > 12) {
      final oldest = _bundles.keys.firstWhere(
        (key) => key != _current?.id && key != bundle.id,
        orElse: () => '',
      );
      if (oldest.isEmpty) break;
      _bundles.remove(oldest);
    }
  }

  Future<void> _persistBundle(ParserBundle bundle) async {
    try {
      await _readArchive(bundle.id, verifyDisk: true);
      return;
    } catch (_) {
      // A freshly verified response can repair a missing or corrupt archive.
    }
    final file = File(_path(bundle.id));
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.${_nonce(8)}.pending');
    try {
      await temporary.writeAsString(jsonEncode(bundle.envelope), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void _checkRevision(ParserBundle bundle) {
    if (bundle.revision < _highestRevision ||
        bundle.revision == _highestRevision &&
            _current != null &&
            bundle.id != _current!.id) {
      throw const ParserRuleError('RULE_ROLLBACK', '远程规则版本异常，沿用当前规则');
    }
  }

  Future<ParserBundle> _fetchBundle() async {
    try {
      final bundle = ParserBundle.verify(
        await _api('/v1/rules'),
        publicKey,
        now: clock(),
      );
      _checkRevision(bundle);
      return bundle;
    } catch (_) {
      RequestScope.checkpoint();
      if (_closed || backupUrl.trim().isEmpty) rethrow;
      final bundle = await _fetchBackup();
      _checkRevision(bundle);
      return bundle;
    }
  }

  Future<ParserBundle> _fetchBackup() async {
    Uri checkedUri(String value) {
      final uri = Uri.tryParse(value);
      if (value.length > 4096 ||
          RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(value) ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        throw const ParserRuleError('RULE_BACKUP_URL', '备用规则地址无效');
      }
      return uri;
    }

    var uri = checkedUri(backupUrl.trim());
    final parts = uri.pathSegments.toList();
    if (uri.host == 'gitee.com' && parts.length >= 5 && parts[2] == 'blob') {
      parts[2] = 'raw';
      uri = uri.replace(pathSegments: parts);
    }
    final originalHost = uri.host;
    final visited = <Uri>{};
    for (var redirects = 0; ; redirects++) {
      RequestScope.checkpoint();
      if (_closed) throw const ParserRuleError('RULE_CLOSED', '解析服务已关闭');
      if (!visited.add(uri)) {
        throw const ParserRuleError('RULE_BACKUP_URL', '备用规则地址循环跳转');
      }
      // Public hosting never receives the hub API key, device ID or account cookies.
      final response = await http.mutationRequest(
        'GET',
        uri.toString(),
        headers: const {
          'Accept': 'application/json, text/plain;q=0.9',
          'Cache-Control': 'no-cache',
          'User-Agent': 'Wenxi-Parser/2',
        },
        followRedirects: false,
      );
      RequestScope.checkpoint();
      if ({301, 302, 303, 307, 308}.contains(response.status)) {
        final location = response.header('location');
        if (redirects >= 3 || location.isEmpty) {
          throw const ParserRuleError('RULE_BACKUP_URL', '备用规则地址跳转异常');
        }
        final next = checkedUri(uri.resolve(location).toString());
        if (next.host != originalHost &&
            !(originalHost == 'gitee.com' &&
                (next.host == 'giteeusercontent.com' ||
                    next.host.endsWith('.giteeusercontent.com')))) {
          throw const ParserRuleError('RULE_BACKUP_URL', '备用规则地址跳转异常');
        }
        uri = next;
        continue;
      }
      if (response.status != 200 ||
          utf8.encode(response.body).length > 1048576) {
        throw const ParserRuleError('RULE_BACKUP_RESPONSE', '备用规则暂不可用');
      }
      Json document;
      try {
        document = asJson(
          jsonDecode(response.body.replaceFirst(RegExp('^\uFEFF'), '')),
        );
      } catch (_) {
        throw const ParserRuleError('RULE_BACKUP_RESPONSE', '备用规则文件格式不正确');
      }
      if (document['kind'] == ParserBundle.backupKind) {
        return ParserBundle.verifyBackup(document, publicKey, now: clock());
      }
      return ParserBundle.verify(
        document['ok'] == true ? document.obj('data') : document,
        publicKey,
        now: clock(),
      );
    }
  }

  Future<bool> refresh({bool force = false}) {
    if (!configured || _closed) return Future.value(false);
    if (_refreshing != null) return _refreshing!;
    if (!force &&
        _attempt != null &&
        !clock().isBefore(_attempt!) &&
        clock().difference(_attempt!) < const Duration(minutes: 15)) {
      return Future.value(false);
    }
    final version = _endpointVersion;
    final work = _scope
        .run(() async {
          await _load();
          if (_closed || version != _endpointVersion) return false;
          _attempt = clock();
          try {
            final bundle = await _fetchBundle();
            if (_closed || version != _endpointVersion) return false;
            await _persistBundle(bundle);
            if (_closed || version != _endpointVersion) return false;
            if (bundle.id == _current?.id) {
              _lastError = null;
              _lastSuccess = clock();
              return false;
            }
            await store.putSecret(
              '$_prefix.current',
              jsonEncode({'id': bundle.id, 'revision': bundle.revision}),
            );
            if (_closed || version != _endpointVersion) return false;
            final changed = bundle.id != _current?.id;
            _current = bundle;
            _bundles[bundle.id] = bundle;
            _highestRevision = bundle.revision;
            _lastError = null;
            _lastSuccess = clock();
            notifyListeners();
            return changed;
          } catch (error) {
            if (_closed || version != _endpointVersion) return false;
            _lastError = error is ParserRuleError ? error.code : 'RULE_NETWORK';
            if (!_closed) notifyListeners();
            return false;
          }
        }, inheritGuard: false)
        .whenComplete(() {
          if (version == _endpointVersion) _refreshing = null;
        });
    return _refreshing = _track(work);
  }

  Future<bool> refreshAfterFailure() {
    if (_lastForcedRefresh != null &&
        !clock().isBefore(_lastForcedRefresh!) &&
        clock().difference(_lastForcedRefresh!) < const Duration(minutes: 1)) {
      return Future.value(false);
    }
    _lastForcedRefresh = clock();
    return refresh(force: true);
  }

  Future<ParserSite?> forNewShare({
    String? siteId,
    CloudPlatform platform = CloudPlatform.baidu,
  }) async {
    if (!configured) return null;
    await _load();
    if (_current == null) await refresh(force: true);
    checkPublicParsing(platform);
    if (_current == null &&
        platform == CloudPlatform.baidu &&
        (siteId == null || siteId == 'mf_dg22')) {
      return null;
    }
    final desired = siteId ?? selectedFor(platform);
    final available = sitesFor(platform);
    final selected = available.where((site) => site.id == desired).firstOrNull;
    if (selected != null) return selected;
    if (siteId == null && available.isNotEmpty) return available.first;
    throw const ParserRuleError(
      'RULE_UNAVAILABLE',
      '该解析通道尚未发布或已停用，请切换通道或使用账号下载',
    );
  }

  Future<ParserSite> snapshot(String bundleId, String siteId) async {
    try {
      await _load();
      final bundle = await _readArchive(bundleId);
      final site = bundle.sites.where((s) => s.id == siteId).firstOrNull;
      if (site == null) throw const FormatException();
      return site;
    } catch (_) {
      throw const ParserRuleError('RULE_CACHE', '此任务的原解析规则缺失，请重新解析分享后下载');
    }
  }

  Future<String> device(String siteId) => _deviceGate.run(() async {
    await _load();
    final key = '$_prefix.device.$siteId';
    final old = _secret('device.$siteId');
    if (old != null && RegExp(r'^wenxi_[a-f0-9]{32}$').hasMatch(old)) {
      return old;
    }
    final value = 'wenxi_${_nonce(16)}';
    await store.putSecret(key, value);
    return value;
  });

  static String _nonce(int size) => CryptoBox.random(
    size,
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<Json> _api(
    String path, {
    Json? body,
    Map<String, String> headers = const {},
  }) async {
    if (!configured || _closed) {
      throw const ParserRuleError('HUB_UNAVAILABLE', '共享密码服务尚未连接');
    }
    require(RegExp(r'^/v1/[a-z0-9_/-]+$').hasMatch(path), '共享接口路径无效');
    final version = _endpointVersion;
    final result = await http.mutationRequest(
      body == null ? 'GET' : 'POST',
      '${url.replaceFirst(RegExp(r'/+$'), '')}$path',
      body: body == null ? null : jsonEncode(body),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'User-Agent': 'Wenxi-Parser/2',
        'X-Parser-Engine': '${ParserRule.engine}',
        'X-Parser-Client-Revision': '${ParserBundle.clientRevision}',
        'Accept': 'application/json',
        ...headers,
      },
      contentType: 'application/json',
      followRedirects: false,
    );
    if (_closed || version != _endpointVersion) {
      throw const ParserRuleError('HUB_CHANGED', '解析服务地址已更新，请重试');
    }
    RequestScope.checkpoint();
    if (utf8.encode(result.body).length > 1048576) {
      throw const ParserRuleError('HUB_RESPONSE', '共享服务响应过大');
    }
    Json response;
    try {
      response = result.json;
    } catch (_) {
      throw const ParserRuleError('HUB_UNAVAILABLE', '共享密码服务暂时无法访问');
    }
    if (!result.successful || response['ok'] != true) {
      final code = response.obj('error').str('code');
      final message = switch (code) {
        'UNAUTHORIZED' => '共享服务接入配置已变化，请联系管理员',
        'SITE_DISABLED' || 'SITE_NOT_FOUND' => '此解析通道已停用，请切换通道',
        'RATE_LIMITED' => '操作较频繁，请稍后重试',
        'PASSWORD_CHANGED' || 'VERSION_CHANGED' => '共享密码已有更新，请重新获取',
        'UPSTREAM_DISABLED' ||
        'interaction_required' ||
        'quota_exhausted' ||
        'share_rejected' ||
        'WORKER_OFFLINE' ||
        'JOB_BUSY' ||
        'JOB_TIMEOUT' ||
        'JOB_CANCELLED' ||
        'JOB_EXPIRED' ||
        'JOB_NOT_FOUND' ||
        'JOB_NOT_READY' ||
        'RULE_CHANGED' ||
        'RULE_FILE_MISMATCH' ||
        'RULE_DOWNLOAD_URL' ||
        'RULE_RESPONSE' ||
        'SESSION_REJECTED' => ParserServerClient.message(code),
        _ => '共享密码服务暂时不可用，请稍后重试',
      };
      throw ParserRuleError(code.isEmpty ? 'HUB_UNAVAILABLE' : code, message);
    }
    return response.obj('data');
  }

  ParserSharedPassword? _cachedPassword(String id) {
    try {
      final data = asJson(jsonDecode(_secret('password.$id') ?? '{}'));
      final value = data.str('value');
      if (value.isEmpty || utf8.encode(value).length > 512) return null;
      final result = ParserSharedPassword(
        value,
        data.integer('version'),
        DateTime.fromMillisecondsSinceEpoch(data.integer('expiresAt')),
      );
      return _isRejected(id, result) ? null : result;
    } catch (_) {
      return null;
    }
  }

  Json _rejection(String id) {
    try {
      return asJson(jsonDecode(_secret('rejected.$id') ?? '{}'));
    } catch (_) {
      return {};
    }
  }

  String _passwordHash(String value) =>
      hashes.sha256.convert(utf8.encode(value)).toString();

  bool _isRejected(String id, ParserSharedPassword password) {
    final marker = _rejection(id);
    return marker.integer('version') == password.version &&
        marker.str('hash') == _passwordHash(password.value);
  }

  Future<ParserSharedPassword> password(String id, {bool force = false}) {
    if (!RegExp(r'^[a-z][a-z0-9_-]{1,63}$').hasMatch(id)) {
      return Future.error(const ParserRuleError('HUB_SITE', '解析通道编号无效'));
    }
    if (_closed) {
      return Future.error(
        const ParserRuleError('HUB_UNAVAILABLE', '共享密码服务已关闭'),
      );
    }
    final existing = _passwordReads[id];
    if (existing != null) return RequestScope.cancellable(existing);
    final version = _endpointVersion;
    final work = _scope
        .run(() async {
          await _load();
          RequestScope.checkpoint();
          final cached = _cachedPassword(id);
          if (!force && cached != null && cached.expiresAt.isAfter(clock())) {
            return cached;
          }
          Json data;
          try {
            data = await _api('/v1/sites/$id/password');
          } on ParserRuleError catch (error) {
            if (cached != null &&
                !_isRejected(id, cached) &&
                {'RULE_NETWORK', 'HUB_UNAVAILABLE'}.contains(error.code) &&
                clock().difference(cached.expiresAt) <
                    const Duration(hours: 24)) {
              return cached;
            }
            rethrow;
          }
          RequestScope.checkpoint();
          _metadata[id] = data;
          final value = data['password'];
          if (value is! String ||
              value.isEmpty ||
              utf8.encode(value).length > 512) {
            await _passwordGate.run(() {
              RequestScope.checkpoint();
              return store.putSecret('$_prefix.password.$id', '');
            });
            throw ParserPasswordRequired(id);
          }
          final result = ParserSharedPassword(
            value,
            data.integer('version'),
            clock().add(
              Duration(seconds: data.integer('cacheFor').clamp(0, 300)),
            ),
          );
          await _passwordGate.run(() async {
            RequestScope.checkpoint();
            if (_isRejected(id, result)) throw ParserPasswordRequired(id);
            await store.putSecret(
              '$_prefix.password.$id',
              jsonEncode({
                'value': value,
                'version': result.version,
                'expiresAt': result.expiresAt.millisecondsSinceEpoch,
              }),
            );
          });
          return result;
        }, inheritGuard: false)
        .whenComplete(() {
          if (version == _endpointVersion) _passwordReads.remove(id);
        });
    _passwordReads[id] = _track(work);
    return RequestScope.cancellable(work);
  }

  Future<void> reportRejected(String id, ParserSharedPassword rejected) async {
    await _passwordGate.run(() async {
      final cached = _cachedPassword(id);
      if (_rejection(id).integer('version') <= rejected.version) {
        await store.putSecret(
          '$_prefix.rejected.$id',
          jsonEncode({
            'version': rejected.version,
            'hash': _passwordHash(rejected.value),
          }),
        );
      }
      if (cached?.version == rejected.version &&
          cached?.value == rejected.value) {
        await store.putSecret('$_prefix.password.$id', '');
      }
    });
    try {
      await _api(
        '/v1/sites/$id/report',
        body: {'version': rejected.version, 'reason': 'password_rejected'},
      );
    } catch (_) {
      /* A failed report must not manufacture a global password invalidation. */
    }
  }

  Future<Json> submitPassword(String id, String value) async {
    require(
      value.trim().isNotEmpty &&
          utf8.encode(value).length <= 512 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value),
      '请填写完整的当前解析密码',
    );
    if (!_metadata.containsKey(id)) {
      await passwordMetadata(id);
    }
    final result = await _api(
      '/v1/sites/$id/submissions',
      body: {
        'password': value,
        'baseVersion':
            _metadata[id]?.integer('version') ??
            _cachedPassword(id)?.version ??
            0,
      },
      headers: {'Idempotency-Key': _nonce(16)},
    );
    if (result.str('status') == 'accepted') await password(id, force: true);
    return result;
  }

  Future<Json> submission(String id) => _api('/v1/submissions/$id');
  Json diagnostics() => {
    'configured': configured,
    'revision': _current?.revision,
    'sites': sites.map((s) => {'id': s.id, 'version': s.version}).toList(),
    'lastSuccess': _lastSuccess?.toIso8601String(),
    'lastError': _lastError,
  };

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _scope.cancel();
    final pending = _pendingWork.toList();
    for (final work in pending) {
      try {
        await work;
      } catch (_) {}
    }
    await _passwordGate.run(() async {});
    await _grantGate.run(() async {});
    await _deviceGate.run(() async {});
    dispose();
  }
}
