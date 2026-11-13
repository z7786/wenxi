import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';

import '../../core/json.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../uploads/upload_io.dart';
import '../../core/operation_progress.dart';

part 'uploads/quark_upload.dart';

class QuarkUcCapacityExceeded extends AppException {
  const QuarkUcCapacityExceeded([
    super.message = '网盘空间不足，可尝试打开实用性功能的突破文件大小限制再试',
  ]);
}

/// Related protocols share mapping code; UC session and transfer parameters stay explicit.
class QuarkUcConnector extends CloudConnector {
  QuarkUcConnector(
    this.platform,
    this.http, {
    this.stageCleanup,
    this.taskDelay = const Duration(milliseconds: 750),
  }) {
    assert(platform == CloudPlatform.quark || platform == CloudPlatform.uc);
  }
  @override
  final CloudPlatform platform;
  final JsonHttp http;
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  final Duration taskDelay;
  final _temporaryRootGate = AsyncGate();
  bool get quark => platform == CloudPlatform.quark;
  static String _md5(Object? value) {
    // The UC endpoint has returned plain, quoted and labelled digests.  Treat
    // provider markers such as 0/null as "no checksum" instead of rejecting
    // an otherwise valid download; only a clearly delimited 32-hex digest is
    // safe to pass to the downloader for verification.
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty ||
        {'0', 'null', 'none', 'undefined'}.contains(raw.toLowerCase())) {
      return '';
    }
    final match = RegExp(
      r'(?:^|[^0-9a-f])([0-9a-f]{32})(?:[^0-9a-f]|$)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match != null) return match.group(1)!.toLowerCase();
    // Some UC files (observed on share-transferred APKs) report the digest as
    // a 24-character Base64 string encoding the 16 digest bytes, which decodes
    // to the verified whole-file MD5.  Accept that form and normalize to hex.
    final base64Candidate = RegExp(
      r'^[A-Za-z0-9+/]{22}={0,2}$',
    ).firstMatch(raw);
    if (base64Candidate != null) {
      try {
        final bytes = base64.decode(raw);
        if (bytes.length == 16) {
          return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        }
      } on FormatException {
        /* Not Base64 after all; fall through to no checksum. */
      }
    }
    return '';
  }

  static bool _noMd5(Object? value) {
    final raw = value?.toString().trim().toLowerCase() ?? '';
    return raw.isEmpty ||
        {'0', 'null', 'none', 'undefined', '-', 'n/a', 'na'}.contains(raw);
  }

  String get base =>
      quark ? 'https://drive-pc.quark.cn' : 'https://pc-api.uc.cn';
  String get origin => quark ? 'https://pan.quark.cn' : 'https://drive.uc.cn';
  String get product => quark ? 'ucpro' : 'UCBrowser';
  String get ua =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ${quark ? 'Chrome/130.0.0.0 Safari/537.36 quark-cloud-drive/2.5.20' : 'Chrome/120.0.0.0 Safari/537.36'}';
  Map<String, String> headers(String cookie, {bool transfer = false}) => {
    'Cookie': cookie,
    'User-Agent': ua,
    'Origin': transfer ? 'https://fast.uc.cn' : origin,
    'Referer': '${transfer ? 'https://fast.uc.cn' : origin}/',
    'Content-Type': 'application/json;charset=UTF-8',
  };
  String url(String path, [Map<String, Object?> extra = const {}]) =>
      query('$base/1/clouddrive/$path', {'pr': product, 'fr': 'pc', ...extra});

  AppException providerError(String message, String fallback, {int? code}) {
    if (code == 32003 ||
        RegExp(
          r'^capacity\s+limit\b',
          caseSensitive: false,
        ).hasMatch(message.trim())) {
      return const QuarkUcCapacityExceeded();
    }
    return AppException(message.ifEmpty(fallback));
  }

