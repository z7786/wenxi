import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/c139_passcode.dart';
import 'c139_passcode.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../uploads/upload_io.dart';
import '../../core/operation_progress.dart';

class C139Protocol {
  static const key = 'PVGDwmcvfs1uV3d1';
  static String calculateSign(String body, String timestamp, String random) {
    final chars = Uri.encodeComponent(body).split('')..sort();
    String digest(String text) => md5.convert(utf8.encode(text)).toString();
    return digest(
      '${digest(base64Encode(utf8.encode(chars.join())))}${digest('$timestamp:$random')}',
    ).toUpperCase();
  }

  static String signHeader(String body) {
    final now = DateTime.now();
    String two(int n) => '$n'.padLeft(2, '0');
    final timestamp =
        '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    final random = List.generate(
      16,
      (_) => alphabet[rng.nextInt(alphabet.length)],
    ).join();
    return '$timestamp,$random,${calculateSign(body, timestamp, random)}';
  }

  static String encrypt(String body, {Uint8List? iv}) {
    final nonce = iv ?? CryptoBox.random(16);
    return base64Encode([
      ...nonce,
      ...CryptoBox.aesCbc(true, utf8.encode(body), utf8.encode(key), nonce),
    ]);
  }

  static String decrypt(String value) {
    try {
      final raw = base64Decode(value.trim());
      require(raw.length > 16, '139 加密响应长度无效');
      var decoded = CryptoBox.aesCbc(
        false,
        raw.sublist(16),
        utf8.encode(key),
        raw.sublist(0, 16),
      );
      if (decoded.length >= 2 && decoded[0] == 0x1f && decoded[1] == 0x8b) {
        decoded = Uint8List.fromList(gzip.decode(decoded));
      }
      return utf8.decode(decoded);
    } catch (_) {
      throw const AppException('139 响应无法解密');
    }
  }
}

class C139Quota {
  static double? _number(Object? value) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return number != null &&
            number.isFinite &&
            number >= 0 &&
            number <= (1 << 42)
        ? number
        : null;
  }

  static CloudAccount parse(Json data, String nickname) {
    final values = data['diskInfo'] is Map ? data.obj('diskInfo') : data;
    final totalMb = _number(values['diskSize']);
    require(totalMb != null && totalMb > 0, '移动云盘未返回有效总容量，请重试');
    final freeMb = _number(values['freeDiskSize']);
    var usedMb = _number(values['usedSize']);
    if (freeMb != null && freeMb <= totalMb!) usedMb = totalMb - freeMb;
    if (usedMb == null) {
      final quotas = values['quotaList'];
      if (quotas is List && quotas.isNotEmpty) {
        final usages = quotas
            .map((quota) => quota is Map ? _number(quota['usedSize']) : null)
            .toList();
        if (usages.every((value) => value != null)) {
          usedMb = usages.fold<double>(0, (sum, value) => sum + value!);
        }
      }
    }
    require(usedMb != null, '移动云盘未返回有效已用容量，请重试');
    const mb = 1024 * 1024;
    return CloudAccount(
      nickname,
      used: (usedMb! * mb).round(),
      total: (totalMb! * mb).round(),
    );
  }
}

class C139Connector extends CloudConnector {
  C139Connector(
    this.http, {
    this.taskDelay = const Duration(milliseconds: 800),
    this.stageCleanup,
  });
  final JsonHttp http;
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  final Duration taskDelay;
  @override
  CloudPlatform get platform => CloudPlatform.c139;
  static const shareBase =
      'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp';
  static const cloudBase = 'https://personal-kd-njs.yun.139.com/hcy';
  static const familyBase =
      'https://yun.139.com/orchestration/familyCloud-rebuild';
  static const ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static String authorization(Credential c) {
    final value = c.field('authorization').ifEmpty(c.secondary);
    return value.isEmpty
        ? LoginCredentials.c139Authorization(c.primary)
        : LoginCredentials.c139Cookie('authorization=$value', 'authorization');
  }

  static String requiredAuth(Credential c) {
    final auth = authorization(c);
    if (auth.isEmpty) throw const AccountLoginRequired('移动云盘登录未完成，请重新网页登录');
    return auth;
  }

  static String accountId(String auth) {
    try {
      return utf8
              .decode(
                base64.decode(
                  base64.normalize(auth.replaceFirst('Basic', '').trim()),
                ),
              )
              .split(':')
              .elementAtOrNull(1) ??
          '';
    } catch (_) {
      return '';
    }
  }

  static String cookieValue(String raw, String key) =>
      LoginCredentials.cookiePairs(raw).entries
          .where((e) => e.key.toLowerCase() == key.toLowerCase())
          .firstOrNull
          ?.value ??
      '';
  Json common(String account) => {'account': account, 'accountType': 1};
  Json check(HttpResult response, Json j) {
    RequestScope.checkpoint();
    final code = j.str('resultCode').ifEmpty(j.str('code'));
    if ({401, 403}.contains(response.status) ||
        {
          '401',
          '403',
          '1809111401',
          '200000401',
          '200000413',
          '1909011501',
          '200050432',
          '1010010002',
          '200000415',
          '04000005',
          '01000003',
          '01000002',
          '04510001',
        }.contains(code)) {
      throw const AccountLoginRequired('移动云盘登录已失效，请重新网页登录');
    }
    require(
      response.successful &&
          (!j.containsKey('success') || j.boolean('success')) &&
          (code.isEmpty || {'0', '0000', '200'}.contains(code)),
      j
          .str('desc')
          .ifEmpty(j.str('message'))
          .ifEmpty('139 请求失败（HTTP ${response.status}）'),
    );
    return j;
  }

