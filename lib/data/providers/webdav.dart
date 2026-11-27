import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../../domain/webdav.dart';
import '../http.dart';
import '../http_retry.dart';
import '../uploads/upload_concurrency.dart';
import 'personal_cloud.dart';
import 'webdav_relay.dart';

/// Shared bounded WebDAV transport for browsing and backup files.
class WebDavClient {
  WebDavClient({Dio? client}) : dio = client ?? DioJsonHttp().dio;
  final Dio dio;

  static Map<String, String> authorization(String username, String password) =>
      {
        if (username.isNotEmpty || password.isNotEmpty)
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      };

  Future<Uint8List> request(
    String method,
    Uri uri, {
    required String username,
    required String password,
    Stream<List<int>> Function()? data,
    int? length,
    Map<String, String> headers = const {},
    int limit = 64 * 1024,
    Set<int>? codes,
    void Function(int, int)? onProgress,
    void Function()? guard,
  }) async {
    void checkpoint() {
      RequestScope.checkpoint();
      guard?.call();
    }

    Uint8List bytes = Uint8List(0);
    Future<HttpResult> send() async {
      checkpoint();
      final cancel = CancelToken(), parent = RequestScope.current;
      var finished = false;
      parent?.whenCancel.then((_) {
        if (!finished) cancel.cancel();
      });
      try {
        final response = await dio.request<ResponseBody>(
          uri.toString(),
          data: data?.call(),
          cancelToken: cancel,
          onSendProgress: onProgress,
          options: Options(
            method: method,
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (_) => true,
            sendTimeout: method == 'PUT' ? const Duration(minutes: 30) : null,
            headers: {
              ...authorization(username, password),
              if (length != null) 'Content-Length': '$length',
              'Content-Type': method == 'PROPFIND'
                  ? 'application/xml; charset=utf-8'
                  : 'application/octet-stream',
              ...headers,
            },
          ),
        );
        checkpoint();
        final output = BytesBuilder(copy: false);
        if (response.data != null) {
          await for (final chunk in response.data!.stream) {
            checkpoint();
            require(output.length + chunk.length <= limit, 'WebDAV 返回内容过大');
            output.add(chunk);
          }
        }
        checkpoint();
        bytes = output.takeBytes();
        return HttpResult(response.statusCode ?? 0, '', response.headers.map);
      } on DioException catch (error) {
        checkpoint();
        throw HttpRequestFailure.network(error);
      } on HttpException catch (error) {
        checkpoint();
        throw HttpRequestFailure.httpConnection(error);
      } finally {
        finished = true;
        cancel.cancel();
      }
    }

    Future<HttpResult> execute() => {'GET', 'PROPFIND', 'HEAD'}.contains(method)
        ? ReadRetryScope.current?.execute(send) ?? send()
        : WriteRequestScope.current?.track(send) ?? send();
    final response = method == 'PUT'
        ? await uploadConnections.run(execute)
        : await execute();
    checkpoint();
    final code = response.status;
    if (!(codes?.contains(code) ?? (code >= 200 && code < 300))) {
      if (code == 401) throw const AccountLoginRequired('WebDAV 账号或密码错误，请重新连接');
      throw AppException(switch (code) {
        403 => 'WebDAV 目录权限不足',
        404 => 'WebDAV 目录或文件不存在',
        405 => 'WebDAV 服务不支持此操作，或目录中已有同名项目',
        409 => 'WebDAV 目标目录不存在，请刷新后重新选择',
        412 => 'WebDAV 中已有同名项目，本次操作未覆盖原文件',
        423 => 'WebDAV 文件被锁定，请稍后重试',
        507 => 'WebDAV 存储空间不足',
        >= 300 && < 400 => 'WebDAV 地址发生重定向，请填写最终目录地址',
        _ => 'WebDAV 请求失败（$code），请稍后重试',
      });
    }
    return bytes;
  }

  Future<List<CloudFile>> list(
    WebDavLocation location,
    String parent, {
    required String username,
    required String password,
    void Function()? guard,
  }) async {
    final xml = utf8.encode(
      '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>',
    );
    final bytes = await request(
      'PROPFIND',
      location.uri(parent, directory: true),
      username: username,
      password: password,
      data: () => Stream.value(xml),
      length: xml.length,
      headers: const {'Depth': '1'},
      codes: const {207},
      limit: 2 * 1024 * 1024,
      guard: guard,
    );
    return parseWebDavFiles(utf8.decode(bytes), location, parent);
  }