  Json success(HttpResult result) {
    final j = result.json;
    if (!result.successful ||
        j.integer('status', j.integer('code') == 0 ? 200 : -1) != 200) {
      throw providerError(
        j.str('message'),
        '${platform.shortName}请求失败（HTTP ${result.status}）',
        code: j.integer('code'),
      );
    }
    return j['data'] is Map ? j.obj('data') : {'data': j['data']};
  }

  Future<Json> post(
    String path,
    Json body,
    String cookie, [
    Map<String, Object?> extra = const {},
  ]) async => success(
    await (path == 'file/download' ? http.postJsonRead : http.postJson)(
      url(path, extra),
      body,
      headers(cookie),
    ),
  );
  void personal(BrowseSession s) =>
      require(s.mode == BrowseMode.personal, '请在个人网盘中执行此操作');

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) => _upload(s, parent, source, c, onProgress);
  @override
  Future<CloudAccount> account(Credential credential) async {
    final data = success(
      await http.get(
        url('member', {'fetch_subscribe': true, '_ch': 'home'}),
        headers(credential.primary),
      ),
    );
    return CloudAccount(
      data
          .str('nickname')
          .ifEmpty(quark ? data.str('username').ifEmpty('夸克用户') : 'UC 用户'),
      used: data.integer('use_capacity'),
      total: data.integer('total_capacity'),
    );
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    require(link.shareId?.isNotEmpty == true, '分享链接缺少分享 ID');
    final cookie = credential?.primary ?? '';
    final data = await post('share/sharepage/token', {
      'pwd_id': link.shareId,
      'passcode': link.passcode ?? '',
      if (quark)
        'support_visit_limit_private_share': true
      else
        'share_for_transfer': true,
    }, cookie);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: data.str('title').ifEmpty('${platform.shortName}分享'),
      rootId: data.str('first_fid').ifEmpty(quark ? '' : '0'),
      metadata: {
        'shareId': link.shareId!,
        'stoken': data.str('stoken'),
        'cookie': cookie,
        'passcode': link.passcode ?? '',
      },
      sourceLink: link,
    );
  }

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    await account(credential);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的${platform.label}',
      rootId: '0',
      metadata: {'cookie': credential.primary},
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    final cookie = (credential?.primary ?? '').ifEmpty(session.meta('cookie'));
    final share = session.mode == BrowseMode.share;
    final pageSize = quark ? 100 : 50;
    final result = <CloudFile>[];
    final seen = <String>{};
    for (var page = 1; page <= 100; page++) {
      final path = share
          ? quark
                ? 'share/sharepage/detail'
                : 'transfer_share/detail'
          : 'file/sort';
      final data = success(
        await http.get(
          url(path, {
            if (share) 'pwd_id': session.meta('shareId'),
            if (share) 'stoken': session.meta('stoken'),
            'pdir_fid': parentId,
            if (share && quark) 'ver': 2,
            if (share && !quark) ...{
              'entry': 'ft',
              'fetch_file_list': 1,
              'passcode': '',
              '_fetch_task': 1,
              '_fetch_share': 1,
            },
            '_page': page,
            '_size': pageSize,
            '_fetch_total': 1,
            '_sort': share
                ? quark
                      ? 'file_type:asc,file_name:asc'
                      : ''
                : 'file_type:asc,updated_at:desc',
          }),
          headers(cookie, transfer: share && !quark),
        ),
      );
      final rawBatch = data['list'] ?? data.obj('detail_info')['list'];
      require(rawBatch is List, '${platform.shortName}文件列表响应不完整，请刷新重试');
      final batch = objects(rawBatch);
      var added = 0;
      for (final j in batch) {
        require(j.str('fid').isNotEmpty, '${platform.shortName}文件标识缺失，请刷新列表');
        if (!seen.add(j.str('fid'))) continue;
        added++;
        final checksum = quark ? '' : _md5(j.str('md5'));
        result.add(
          CloudFile(
            id: j.str('fid'),
            name: j.str('file_name').ifEmpty(j.str('fname')),
            size: j.integer('size', j.integer('fsize')),
            isDirectory: j.boolean(
              'dir',
              j.integer('dir') == 1 || j.integer('isdir') == 1,
            ),
            // Share roots can differ from the owner's physical directory.
            parentId: share ? parentId : j.str('pdir_fid').ifEmpty(parentId),
            token: j.str(share ? 'share_fid_token' : 'fid_token'),
            modifiedAt: j.str('updated_at').ifEmpty(j.str('modify_time')),
            thumbnailUrl: j.str('thumbnail'),
            hashType: checksum.isEmpty ? null : 'md5',
            hashValue: checksum.isEmpty ? null : checksum,
          ),
        );
      }
      if (batch.length < pageSize || added == 0) break;
      require(page < 100, '目录文件过多，请缩小范围后重试');
    }
    return result;
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) => prepareFile(session, file, credential);

  /// Own the share-transfer directory across either source authorization route.
  Future<DownloadSpec> prepareFile(
    BrowseSession session,
    CloudFile file,
    Credential? credential, {
    bool forPlayback = false,
    Future<DownloadSpec> Function(String fid)? resolveStream,
  }) async {
    RequestScope.checkpoint();
    require(!file.isDirectory, '文件夹不能直接下载');
    final cookie = (credential?.primary ?? '').ifEmpty(session.meta('cookie'));
    DownloadCleanup? cleanup;
    try {
      var fid = file.id;
      if (session.mode == BrowseMode.share) {
        require(credential != null, '${platform.shortName}分享下载需要登录账号');
        final root = BrowseSession(
          platform: platform,
          mode: BrowseMode.personal,
          title: '',
          rootId: '0',
          metadata: {'cookie': cookie},
        );
        final directory = await OperationProgress.step(
          OperationStage.createTemporary,
          () async {
            final baseId = await RequestScope.cancellable(
              _temporaryRootGate.run(() async {
                RequestScope.checkpoint();
                final items = await list(root, '0', credential);
                final existing = items
                    .where((f) => f.isDirectory && f.name == '文析助手临时转存')
                    .firstOrNull;
                return existing?.id ?? await _folder('0', '文析助手临时转存', cookie);
              }),
            );
            RequestScope.checkpoint();
            return _folder(
              baseId,
              'tr_${DateTime.now().millisecondsSinceEpoch}_${newId().substring(0, 8)}',
              cookie,
            );
          },
        );
        cleanup = DownloadCleanup(
          url: url('file/delete', {'uc_param_str': ''}),
          body: encoded({
            'action_type': 2,
            'filelist': [directory],
            'exclude_fids': [],
          }),
          headers: headers(cookie),
        );
        await stageCleanup?.call(cleanup);
        final ids = await OperationProgress.step(
          OperationStage.transfer,
          () => saveSharedFiles(session, [file], directory, cookie),
        );
        require(ids.isNotEmpty, '${platform.shortName}转存完成但未返回新文件 ID');
        require(
          !(forPlayback || resolveStream != null) || ids.length == 1,
          '${platform.shortName}单文件转存结果不明确，请重新打开分享列表',
        );
        fid = ids.first;
      }
      RequestScope.checkpoint();
      if (resolveStream != null) {
        final stream = await OperationProgress.step(
          forPlayback
              ? OperationStage.playbackLink
              : OperationStage.downloadLink,
          () => resolveStream(fid),
        );
        return stream.copyWith(cleanup: cleanup);
      }
      return await OperationProgress.step(
        forPlayback ? OperationStage.playbackLink : OperationStage.downloadLink,
        () async {
          final data = await resolveFile(
            fid,
            file.name,
            cookie,
            forPlayback: forPlayback,
          );
          final items = data['data'] is List
              ? data.list('data')
              : [data['data'] is Map ? data.obj('data') : data];
          final matches = items
              .where((item) => item.str('fid') == fid)
              .toList();
          require(
            matches.length == 1 ||
                matches.isEmpty &&
                    items.length == 1 &&
                    items.single.str('fid').isEmpty,
            '${platform.shortName} 返回的下载文件与所选文件不一致，请刷新列表后重试',
          );
          final item = matches.isEmpty ? items.single : matches.single;
          final direct = item.str('download_url').ifEmpty(item.str('url'));
          require(direct.isNotEmpty, '${platform.shortName}没有返回可用下载链接');
          // Quark's download md5 did not match the complete PDF bytes in a live
          // check. Keep any independently supplied checksum; do not treat that API
          // field as a whole-file digest. UC's digest is verified separately below.
          final rawMd5 = item['md5'];
          final checksum = quark ? '' : _md5(rawMd5);
          require(
            quark || _noMd5(rawMd5) || checksum.isNotEmpty,
            '${platform.shortName} 返回的文件校验值无效，请重试',
          );
          require(
            file.hashType?.toLowerCase() != 'md5' ||
                file.hashValue?.isNotEmpty != true ||
                checksum.isEmpty ||
                file.hashValue!.toLowerCase() == checksum,
            '${platform.shortName} 返回的文件校验值与所选文件不一致，请刷新列表后重试',
          );
          return DownloadSpec(
            url: direct,
            fileName: item.str('file_name').ifEmpty(file.name),
            expectedSize: item.integer('size', file.size),
            checksumType: checksum.isEmpty ? file.hashType : 'md5',
            checksumValue: checksum.isEmpty ? file.hashValue : checksum,
            headers: headers(cookie),
            cleanup: cleanup,
          );
        },
      );
    } catch (_) {
      final pending = cleanup;
      if (pending != null) {
        try {
          await OperationProgress.step(OperationStage.cleanup, () async {
            success(
              await http.postJson(pending.url, pending.body, pending.headers),
            );
          });
        } catch (_) {
          /* Persisted cleanup is retried at the next safe opportunity. */
        }
      }
      rethrow;
    }
  }

  Future<Json> resolveFile(
    String fid,
    String name,
    String cookie, {
    bool forPlayback = false,
  }) => post(
    'file/download',
    {
      'fids': [fid],
    },
    cookie,
    {'sys': 'win32', 've': quark ? '3.23.2' : '1.6.1'},
  );

  Future<String> _folder(String parent, String name, String cookie) async {
    final data = await post('file', {
      'pdir_fid': parent,
      'file_name': name,
      'dir_path': '',
      'dir_init_lock': false,
    }, cookie);
    require(data.str('fid').isNotEmpty, '${platform.shortName}创建目录失败');
    return data.str('fid');
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    personal(s);
    return CloudFile(
      id: await _folder(parent, name, c.primary),
      name: name,
      isDirectory: true,
      parentId: parent,
    );
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    personal(s);
    final result = await post('file/rename', {
      'fid': f.id,
      'file_name': name,
    }, c.primary);
    await _finishMutation(result, c.primary);
    await _awaitVisible(
      s,
      f.parentId.ifEmpty(s.rootId),
      c,
      (items) => items.any((item) => item.id == f.id && item.name == name),
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
    final result = await post('file/move', {
      'action_type': 1,
      'to_pdir_fid': target,
      'filelist': files.map((f) => f.id).toList(),
      'exclude_fids': [],
    }, c.primary);
    await _finishMutation(result, c.primary);
    final ids = files.map((file) => file.id).toSet();
    await _awaitVisible(
      s,
      target,
      c,
      (items) => items.map((item) => item.id).toSet().containsAll(ids),
    );
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    final result = await post('file/delete', {
      'action_type': 2,
      'filelist': files.map((f) => f.id).toList(),
      'exclude_fids': [],
    }, c.primary);
    await _finishMutation(result, c.primary);
  }

  Future<void> _finishMutation(Json result, String cookie) async {
    final task = result.str('task_id');
    if (task.isNotEmpty && !result.boolean('finish')) await _poll(task, cookie);
  }

  Future<void> _awaitVisible(
    BrowseSession session,
    String parent,
    Credential credential,
    bool Function(List<CloudFile>) visible,
  ) async {
    // The task may finish before the directory index catches up. Confirm only
    // the requested result; do not repeat the mutation if indexing is delayed.
    for (var attempt = 0; attempt < 8; attempt++) {
      RequestScope.checkpoint();
      if (visible(await list(session, parent, credential))) return;
      if (attempt < 7) await Future<void>.delayed(taskDelay);
    }
    throw AppException('${platform.shortName} 已受理操作，列表尚未更新，请稍后刷新确认');
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请打开分享链接');
    final ids = await saveSharedFiles(s, files, target, c.primary);
    require(ids.isNotEmpty, '${platform.shortName}转存完成但未返回新文件 ID');
  }

  /// Shared by explicit saves and temporary download/playback transfers.
  Future<List<String>> saveSharedFiles(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    String cookie,
  ) async {
    require(files.isNotEmpty, '请选择要转存的文件');
    require(
      s.meta('shareId').isNotEmpty &&
          s.meta('stoken').isNotEmpty &&
          files.every((file) => file.id.isNotEmpty && file.token.isNotEmpty),
      '${platform.shortName}分享凭证缺失，请重新打开分享列表',
    );
    final data = await post('share/sharepage/save', {
      'pwd_id': s.meta('shareId'),
      'stoken': s.meta('stoken'),
      'pdir_fid': files.firstOrNull?.parentId ?? '',
      'to_pdir_fid': target,
      'fid_list': files.map((f) => f.id).toList(),
      'fid_token_list': files.map((f) => f.token).toList(),
      'scene': 'link',
    }, cookie);
    require(data.str('task_id').isNotEmpty, '${platform.shortName}转存未返回任务 ID');
    final task = await _poll(data.str('task_id'), cookie);
    return (task.obj('save_as')['save_as_top_fids'] as List? ?? [])
        .map((e) => '$e')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    personal(s);
    final passcode = options.passcode ?? '';
    final data = await post('share', {
      'fid_list': files.map((f) => f.id).toList(),
      'title': options.title.ifEmpty(files.firstOrNull?.name ?? '分享文件'),
      'url_type': passcode.isEmpty ? 1 : 2,
      'expired_type': switch (options.expiryDays) {
        1 => 2,
        7 => 3,
        30 => 4,
        _ => 1,
      },
      if (quark) 'support_error_code': ['41060'] else 'public_search': false,
      if (passcode.isNotEmpty) 'passcode': passcode,
    }, c.primary);
    require(data.str('task_id').isNotEmpty, '创建分享未返回任务 ID');
    final id = (await _poll(data.str('task_id'), c.primary)).str('share_id');
    require(id.isNotEmpty, '创建分享完成但未返回分享 ID');
    final info = await post('share/password', {'share_id': id}, c.primary);
    return ShareCreation(
      info.str('share_url').ifEmpty('$origin/s/$id'),
      info.str('passcode').ifEmpty(passcode),
      options.title,
    );
  }

  Future<Json> _poll(String taskId, String cookie) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final data = success(
        await http.get(
          url('task', {'task_id': taskId, 'retry_index': 0}),
          headers(cookie),
        ),
      );
      if ({3, 4}.contains(data.integer('status')) ||
          {3, 4}.contains(data.integer('task_status'))) {
        throw providerError(
          data.str('message'),
          '${platform.shortName}异步任务失败',
          code: data.integer('code'),
        );
      }
      if (data.integer('finished_at') > 0 ||
          data.integer('status') == 2 ||
          data.integer('task_status') == 2) {
        return data;
      }
      await Future<void>.delayed(taskDelay);
    }
    throw AppException('${platform.shortName}异步任务超时');
  }
}