  Json data(Json j) {
    final d = j.obj('data');
    for (final key in [
      'getOutLinkInfoResp',
      'getOutLinkGeneralResp',
      'getOutLinkRes',
    ]) {
      if (d[key] is Map) return d.obj(key);
    }
    return d;
  }

  Map<String, String> cloudHeaders(
    String auth,
    String body,
    Credential? c, {
    bool includeCookie = false,
    bool includeSkey = false,
    bool family = false,
    bool familyUserDomain = false,
  }) {
    final headers = {
      'Authorization': auth,
      'mcloud-sign': C139Protocol.signHeader(body),
      'x-yun-channel-source': '10000034',
      'x-yun-app-channel': '10000034',
      'x-huawei-channelSrc': family ? '10230043' : '10000034',
      'mcloud-version': '7.17.9',
      'mcloud-client': '10701',
      'mcloud-channel': '1000101',
      'mcloud-route': '001',
      'x-yun-module-type': '100',
      'x-yun-api-version': 'v1',
      'x-yun-svc-type': family ? '2' : '1',
      'x-SvcType': family ? '2' : '1',
      if (family && familyUserDomain) 'mcloud-userid-flag': '1',
      'caller': 'web',
      'x-inner-ntwk': '2',
      'CMS-DEVICE': 'default',
      'x-m4c-src': '10002',
      'x-m4c-caller': 'PC',
      'X-Deviceinfo':
          '||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||',
      'x-yun-client-info':
          '||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||dW5kZWZpbmVk||',
      'INNER-HCY-ROUTER-HTTPS': '1',
      'Sec-Fetch-Site': 'same-site',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Dest': 'empty',
      'X-Requested-With': 'mark.via',
      'Content-Type': 'application/json;charset=UTF-8',
      'User-Agent': ua,
      'Origin': 'https://yun.139.com',
      'Referer': 'https://yun.139.com/',
      'Accept': 'application/json, text/plain, */*',
    };
    final cookie = c?.primary ?? '';
    if (includeCookie && cookie.isNotEmpty) headers['Cookie'] = cookie;
    if (includeSkey) {
      final skey = LoginCredentials.c139Cookie(cookie, 'skey');
      require(
        includeCookie && skey.isNotEmpty,
        '139 登录态缺少 skey，请重新获取完整 Cookie',
      );
      headers['mcloud-skey'] = skey;
    }
    return headers;
  }

  Future<Json> cloud(
    String url,
    Json body,
    String auth,
    Credential? c, {
    bool includeCookie = false,
    bool includeSkey = false,
    bool family = false,
  }) async {
    require(auth.isNotEmpty, '请配置中国移动云盘 Authorization');
    final plain = encoded(body);
    final readOnly = {
      '$cloudBase/file/getDownloadUrl',
      '$cloudBase/file/list',
      '$cloudBase/task/get',
    }.contains(url);
    final response = await (readOnly ? http.postJsonRead : http.postJson)(
      url,
      plain,
      cloudHeaders(
        auth,
        plain,
        c,
        includeCookie: includeCookie,
        includeSkey: includeSkey,
        family: family,
      ),
    );
    // An expired session may return an HTML login page instead of JSON.
    if ({401, 403}.contains(response.status)) check(response, const {});
    return check(response, response.json);
  }

  Future<Json> share(
    String url,
    String? operation,
    Json body,
    String? auth, {
    bool anonymous = false,
  }) async {
    final plain = encoded(operation == null ? body : {operation: body});
    final headers = {
      'hcy-cool-flag': '1',
      'Accept-Encoding': 'identity',
      'x-deviceinfo': '||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||',
      'x-huawei-channelsrc': '10245500',
      'x-mm-source': '0002',
      'Content-Type': 'application/json;charset=UTF-8',
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36',
      'Origin': 'https://yun.139.com',
      'Referer': 'https://yun.139.com/',
      'Accept': 'application/json, text/plain, */*',
      if (!anonymous) 'mcloud-sign': C139Protocol.signHeader(plain),
      if (!anonymous && auth?.isNotEmpty == true) 'Authorization': auth!,
    };
    final readOnly = {
      '$shareBase/IOutLink/getOutLinkGeneral',
      '$shareBase/IOutLink/getOutLinkInfoV6',
      '$shareBase/IBatchOprTask/queryBatchOprTaskDetail',
    }.contains(url);
    final response = await (readOnly ? http.postJsonRead : http.postJson)(
      url,
      C139Protocol.encrypt(plain),
      headers,
    );
    if (!response.successful) check(response, const {});
    Json j;
    require(
      response.body.length <= C139PasscodeProtocol.maxResponseBytes,
      '移动分享响应过大',
    );
    try {
      j = response.json;
    } on AppException {
      j = asJson(jsonDecode(C139Protocol.decrypt(response.body)));
    }
    return check(response, j);
  }

  @override
  Future<CloudAccount> account(Credential c) async {
    final auth = requiredAuth(c);
    final body = {
      'userDomainId': LoginCredentials.c139Cookie(
        c.primary,
        'ud_id',
      ).ifEmpty(c.field('userDomainId')),
    };
    Future<CloudAccount> read(String endpoint) async {
      final response = await cloud(
        'https://user-njs.yun.139.com/user/disk/$endpoint',
        body,
        auth,
        c,
        includeCookie: true,
        includeSkey: LoginCredentials.c139Cookie(c.primary, 'skey').isNotEmpty,
      );
      return C139Quota.parse(
        data(response),
        c.field('nickname').ifEmpty(accountId(auth)).ifEmpty('139 用户'),
      );
    }

    try {
      return await read('quota/detail');
    } on AccountLoginRequired {
      rethrow;
    } on AppException {
      // The current official web client also uses this personal-space endpoint.
      RequestScope.checkpoint();
      return read('getPersonalDiskInfo');
    }
  }