  Future<void> test(
    WebDavLocation location, {
    required String username,
    required String password,
  }) async {
    await list(location, '/', username: username, password: password);
    final id = location.child('/', '.asterlink-test-${newId()}.json');
    final bytes = utf8.encode(newId());
    try {
      await request(
        'PUT',
        location.uri(id),
        username: username,
        password: password,
        data: () => Stream.value(bytes),
        length: bytes.length,
        headers: const {'If-None-Match': '*'},
      );
      final read = await request(
        'GET',
        location.uri(id),
        username: username,
        password: password,
      );
      require(sha256.convert(read) == sha256.convert(bytes), 'WebDAV 回读内容不一致');
    } finally {
      await RequestScope().run(
        () => request(
          'DELETE',
          location.uri(id),
          username: username,
          password: password,
          codes: const {200, 202, 204, 404},
        ),
        inheritGuard: false,
      );
    }
  }

  void close() => dio.close(force: true);
}

List<CloudFile> parseWebDavFiles(
  String xml,
  WebDavLocation location,
  String parent,
) {
  require(
    !RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(xml),
    'WebDAV 目录响应不受支持',
  );
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml);
  } on XmlParserException {
    throw const AppException('WebDAV 返回的目录格式无效');
  }
  bool dav(XmlElement e, String name) =>
      e.name.local == name && e.namespaceUri == 'DAV:';
  require(dav(document.rootElement, 'multistatus'), 'WebDAV 返回的目录格式无效');
  final directory = location.uri(parent, directory: true);
  final directorySegments = directory.pathSegments
      .where((s) => s.isNotEmpty)
      .toList();
  final files = <String, CloudFile>{};
  for (final response in document.descendants.whereType<XmlElement>().where(
    (e) => dav(e, 'response'),
  )) {
    final href = response.childElements
        .where((e) => dav(e, 'href'))
        .firstOrNull
        ?.innerText;
    if (href == null) continue;
    final Uri target;
    try {
      target = directory.resolve(href.trim());
    } on FormatException {
      continue;
    }
    final id = location.id(target);
    final segments = target.pathSegments.where((s) => s.isNotEmpty).toList();
    if (id == null ||
        segments.length != directorySegments.length + 1 ||
        List.generate(
          directorySegments.length,
          (i) => segments[i] == directorySegments[i],
        ).contains(false)) {
      continue;
    }
    final properties = <XmlElement>[];
    for (final stat in response.childElements.where(
      (e) => dav(e, 'propstat'),
    )) {
      final status =
          stat.childElements
              .where((e) => dav(e, 'status'))
              .firstOrNull
              ?.innerText ??
          '';
      if (status.isNotEmpty &&
          !RegExp(r'^HTTP/\S+\s+2\d\d(?:\s|$)').hasMatch(status.trim())) {
        continue;
      }
      properties.addAll(
        stat.childElements
            .where((e) => dav(e, 'prop'))
            .expand((e) => e.childElements),
      );
    }
    if (properties.isEmpty) continue;
    String property(String name) =>
        properties.where((e) => dav(e, name)).firstOrNull?.innerText ?? '';
    final type = properties.where((e) => dav(e, 'resourcetype')).firstOrNull;
    final isDirectory =
        type?.childElements.any((e) => dav(e, 'collection')) ?? false;
    var modified = property('getlastmodified');
    try {
      modified = HttpDate.parse(modified).toIso8601String();
    } catch (_) {
      /* Some servers omit dates. */
    }
    files[id] = CloudFile(
      id: id,
      name: segments.last,
      parentId: parent,
      isDirectory: isDirectory,
      size: (int.tryParse(property('getcontentlength')) ?? 0).clamp(
        0,
        0x7fffffffffffffff,
      ),
      modifiedAt: modified,
      token: property('getetag'),
    );
    require(files.length <= 10000, 'WebDAV 目录文件过多，请分批整理');
  }
  return files.values.toList();
}

class WebDavConnector extends PersonalCloudConnector {
  WebDavConnector({WebDavClient? client}) : client = client ?? WebDavClient();
  final WebDavClient client;
  late final _relay = WebDavRelay(client.dio);
  final _passwords = <String, String>{};
  final _connecting = <String>{};
  @override
  CloudPlatform get platform => CloudPlatform.webdav;

  bool hasPassword(Credential c) =>
      c.field('rememberPassword') == 'true' ||
      _passwords.containsKey(c.field('sessionId'));
  String password(Credential c) {
    if (c.field('rememberPassword') == 'true') return c.field('password');
    return _passwords[c.field('sessionId')] ??
        (throw const AccountLoginRequired('请重新连接 WebDAV，登录密码未保存在本机'));
  }

  void retainSessions(Iterable<Credential> credentials) {
    final ids = {
      ...credentials.map((c) => c.field('sessionId')),
      ..._connecting,
    };
    _passwords.removeWhere((key, _) => !ids.contains(key));
    _relay.retainSessions(ids);
  }

  void forget(Credential c) => _passwords.remove(c.field('sessionId'));
  void finishConnection(Credential c, {required bool saved}) {
    _connecting.remove(c.field('sessionId'));
    if (!saved) forget(c);
  }

  Future<LoginResult> connect(Credential c, String secret) async {
    final location = WebDavLocation(c.primary);
    await client.list(
      location,
      '/',
      username: c.field('username'),
      password: secret,
    );
    RequestScope.checkpoint();
    if (c.field('rememberPassword') != 'true') {
      _connecting.add(c.field('sessionId'));
      _passwords[c.field('sessionId')] = secret;
    }
    return LoginResult(c, CloudAccount(c.label));
  }

  WebDavLocation location(BrowseSession s, Credential c) {
    personal(s);
    final result = WebDavLocation(c.primary);
    require(
      s.meta('webdavRoot').isEmpty ||
          s.meta('webdavRoot') == result.base.toString(),
      'WebDAV 地址已变化，请重新选择目录',
    );
    return result;
  }

  @override
  Future<CloudAccount> account(Credential c) async {
    await client.list(
      WebDavLocation(c.primary),
      '/',
      username: c.field('username'),
      password: password(c),
    );
    return CloudAccount(c.field('nickname').ifEmpty(c.label));
  }

  @override
  Future<BrowseSession> openPersonal(Credential c) async {
    password(c);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: c.field('nickname').ifEmpty(c.label),
      rootId: '/',
      metadata: {'webdavRoot': WebDavLocation(c.primary).base.toString()},
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    require(c != null, '请先连接 WebDAV');
    return client.list(
      location(s, c!),
      parent,
      username: c.field('username'),
      password: password(c),
    );
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile file,
    Credential? c,
  ) async {
    require(c != null && !file.isDirectory, '请选择 WebDAV 文件');
    final url = await _relay.file(
      credential: c!,
      location: location(s, c),
      id: file.id,
      authorization: WebDavClient.authorization(
        c.field('username'),
        password(c),
      ),
    );
    RequestScope.checkpoint();
    return DownloadSpec(
      url: url.toString(),
      fileName: file.name,
      expectedSize: file.size,
    );
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    final root = location(s, c), id = root.child(parent, name);
    await client.request(
      'MKCOL',
      root.uri(id, directory: true),
      username: c.field('username'),
      password: password(c),
      codes: const {201},
    );
    return CloudFile(id: id, name: name, parentId: parent, isDirectory: true);
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    final root = location(s, c), id = root.child(parent, source.name);
    onProgress?.call(UploadProgress(UploadPhase.preparing, 0, source.size));
    await client.request(
      'PUT',
      root.uri(id),
      username: c.field('username'),
      password: password(c),
      data: () => source.openRead(),
      length: source.size,
      headers: const {'If-None-Match': '*'},
      codes: const {201, 204},
      onProgress: (sent, _) => onProgress?.call(
        UploadProgress(
          UploadPhase.uploading,
          sent.clamp(0, source.size),
          source.size,
        ),
      ),
    );
    await WriteRequestScope.current?.acceptedId(id);
    onProgress?.call(
      UploadProgress(UploadPhase.finishing, source.size, source.size),
    );
    final saved = (await list(
      s,
      parent,
      c,
    )).where((f) => f.id == id && !f.isDirectory).firstOrNull;
    require(
      saved != null && saved.size == source.size,
      'WebDAV 上传已发送，目录确认失败，请刷新后核对文件',
    );
    return saved!;
  }

  Future<void> _move(
    BrowseSession s,
    CloudFile f,
    String target,
    Credential c,
  ) async {
    final root = location(s, c);
    require(
      f.id != '/' &&
          (target != f.id) &&
          (!f.isDirectory || !target.startsWith('${f.id}/')),
      '不能把文件夹移入自身',
    );
    await client.request(
      'MOVE',
      root.uri(f.id, directory: f.isDirectory),
      username: c.field('username'),
      password: password(c),
      headers: {
        'Destination': root.uri(target, directory: f.isDirectory).toString(),
        'Overwrite': 'F',
      },
      codes: const {201, 204},
    );
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) => _move(s, f, location(s, c).child(f.parentId, name), c);
  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    for (final f in files) {
      await _move(s, f, location(s, c).child(target, f.name), c);
    }
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    final root = location(s, c);
    for (final f in files) {
      require(f.id != '/', '不能删除 WebDAV 根目录');
      await client.request(
        'DELETE',
        root.uri(f.id, directory: f.isDirectory),
        username: c.field('username'),
        password: password(c),
        codes: const {200, 202, 204, 404},
      );
    }
  }

  Future<void> close() async {
    _passwords.clear();
    _connecting.clear();
    await _relay.close();
    client.close();
  }
}