  @override
  Future<BrowseSession> openShare(ParsedLink link, Credential? c) async {
    final command = C139Passcode.fromLink(link);
    if (command != null) {
      if (c == null) throw const AccountLoginRequired('移动口令解析需要先登录移动云盘');
      final page = await _commandPage(command, 'root', 1, c);
      final session = BrowseSession(
        platform: platform,
        mode: BrowseMode.share,
        title: page.str('lkName').ifEmpty('移动云盘口令分享'),
        rootId: 'root',
        metadata: {
          'linkCode': command.code,
          'linkCodeType': '${command.codeType}',
          'linkId': page.str('linkID').ifEmpty(page.str('linkId')),
          'password': command.password ?? '',
          'authorization': requiredAuth(c),
          'account': accountId(requiredAuth(c)),
          'cookie': c.primary,
        },
        sourceLink: link,
      );
      return _resolveCommandShare(session, c);
    }
    require(link.shareId?.isNotEmpty == true, '139 分享链接缺少链接 ID');
    final general =
        data(
          await share(
            '$shareBase/IOutLink/getOutLinkGeneral',
            'getOutLinkGeneralReq',
            {'linkID': link.shareId, 'isPasswd': 1, 'account': ''},
            null,
            anonymous: true,
          ),
        ).list('outLinkGeneral').firstOrNull ??
        <String, dynamic>{};
    final auth = c == null ? '' : authorization(c);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: general.str('lkName').ifEmpty('中国移动云盘分享'),
      rootId: 'root',
      metadata: {
        'linkId': link.shareId!,
        'password': (link.passcode ?? '')
            .ifEmpty(general.str('passwd'))
            .ifEmpty(general.str('password')),
        'authorization': auth,
        'account': accountId(auth),
        'cookie': c?.primary ?? '',
      },
      sourceLink: link,
    );
  }

  static int _commandFileSize(Json item) {
    final size = int.tryParse(item.str('coSize'));
    require(size != null && size >= 0, '移动口令文件大小无效，请刷新重试');
    return size!;
  }

  Future<Json> _commandPage(
    C139Passcode command,
    String parent,
    int begin,
    Credential credential,
  ) async {
    final auth = requiredAuth(credential);
    // Web sessions use the signed JSON endpoint and its web protocol key.
    // The app's XML dispatcher rejects those sessions with an empty HTTP 500.
    final response = await share(
      '$shareBase/IOutLink/getOutLinkInfoV6',
      'getOutLinkInfoReq',
      C139PasscodeProtocol.requestData(
        command,
        accountId(auth),
        parent: parent,
        begin: begin,
        end: begin + 199,
      ),
      auth,
    );
    require(
      response.str('resultCode') == '0' && response['data'] is Map,
      '移动口令服务未返回有效结果，请刷新重试',
    );
    return data(response);
  }

  Future<BrowseSession> _resolveCommandShare(
    BrowseSession session,
    Credential credential,
  ) async {
    if (session.meta('linkId').isNotEmpty || session.meta('linkCode').isEmpty) {
      return session;
    }
    final auth = requiredAuth(credential);
    final command = C139Passcode(
      session.meta('linkCode'),
      password: session.meta('password'),
    );
    // The directory endpoint omits the share ID for command links. The web
    // detail endpoint resolves it; a command token is not a transfer link ID.
    final result = data(
      await share(
        '$shareBase/IOutLink/getOutLinkGeneral',
        'getOutLinkGeneralReq',
        C139PasscodeProtocol.generalRequestData(command, accountId(auth)),
        auth,
      ),
    );
    final entries = result.list('outLinkGeneral');
    require(entries.length == 1, '移动口令未返回有效分享详情，请重新解析后重试');
    final general = entries.single;
    final linkId = general.str('linkID').ifEmpty(general.str('linkId')).trim();
    require(linkId.isNotEmpty, '移动口令未返回有效分享 ID，请重新解析后重试');
    return BrowseSession(
      platform: session.platform,
      mode: session.mode,
      title: general.str('lkName').ifEmpty(session.title),
      rootId: session.rootId,
      metadata: {
        ...session.metadata,
        'linkId': linkId,
        'password': session
            .meta('password')
            .ifEmpty(general.str('passwd').ifEmpty(general.str('password'))),
      },
      sourceLink: session.sourceLink,
    );
  }

  @override
  Future<BrowseSession> openPersonal(Credential c) async => BrowseSession(
    platform: platform,
    mode: BrowseMode.personal,
    title: '我的中国移动云盘',
    rootId: 'root',
    metadata: {'authorization': requiredAuth(c), 'cookie': c.primary},
  );

  String _familyUserDomain(Credential c) => LoginCredentials.c139Cookie(
    c.primary,
    'ud_id',
  ).ifEmpty(c.field('userDomainId'));

  Json _familyAccount(Credential c, {required bool useUserDomain}) {
    final domain = _familyUserDomain(c);
    if (useUserDomain) return {'userDomainId': domain, 'accountType': 1};
    // Downloads and older imported authorizations use the account form.
    final account = accountId(requiredAuth(c));
    require(account.isNotEmpty, '无法读取移动云盘账号，请重新登录');
    return common(account);
  }

  Future<Json> _familyRequest(String path, Json body, Credential c) async {
    RequestScope.checkpoint();
    final auth = requiredAuth(c);
    final useUserDomain =
        {
          'cloudManage/v1.0/queryFamilyCloud',
          'content/v1.2/queryContentList',
        }.contains(path) &&
        _familyUserDomain(c).isNotEmpty;
    // The web interceptor adds identity before computing mcloud-sign.
    final plain = encoded({
      ...body,
      'commonAccountInfo': _familyAccount(c, useUserDomain: useUserDomain),
    });
    HttpResult? response;
    Json result = {};
    try {
      response =
          await ({
                'content/v1.0/getFileDownLoadURL',
                'content/v1.2/queryContentList',
                'cloudManage/v1.0/queryFamilyCloud',
              }.contains(path)
              ? http.postJsonRead
              : http.postJson)(
            '$familyBase/$path',
            plain,
            cloudHeaders(
              auth,
              plain,
              c,
              includeCookie: true,
              includeSkey: LoginCredentials.c139Cookie(
                c.primary,
                'skey',
              ).isNotEmpty,
              family: true,
              familyUserDomain: useUserDomain,
            ),
          );
      RequestScope.checkpoint();
      if ({401, 403}.contains(response.status)) check(response, const {});
      result = response.json;
      check(response, result);
      require(result['data'] is Map, '移动家庭云响应不完整，请重试');
      final value = result.obj('data');
      require(
        value['result'] == null || value['result'] is Map,
        '移动家庭云状态格式无效，请重试',
      );
      if (value['result'] is Map) {
        check(response, value.obj('result'));
      }
      return value;
    } catch (error, stack) {
      RequestScope.checkpoint();
      final code =
          [
                result.obj('data').obj('result').str('resultCode'),
                result.str('resultCode'),
                result.str('code'),
              ]
              .where(
                (value) =>
                    value.isNotEmpty && !{'0', '0000', '200'}.contains(value),
              )
              .firstOrNull;
      DiagnosticLog.error(
        'cloud.family.request_failed',
        error,
        stack,
        fields: {
          'platform': platform.key,
          'stage': path.split('/').last,
          if (response != null) 'httpStatus': response.status,
          if (code != null && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(code))
            'serverCode': code,
        },
      );
      rethrow;
    }
  }

  @override
  Future<List<CloudSpace>> familySpaces(Credential credential) async {
    final spaces = <CloudSpace>[], seen = <String>{};
    for (var page = 1; page <= 20; page++) {
      final value = await _familyRequest('cloudManage/v1.0/queryFamilyCloud', {
        'pageInfo': {'pageNum': page, 'pageSize': 100},
      }, credential);
      final total = int.tryParse(value.str('totalCount'));
      require(
        !value.containsKey('totalCount') || total != null && total >= 0,
        '移动家庭云数量无效',
      );
      require(
        value['familyCloudList'] is List &&
                (value['familyCloudList'] as List).every(
                  (item) => item is Map,
                ) ||
            value['familyCloudList'] == null && total == 0,
        '移动未返回家庭云列表，请重试',
      );
      final batch = value.list('familyCloudList');
      for (final item in batch) {
        final id = item.str('cloudID');
        require(
          RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id) && seen.add(id),
          '移动家庭云列表重复或编号无效，请刷新重试',
        );
        spaces.add(CloudSpace(id, item.str('cloudName').ifEmpty('家庭云')));
      }
      require(total == null || spaces.length <= total, '移动家庭云数量不一致，请重试');
      if (total != null && spaces.length == total ||
          total == null && batch.length < 100) {
        return spaces;
      }
      require(batch.isNotEmpty, '移动家庭云列表不完整，请重试');
    }
    throw const AppException('移动家庭云数量过多，请在官网整理后重试');
  }

  Json _familyBody(BrowseSession s) {
    require(
      s.platform == platform &&
          s.isFamily &&
          RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s.familyId),
      '移动家庭云信息已缺失，请重新选择家庭',
    );
    return {'catalogType': 3, 'cloudID': s.familyId, 'cloudType': 1};
  }

  Future<Json> _familyPage(
    BrowseSession s,
    String parent,
    int page,
    int size,
    Credential c,
  ) => _familyRequest('content/v1.2/queryContentList', {
    ..._familyBody(s),
    'catalogID': parent == s.rootId ? '' : parent,
    'contentSortType': 0,
    'pageInfo': {'pageNum': page, 'pageSize': size},
    'sortDirection': 1,
  }, c);

  String _familyPath(String value) {
    final path = value
        .trim()
        .replaceFirst(RegExp(r'^root:/*'), 'root:/')
        .replaceFirst(RegExp(r'/+$'), '');
    require(
      path.startsWith('root:/') &&
          path.length > 6 &&
          !RegExp(r'[\x00-\x1f\x7f\\]').hasMatch(path) &&
          path
              .substring(6)
              .split('/')
              .every((part) => part.isNotEmpty && part != '.' && part != '..'),
      '移动家庭云未返回有效目录路径，请刷新列表',
    );
    return path;
  }

  String _checkFamilyPath(BrowseSession s, String parent, String value) {
    final path = _familyPath(value),
        root = _familyPath(s.meta('familyRootPath'));
    require(
      parent == s.rootId
          ? path == root
          : path.startsWith('$root/') && path.endsWith('/$parent'),
      '移动家庭云目录不一致，请刷新列表',
    );
    return path;
  }

  @override
  Future<BrowseSession> openFamily(
    CloudSpace space,
    Credential credential,
  ) async {
    final candidate = BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '移动家庭云',
      rootId: '',
      metadata: {'familyId': space.id, 'familyName': space.name},
    );
    final value = await _familyPage(candidate, '', 1, 1, credential);
    final path = _familyPath(value.str('path'));
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: candidate.title,
      rootId: path.substring(6),
      metadata: {...candidate.metadata, 'familyRootPath': path},
    );
  }

  String _thumbnail(Json item) {
    final urls = item.list('thumbnailUrls');
    return urls
            .where((value) => value.str('style').toLowerCase() == 'large')
            .map((value) => value.str('url'))
            .where((url) => url.isNotEmpty)
            .firstOrNull ??
        urls
            .map((value) => value.str('url'))
            .where((url) => url.isNotEmpty)
            .firstOrNull ??
        item
            .str('bigthumbnailURL')
            .ifEmpty(item.str('midthumbnailURL'))
            .ifEmpty(item.str('thumbnailURL'));
  }

  Future<List<CloudFile>> _familyFiles(
    BrowseSession s,
    String parent,
    Credential c,
  ) async {
    final files = <CloudFile>[], seen = <String>{};
    for (var page = 1; page <= 100; page++) {
      final value = await _familyPage(s, parent, page, 100, c);
      final path = _checkFamilyPath(s, parent, value.str('path'));
      final total = int.tryParse(value.str('totalCount'));
      require(
        !value.containsKey('totalCount') || total != null && total >= 0,
        '移动家庭云文件数量无效',
      );
      require(
        value['cloudCatalogList'] is List ||
            value['cloudContentList'] is List ||
            total == 0,
        '移动家庭云文件列表不完整，请重试',
      );
      var count = 0;
      for (final (key, directory) in [
        ('cloudCatalogList', true),
        ('cloudContentList', false),
      ]) {
        require(
          value[key] == null ||
              value[key] is List &&
                  (value[key] as List).every((item) => item is Map),
          '移动家庭云文件列表格式无效',
        );
        for (final item in value.list(key)) {
          final id = item.str(directory ? 'catalogID' : 'contentID');
          final name = item.str(directory ? 'catalogName' : 'contentName');
          final size = directory ? 0 : int.tryParse(item.str('contentSize'));
          require(
            id.isNotEmpty && name.isNotEmpty && size != null && size >= 0,
            '移动家庭云文件信息不完整，请刷新列表',
          );
          require(seen.add(id), '移动家庭云返回重复分页，请刷新列表');
          files.add(
            CloudFile(
              id: id,
              name: name,
              size: size!,
              isDirectory: directory,
              parentId: parent,
              token: path,
              modifiedAt: item
                  .str('lastUpdateTime')
                  .ifEmpty(item.str('createTime')),
              thumbnailUrl: directory ? '' : _thumbnail(item),
            ),
          );
          count++;
        }
      }
      require(
        files.length <= 10000 && (total == null || files.length <= total),
        '移动家庭云文件数量不一致或过多，请进入子目录后重试',
      );
      if (total != null && files.length == total ||
          total == null && count < 100) {
        return files;
      }
      require(count > 0, '移动家庭云文件列表不完整，请刷新重试');
    }
    throw const AppException('移动家庭云目录分页过多，请进入子目录后重试');
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    if (s.isFamily) {
      if (c == null) throw const AccountLoginRequired('请先登录移动云盘');
      return _familyFiles(s, parent.ifEmpty(s.rootId), c);
    }
    final files = <CloudFile>[], seen = <String>{};
    final dir = parent.ifEmpty('root');
    if (s.mode == BrowseMode.share && s.meta('linkCode').isNotEmpty) {
      if (c == null) throw const AccountLoginRequired('移动口令解析需要先登录移动云盘');
      final command = C139Passcode(
        s.meta('linkCode'),
        password: s.meta('password'),
      );
      for (var begin = 1; begin <= 20000; begin += 200) {
        final page = await _commandPage(command, dir, begin, c);
        final batch = [
          for (final item in C139PasscodeProtocol.items(
            page,
            'caLst',
            'outLinkCaInfo',
          ))
            CloudFile(
              id: item.str('caID'),
              name: item.str('caName'),
              isDirectory: true,
              parentId: dir,
              modifiedAt: item.str('udTime').ifEmpty(item.str('ctTime')),
            ),
          for (final item in C139PasscodeProtocol.items(
            page,
            'coLst',
            'outLinkCoInfo',
          ))
            CloudFile(
              id: item.str('coID'),
              name: item.str('coName'),
              size: _commandFileSize(item),
              parentId: dir,
              modifiedAt: item.str('udTime').ifEmpty(item.str('ctTime')),
            ),
        ];
        require(
          batch.every((f) => f.id.isNotEmpty && f.name.isNotEmpty),
          '移动口令文件列表不完整，请刷新重试',
        );
        final fresh = batch.where((f) => seen.add(f.id)).toList();
        files.addAll(fresh);
        final totalText = page.str('nodNum');
        final total = int.tryParse(totalText);
        require(
          totalText.isEmpty || total != null && total >= 0,
          '移动口令目录数量无效，请刷新重试',
        );
        require(fresh.length == batch.length, '移动口令目录分页重复，请刷新重试');
        if (total != null) {
          require(files.length <= total, '移动口令目录数量不一致，请刷新重试');
        }
        if (total != null && files.length == total ||
            total == null && batch.length < 200) {
          return files;
        }
        require(batch.length == 200 && begin < 19801, '移动口令目录分页不完整，请刷新重试');
      }
      return files;
    }
    if (s.mode == BrowseMode.share) {
      for (var begin = 1; begin <= 20000; begin += 200) {
        final d = data(
          await share(
            '$shareBase/IOutLink/getOutLinkInfoV6',
            'getOutLinkInfoReq',
            {
              'account': '',
              'linkID': s.meta('linkId'),
              'passwd': s.meta('password'),
              'caSrt': 1,
              'coSrt': 1,
              'srtDr': 0,
              'bNum': begin,
              'pCaID': dir,
              'eNum': begin + 199,
            },
            null,
            anonymous: true,
          ),
        );
        require(
          d['caLst'] is List || d['coLst'] is List,
          '移动云盘分享列表响应不完整，请刷新重试',
        );
        final batch = [
          for (final j in d.list('caLst'))
            CloudFile(
              id: j.str('caID'),
              name: j.str('caName'),
              isDirectory: true,
              parentId: dir,
              modifiedAt: j.str('udTime').ifEmpty(j.str('ctTime')),
            ),
          for (final j in d.list('coLst'))
            CloudFile(
              id: j.str('coID'),
              name: j.str('coName'),
              size: j.integer('coSize'),
              isDirectory: j.boolean('isdir', j.integer('coType') == 2),
              parentId: dir,
              modifiedAt: j.str('udTime').ifEmpty(j.str('ctTime')),
              thumbnailUrl: _thumbnail(j),
            ),
        ];
        require(
          batch.every((file) => file.id.isNotEmpty),
          '移动云盘分享文件标识缺失，请刷新列表',
        );
        final fresh = batch
            .where((f) => f.id.isNotEmpty && seen.add(f.id))
            .toList();
        files.addAll(fresh);
        if (batch.length < 200 || fresh.isEmpty) break;
        require(begin < 19801, '目录文件过多，请缩小范围后重试');
      }
    } else {
      final auth = (c == null ? '' : authorization(c)).ifEmpty(
        s.meta('authorization'),
      );
      String? cursor;
      final cursors = <String>{};
      for (var page = 0; page < 100; page++) {
        final d = data(
          await cloud(
            '$cloudBase/file/list',
            {
              'pageInfo': {'pageSize': 100, 'pageCursor': cursor},
              'orderBy': 'updated_at',
              'orderDirection': 'DESC',
              'parentFileId': dir,
              'imageThumbnailStyleList': ['Small', 'Large'],
            },
            auth,
            c,
          ),
        );
        require(d['items'] is List, '移动云盘文件列表响应不完整，请刷新重试');
        final items = d.list('items');
        require(
          items.every((item) => item.str('fileId').isNotEmpty),
          '移动云盘文件标识缺失，请刷新列表',
        );
        files.addAll(
          items
              .where((j) => seen.add(j.str('fileId')))
              .map(
                (j) => CloudFile(
                  id: j.str('fileId'),
                  name: j.str('name'),
                  size: j.integer('size'),
                  isDirectory:
                      j.str('type') == 'folder' || j.boolean('isFolder'),
                  parentId: dir,
                  modifiedAt: j.str('updatedAt'),
                  thumbnailUrl: _thumbnail(j),
                ),
              ),
        );
        final rawNext = d.str('nextPageCursor').trim();
        final next = rawNext.toLowerCase() == 'null' ? '' : rawNext;
        if (next.isEmpty || items.isEmpty || !cursors.add(next)) break;
        cursor = next;
        require(page < 99, '目录文件过多，请缩小范围后重试');
      }
    }
    return files;
  }

  Future<DownloadSpec> _transferDownload(
    BrowseSession share,
    CloudFile file,
    Credential account,
  ) async {
    share = await _resolveCommandShare(share, account);
    require(share.meta('linkId').isNotEmpty, '此移动口令未返回可转存的分享 ID，请使用原分享链接下载或转存');
    final personal = await openPersonal(account);
    final name = 'AsterLink临时转存_${newId()}';
    final directory = await OperationProgress.step(
      OperationStage.createTemporary,
      () => _temporaryFolder(personal.rootId, name, account),
    );
    final cleanup = DownloadCleanup(
      url: '',
      action: {
        'kind': 'temporary-folder',
        'platform': platform.key,
        'folderId': directory,
        'name': name,
        'accountRevision': account.updatedAt,
      },
    );
    await stageCleanup?.call(cleanup);
    await OperationProgress.step(
      OperationStage.transfer,
      () => saveShare(share, [file], directory, account),
    );
    final transferred = await OperationProgress.step(
      OperationStage.waitTransfer,
      () async {
        for (var attempt = 0; attempt < 8; attempt++) {
          RequestScope.checkpoint();
          final matches = (await list(personal, directory, account))
              .where(
                (item) =>
                    !item.isDirectory &&
                    item.name == file.name &&
                    (file.size <= 0 || item.size == file.size),
              )
              .toList();
          if (matches.length == 1) {
            final transferred = matches.single;
            require(
              file.hashValue == null ||
                  transferred.hashValue == null ||
                  file.hashType != transferred.hashType ||
                  file.hashValue!.toLowerCase() ==
                      transferred.hashValue!.toLowerCase(),
              '转存后的文件校验标识不一致',
            );
            return transferred;
          }
          require(matches.length <= 1, '转存目录存在多个同名文件，无法确定下载目标');
          await Future<void>.delayed(taskDelay);
        }
        throw const AppException('转存已提交，但目标文件暂不可见，请稍后重试');
      },
    );
    return (await download(
      personal,
      transferred,
      account,
    )).copyWith(fileName: file.name, cleanup: cleanup);
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    require(s.canManageFiles, '请在个人网盘中新建文件夹');
    require(
      name.trim().isNotEmpty && !RegExp(r'[/\\\x00-\x1f]').hasMatch(name),
      '文件夹名称无效',
    );
    final id = await _temporaryFolder(parent, name, c);
    return CloudFile(id: id, name: name, isDirectory: true, parentId: parent);
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    require(s.canManageFiles, '请在个人网盘中上传文件');
    final auth = requiredAuth(c), io = UploadIO(http, source, onProgress);
    Future<Json> post(String path, Json body) async =>
        data(await cloud('$cloudBase/file/$path', body, auth, c));
    final hash = await io.digest(sha256);
    final partSize = source.size > 30 * 1024 * 1024 * 1024
        ? 512 * 1024 * 1024
        : 100 * 1024 * 1024;
    final count = max(1, (source.size / partSize).ceil());
    final parts = <Json>[
      for (var i = 0; i < count; i++)
        {
          'partNumber': i + 1,
          'partSize': min(source.size - i * partSize, partSize),
          'parallelHashCtx': {'partOffset': i * partSize},
        },
    ];
    final pre = await post('create', {
      'contentHash': hash,
      'contentHashAlgorithm': 'SHA256',
      'contentType': 'application/octet-stream',
      'parallelUpload': false,
      'partInfos': parts.take(100).toList(),
      'size': source.size,
      'parentFileId': parent,
      'name': source.name,
      'type': 'file',
      'fileRenameMode': 'auto_rename',
    });
    require(!pre.boolean('exist'), '移动云盘已有同名文件，请重新命名后上传');
    final id = pre.str('fileId'), uploadId = pre.str('uploadId');
    require(id.isNotEmpty, '移动云盘未创建上传任务');
    if (!pre.boolean('rapidUpload')) {
      require(uploadId.isNotEmpty, '移动云盘未返回上传标识');
      for (var first = 0; first < count; first += 100) {
        final batch = first == 0
            ? pre
            : await post('getUploadUrl', {
                'fileId': id,
                'uploadId': uploadId,
                'partInfos': parts.skip(first).take(100).toList(),
              });
        final addresses = batch.list('partInfos')
          ..sort(
            (a, b) =>
                a.integer('partNumber').compareTo(b.integer('partNumber')),
          );
        require(addresses.length == min(100, count - first), '移动云盘未返回完整上传分段');
        for (var i = 0; i < addresses.length; i++) {
          final part = addresses[i], index = part.integer('partNumber') - 1;
          require(index == first + i, '移动云盘上传分段序号无效');
          await io.send(
            part.str('uploadUrl'),
            start: index * partSize,
            end: min(source.size, (index + 1) * partSize),
            headers: {
              'Content-Type': 'application/octet-stream',
              'Origin': 'https://yun.139.com',
              'Referer': 'https://yun.139.com/',
            },
          );
        }
      }
      io.progress(UploadPhase.finishing, source.size);
      await post('complete', {
        'contentHash': hash,
        'contentHashAlgorithm': 'SHA256',
        'fileId': id,
        'uploadId': uploadId,
      });
    }
    return io.confirm(() => list(s, parent, c), id: id);
  }

  Future<String> _temporaryFolder(
    String parent,
    String name,
    Credential account,
  ) async {
    final result = data(
      await cloud(
        '$cloudBase/file/create',
        {
          'parentFileId': parent,
          'name': name,
          'description': '',
          'type': 'folder',
          'fileRenameMode': 'force_rename',
        },
        requiredAuth(account),
        account,
      ),
    );
    final id = result.str('fileId');
    require(id.isNotEmpty && id != parent, '移动云盘未返回临时目录 ID');
    return id;
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!f.isDirectory, '文件夹不能直接下载');
    if (s.mode == BrowseMode.share) {
      require(c != null, '分享下载需要先登录网盘账号');
      return _transferDownload(s, f, c!);
    }
    return OperationProgress.step(OperationStage.downloadLink, () async {
      final auth = (c == null ? '' : authorization(c)).ifEmpty(
        s.meta('authorization'),
      );
      Json d;
      if (s.isFamily) {
        if (c == null) throw const AccountLoginRequired('请先登录移动云盘');
        d = await _familyRequest('content/v1.0/getFileDownLoadURL', {
          ..._familyBody(s),
          'contentID': f.id,
          'path': _checkFamilyPath(s, f.parentId, f.token),
        }, c);
      } else {
        d = data(
          await cloud(
            '$cloudBase/file/getDownloadUrl',
            {'fileId': f.id},
            auth,
            c,
          ),
        );
      }
      final url = d
          .str(s.isFamily ? 'downloadURL' : 'downloadUrl')
          .ifEmpty(d.str('url'));
      require(url.isNotEmpty, '139 没有返回可用下载链接');
      final uri = Uri.tryParse(url);
      require(
        uri != null &&
            {'http', 'https'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty,
        '移动云盘返回的下载地址无效',
      );
      return DownloadSpec(
        url: url,
        fileName: f.name,
        expectedSize: f.size,
        checksumType: f.hashType,
        checksumValue: f.hashValue,
        headers: {'User-Agent': ua, 'Referer': 'https://yun.139.com/'},
      );
    });
  }

  void personal(BrowseSession s) =>
      require(s.platform == platform && s.canManageFiles, '请在个人网盘中执行此操作');
  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    personal(s);
    await cloud(
      '$cloudBase/file/update',
      {'fileId': f.id, 'name': name, 'description': ''},
      requiredAuth(c),
      c,
    );
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    personal(s);
    final d = data(
      await cloud(
        '$cloudBase/file/batchMove',
        {'fileIds': files.map((f) => f.id).toList(), 'toParentFileId': target},
        requiredAuth(c),
        c,
      ),
    );
    await poll(d.str('taskId'), c);
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    final d = data(
      await cloud(
        '$cloudBase/recyclebin/batchTrash',
        {'fileIds': files.map((f) => f.id).toList()},
        requiredAuth(c),
        c,
      ),
    );
    await poll(d.str('taskId'), c);
  }

  Future<void> poll(String id, Credential c) async {
    require(id.isNotEmpty, '移动云盘未返回操作任务 ID，请刷新列表确认');
    for (var attempt = 0; attempt < 30; attempt++) {
      RequestScope.checkpoint();
      final result = data(
        await cloud('$cloudBase/task/get', {'taskId': id}, requiredAuth(c), c),
      );
      require(result['taskInfo'] is Map, '移动云盘未返回有效任务状态');
      final info = result.obj('taskInfo');
      final status = info.str('status').toLowerCase();
      require(
        !{'failed', 'error', 'cancelled', '3', '4'}.contains(status),
        '139 异步任务失败',
      );
      require(
        result
            .list('batchFileResults')
            .every((item) => {'', '0', '0000'}.contains(item.str('errCode'))),
        '移动云盘部分文件操作失败，请刷新列表确认',
      );
      if (info.integer('progress') >= 100 ||
          {'success', 'succeed', 'completed', 'done', '2'}.contains(status)) {
        return;
      }
      await Future<void>.delayed(taskDelay);
    }
    throw const AppException('139 异步任务超时');
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请打开分享链接');
    s = await _resolveCommandShare(s, c);
    require(s.meta('linkId').isNotEmpty, '此移动口令未返回可转存的分享 ID，请使用原分享链接下载或转存');
    final auth = requiredAuth(c), account = accountId(requiredAuth(c));
    require(account.isNotEmpty, '无法从 139 Authorization 解析账号');
    final request = {
      'createOuterLinkBatchOprTaskReq': {
        'msisdn': account,
        'ownerAccount': '',
        'taskType': 1,
        'taskInfo': {
          'contentInfoList': files
              .where((f) => !f.isDirectory)
              .map((f) => '/${f.id}')
              .toList(),
          'catalogInfoList': files
              .where((f) => f.isDirectory)
              .map((f) => f.id)
              .toList(),
          'newCatalogID': target,
          'linkID': s.meta('linkId'),
          'newCatalogName': '文析助手转存',
          'needPassword': true,
        },
        'linkID': s.meta('linkId'),
        'needPassword': true,
      },
      'commonAccountInfo': common(account),
    };
    final response = await share(
      '$shareBase/IBatchOprTask/createOuterLinkBatchOprTask',
      null,
      request,
      auth,
    );
    // The response envelope varies across deployed 139 backends.
    final taskId = data(
      response,
    ).str('taskID').ifEmpty(response.obj('data').str('taskID'));
    require(taskId.isNotEmpty, '139 转存未返回任务 ID');
    for (var attempt = 0; attempt < 40; attempt++) {
      RequestScope.checkpoint();
      final result = data(
        await share('$shareBase/IBatchOprTask/queryBatchOprTaskDetail', null, {
          'queryBatchOprTaskDetailReq': {
            'taskID': taskId,
            'msisdn': account,
            'commonAccountInfo': common(account),
          },
        }, auth),
      );
      final task = result.obj('batchOprTask');
      final status = task.str('taskStatus').toLowerCase();
      require(
        !{'3', '4', '5', 'failed', 'error'}.contains(status),
        '139 转存任务失败',
      );
      if (task.integer('taskStatus') == 2 && task.integer('progress') >= 100 ||
          {'succeed', 'success'}.contains(status)) {
        final entries = result.obj('contentList').list('idRspInfo');
        require(
          entries.every((item) => {'0', '0000'}.contains(item.str('reason'))),
          '移动云盘部分文件转存失败，请刷新目标目录确认',
        );
        for (final file in files.where((file) => !file.isDirectory)) {
          require(
            entries.any(
              (entry) =>
                  entry.str('srcId') == file.id &&
                  entry.str('rstId').isNotEmpty,
            ),
            '移动云盘未确认所选文件的转存结果，请刷新目标目录确认',
          );
        }
        return;
      }
      await Future<void>.delayed(taskDelay);
    }
    throw const AppException('139 转存任务超时');
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    personal(s);
    final auth = requiredAuth(c), account = accountId(requiredAuth(c));
    require(account.isNotEmpty, '无法从 139 Authorization 解析账号');
    final response = await cloud(
      'https://yun.139.com/orchestration/personalCloud-rebuild/outlink/v1.0/getOutLink',
      {
        'getOutLinkReq': {
          'subLinkType': 0,
          'encrypt': 1,
          'coIDLst': files
              .where((f) => !f.isDirectory)
              .map((f) => f.id)
              .toList(),
          'caIDLst': files
              .where((f) => f.isDirectory)
              .map((f) => f.id)
              .toList(),
          'pubType': 1,
          'dedicatedName': options.title.ifEmpty(
            files.firstOrNull?.name ?? '分享文件',
          ),
          'periodUnit': 1,
          if ({1, 7, 30}.contains(options.expiryDays))
            'period': options.expiryDays,
          'viewerLst': [],
          'extInfo': {'isWatermark': 0, 'shareChannel': '3001'},
          'commonAccountInfo': common(account),
        },
      },
      auth,
      c,
      includeCookie: true,
      includeSkey: LoginCredentials.c139Cookie(c.primary, 'skey').isNotEmpty,
    );
    final result =
        data(response).list('getOutLinkResSet').firstOrNull ??
        response
            .obj('data')
            .obj('getOutLinkRes')
            .list('getOutLinkResSet')
            .firstOrNull ??
        <String, dynamic>{};
    final url = result.str('linkUrl').ifEmpty(result.str('shareUrl'));
    require(url.isNotEmpty, '139 创建分享未返回链接');
    return ShareCreation(url, result.str('passwd'), options.title);
  }
}
