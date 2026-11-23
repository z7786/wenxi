import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:xml/xml.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../domain/models.dart';
import '../download/transfer_http.dart';
import '../upload/upload_manager.dart';
import '../upload/upload_task.dart';
import 'classified_backup.dart';
import 'cleanup_outbox.dart';
import 'cloud_repository.dart';
import 'http.dart';
import 'state_store.dart';

class BackupRemoteFile {
  const BackupRemoteFile(this.name, this.size, {this.cloudFile});
  final String name;
  final int size;
  final CloudFile? cloudFile;
}

abstract class BackupTarget {
  Future<List<BackupRemoteFile>> list();
  Future<Uint8List> read(BackupRemoteFile file, {int limit = backupSizeLimit});
  Future<void> write(String name, Uint8List bytes);
  Future<void> repairIncomplete(String name, Uint8List bytes) =>
      Future.error(const AppException('远端未完成文件已损坏，请放弃此版本并创建新备份'));
  void close() {}
}

bool isBackupName(String name) =>
    RegExp(r'^asterlink-backup-[a-zA-Z0-9_-]+\.json$').hasMatch(name);

/// No redirects carry WebDAV credentials. All reads are streamed and bounded.
class WebDavBackupTarget extends BackupTarget {
  WebDavBackupTarget({
    required String url,
    required this.username,
    required this.password,
    Dio? client,
  }) : base = Uri.parse(url.endsWith('/') ? url : '$url/'),
       dio = client ?? DioJsonHttp().dio {
    require(
      {'https', 'http'}.contains(base.scheme) &&
          base.host.isNotEmpty &&
          base.userInfo.isEmpty &&
          !base.hasQuery &&
          !base.hasFragment,
      '请输入完整 WebDAV 目录地址，不含账号、查询参数或片段',
    );
  }
  final Uri base;
  final String username, password;
  final Dio dio;
  Uri _uri(String name) {
    require(
      name.isNotEmpty &&
          !name.contains('/') &&
          !name.contains('\\') &&
          name != '.' &&
          name != '..',
      '备份文件名无效',
    );
    return base.resolve(Uri.encodeComponent(name));
  }

  Future<Uint8List> _request(
    String method,
    Uri uri, {
    Uint8List? data,
    Map<String, String> headers = const {},
    int limit = backupSizeLimit,
    Set<int>? codes,
  }) async {
    RequestScope.checkpoint();
    final cancel = CancelToken(), parent = RequestScope.current;
    var finished = false;
    parent?.whenCancel.then((_) {
      if (!finished) cancel.cancel();
    });
    try {
      final response = await dio.request<ResponseBody>(
        uri.toString(),
        data: data == null ? null : Stream.value(data),
        cancelToken: cancel,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Authorization':
                'Basic ${base64Encode(utf8.encode('$username:$password'))}',
            if (data != null) 'Content-Length': '${data.length}',
            'Content-Type': method == 'PROPFIND'
                ? 'application/xml; charset=utf-8'
                : 'application/octet-stream',
            ...headers,
          },
        ),
      );
      final code = response.statusCode ?? 0;
      if (!(codes?.contains(code) ?? (code >= 200 && code < 300))) {
        throw AppException(switch (code) {
          401 => 'WebDAV 账号或密码错误',
          403 => 'WebDAV 目录权限不足',
          404 => 'WebDAV 目录或文件不存在',
          507 => 'WebDAV 存储空间不足',
          >= 300 && < 400 => 'WebDAV 地址发生重定向，请填写最终目录地址',
          _ => 'WebDAV 请求失败（$code），请稍后重试',
        });
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        RequestScope.checkpoint();
        require(bytes.length + chunk.length <= limit, 'WebDAV 返回内容过大');
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      finished = true;
      cancel.cancel();
    }
  }

  @override
  Future<List<BackupRemoteFile>> list() async {
    final bytes = await _request(
      'PROPFIND',
      base,
      headers: {'Depth': '1'},
      data: Uint8List.fromList(
        utf8.encode(
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>',
        ),
      ),
      limit: 2 * 1024 * 1024,
      codes: {207},
    );
    final xml = utf8.decode(bytes);
    require(
      !RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(xml),
      'WebDAV 目录响应不受支持',
    );
    final document = XmlDocument.parse(xml);
    final files = <BackupRemoteFile>[];
    for (final response in document.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'response',
    )) {
      final elements = response.descendants.whereType<XmlElement>().toList();
      if (elements.any((e) => e.name.local == 'collection')) continue;
      final href = elements
          .where((e) => e.name.local == 'href')
          .firstOrNull
          ?.innerText;
      if (href == null) continue;
      final uri = base.resolve(href);
      if (uri.origin != base.origin || uri.hasQuery || uri.hasFragment) {
        continue;
      }
      final parent = base.pathSegments.where((s) => s.isNotEmpty).toList();
      final segments = uri.pathSegments;
      if (segments.length != parent.length + 1 ||
          List.generate(
            parent.length,
            (i) => segments[i] == parent[i],
          ).contains(false)) {
        continue;
      }
      final name = segments.last;
      if (!isBackupName(name) &&
          !name.endsWith('.complete') &&
          !name.startsWith('.asterlink-test-') &&
          !name.endsWith('.json')) {
        continue;
      }
      final size =
          int.tryParse(
            elements
                    .where((e) => e.name.local == 'getcontentlength')
                    .firstOrNull
                    ?.innerText ??
                '',
          ) ??
          0;
      files.add(BackupRemoteFile(name, size));
      require(files.length <= 10000, '此目录文件过多，请使用单独的备份目录');
    }
    return files;
  }

  @override
  Future<Uint8List> read(BackupRemoteFile file, {int limit = backupSizeLimit}) {
    require(file.size <= limit, '备份文件过大');
    return _request('GET', _uri(file.name), limit: limit);
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    await _request(
      'PUT',
      _uri(name),
      data: bytes,
      headers: {'If-None-Match': '*'},
      limit: 64 * 1024,
    );
  }

  @override
  Future<void> repairIncomplete(String name, Uint8List bytes) async {
    require(isBackupName(name), '只能重传本次未完成的备份包');
    require(
      !(await list()).any((f) => f.name == '$name.complete'),
      '该备份已经发布，不能覆盖',
    );
    // Generic WebDAV may leave a truncated object after a cancelled PUT.
    // Only a locally staged UUID snapshot without a completion marker is retried.
    await _request('PUT', _uri(name), data: bytes, limit: 64 * 1024);
  }

  Future<void> test() async {
    await list();
    final name = '.asterlink-test-${newId()}.json';
    final bytes = Uint8List.fromList(utf8.encode(newId()));
    var attempted = false;
    try {
      attempted = true;
      await write(name, bytes);
      require(
        sha256.convert(await read(BackupRemoteFile(name, bytes.length))) ==
            sha256.convert(bytes),
        'WebDAV 回读内容不一致',
      );
    } finally {
      if (attempted) {
        // Cleanup owns its scope even if the capability test was cancelled.
        await RequestScope().run(() async {
          await _request(
            'DELETE',
            _uri(name),
            limit: 64 * 1024,
            codes: {200, 202, 204, 404},
          );
        }, inheritGuard: false);
      }
    }
  }

  @override
  void close() => dio.close(force: true);
}

class CloudBackupTarget extends BackupTarget {
  CloudBackupTarget({
    required this.cloud,
    required this.uploads,
    required this.http,
    required this.cleanups,
    required this.directory,
    required this.session,
    required this.parent,
  });
  final CloudRepository cloud;
  final UploadManager uploads;
  final TransferHttp http;
  final CleanupOutbox cleanups;
  final Directory directory;
  final BrowseSession session;
  final String parent;

  @override
  Future<List<BackupRemoteFile>> list() async {
    final files = <String, BackupRemoteFile>{}, cursors = <String>{};
    String? cursor;
    do {
      final page = await cloud.listPage(session, parent, cursor: cursor);
      for (final file in page.files) {
        if (!file.isDirectory) {
          files[file.id] = BackupRemoteFile(
            file.name,
            file.size,
            cloudFile: file,
          );
        }
      }
      cursor = page.nextCursor;
      require(
        files.length <= 10000 && (cursor == null || cursors.add(cursor)),
        '备份目录分页异常或文件过多',
      );
    } while (cursor != null);
    return files.values.toList();
  }

  @override
  Future<Uint8List> read(
    BackupRemoteFile file, {
    int limit = backupSizeLimit,
  }) async {
    require(file.size <= limit, '备份文件过大');
    final resolved =
        file.cloudFile ??
        (await list()).where((f) => f.name == file.name).firstOrNull?.cloudFile;
    require(resolved != null, '备份文件不存在，请刷新列表');
    final spec = await cloud.prepareTransfer(session, resolved!);
    try {
      return await http.limited(spec.url, spec.headers, limit);
    } finally {
      await cleanups.release(spec.cleanup);
      await cleanups.ready(spec.cleanup);
    }
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    require(
      isBackupName(name) ||
          isBackupName(name.replaceFirst(RegExp(r'\.complete$'), '')),
      '备份文件名无效',
    );
    require(
      cloud.connector(session.platform).canUploadTo(session, parent),
      '当前网盘目录不支持上传',
    );
    await directory.create(recursive: true);
    final file = File(p.join(p.normalize(directory.path), name));
    // An interrupted task always reuses its original immutable payload.
    if (await file.exists()) {
      require(
        sha256.convert(await file.readAsBytes()) == sha256.convert(bytes),
        '暂存备份内容已变化',
      );
    } else {
      await file.writeAsBytes(bytes, flush: true);
    }
    await uploads.initialize();
    var task = uploads.tasks
        .where(
          (t) =>
              t.path == file.path &&
              t.parent == parent &&
              t.session.platform == session.platform &&
              t.session.accountId == session.accountId &&
              t.session.familyId == session.familyId &&
              t.session.personalSpaceId == session.personalSpaceId,
        )
        .firstOrNull;
    if (task == null) {
      final ids = await uploads.enqueue(session, parent, '应用备份', [
        XFile(file.path),
      ]);
      task = uploads.task(ids.single)!;
    } else if (task.canRetry) {
      await uploads.retry(task.id);
    }
    try {
      while (task!.active) {
        await RequestScope.wait(const Duration(milliseconds: 250));
        task = uploads.task(task.id);
        require(task != null, '备份上传任务已移除，可重新继续备份');
      }
      require(
        task.status == UploadStatus.completed,
        task.error.ifEmpty('备份上传未完成，可在备份页继续'),
      );
    } catch (_) {
      if (RequestScope.current?.isCancelled == true && task?.active == true) {
        await uploads.cancel(task!.id);
      }
      rethrow;
    }
  }
}

/// Unique snapshots + readback + completion marker; never overwrite old versions.
/// Staging survives process death so a retry uses the same name and ciphertext.
class BackupTransfers {
  BackupTransfers(this.store, this.directory);
  final StateStore store;
  final Directory directory;
  static final _gates = Expando<AsyncGate>('backup.transfers');
  AsyncGate get _gate => _gates[store] ??= AsyncGate();
  List<Json> get pending => store.data.list('backupTransfers');

  Future<Json> stage(Uint8List bytes, Json target) async {
    require(bytes.length <= backupSizeLimit, '备份文件过大');
    final id = newId(),
        name =
            'asterlink-backup-${DateTime.now().toUtc().millisecondsSinceEpoch}-${newId()}.json';
    await directory.create(recursive: true);
    final job = <String, dynamic>{
      'id': id,
      'name': name,
      'target': target,
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };
    await File(
      p.join(p.normalize(directory.path), name),
    ).writeAsBytes(bytes, flush: true);
    await store.change(
      (draft) =>
          draft['backupTransfers'] = [...draft.list('backupTransfers'), job],
    );
    return job;
  }

  Future<void> send(Json job, BackupTarget target) => _gate.run(() async {
    final name = job.str('name');
    require(isBackupName(name), '暂存备份文件名无效');
    final file = File(p.join(p.normalize(directory.path), name));
    require(
      await file.exists() && await file.length() <= backupSizeLimit,
      '暂存备份已丢失，请重新创建',
    );
    final bytes = await file.readAsBytes();
    require(
      bytes.length == job.integer('size') &&
          sha256.convert(bytes).toString() == job.str('sha256'),
      '暂存备份已损坏',
    );
    Future<void> publish(String objectName, Uint8List content) async {
      RequestScope.checkpoint();
      final existing = (await target.list())
          .where((f) => f.name == objectName)
          .toList();
      require(existing.length <= 1, '远端出现同名文件，请检查备份目录');
      if (existing.isEmpty) await target.write(objectName, content);
      final files = (await target.list())
          .where((f) => f.name == objectName)
          .toList();
      require(files.length == 1, '上传后暂未找到备份文件，请稍后继续验证');
      var received = await target.read(files.single, limit: backupSizeLimit);
      if (objectName == name &&
          existing.isNotEmpty &&
          (received.length != content.length ||
              sha256.convert(received) != sha256.convert(content))) {
        await target.repairIncomplete(objectName, content);
        received = await target.read(
          BackupRemoteFile(objectName, 0),
          limit: content.length,
        );
      }
      require(
        received.length == content.length &&
            sha256.convert(received) == sha256.convert(content),
        '备份回读校验失败，旧版本仍然保留',
      );
    }

    await publish(name, bytes);
    final marker = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'asterlink-backup-complete-v1',
          'name': name,
          'size': bytes.length,
          'sha256': job.str('sha256'),
        }),
      ),
    );
    await publish('$name.complete', marker);
    await store.change(
      (draft) => draft['backupTransfers'] = draft
          .list('backupTransfers')
          .where((j) => j.str('id') != job.str('id'))
          .toList(),
    );
    await file.delete();
    final markerFile = File(
      p.join(p.normalize(directory.path), '$name.complete'),
    );
    if (await markerFile.exists()) await markerFile.delete();
  });

  Future<void> discard(Json job, UploadManager uploads) => _gate.run(() async {
    final name = job.str('name');
    require(isBackupName(name), '暂存备份文件名无效');
    for (final object in [name, '$name.complete']) {
      final file = File(p.join(p.normalize(directory.path), object));
      for (final task in uploads.tasks.where(
        (t) => p.equals(t.path, file.path),
      )) {
        if (task.active) await uploads.cancel(task.id);
        await uploads.remove(task.id);
      }
      if (await file.exists()) await file.delete();
    }
    await store.change(
      (draft) => draft['backupTransfers'] = draft
          .list('backupTransfers')
          .where((j) => j.str('id') != job.str('id'))
          .toList(),
    );
  });

  Future<List<BackupRemoteFile>> versions(
    BackupTarget target, {
    bool includeUnconfirmed = false,
  }) async {
    final files = await target.list();
    final names = files.map((f) => f.name).toSet();
    final versions = files
        .where(
          (f) =>
              f.name.endsWith('.json') &&
              f.size <= backupSizeLimit &&
              (includeUnconfirmed || names.contains('${f.name}.complete')),
        )
        .toList();
    versions.sort((a, b) => b.name.compareTo(a.name));
    return versions;
  }

  Future<Uint8List> download(
    BackupTarget target,
    BackupRemoteFile file, {
    bool unconfirmed = false,
  }) async {
    final bytes = await target.read(file);
    if (!unconfirmed) {
      final marker = asJson(
        jsonDecode(
          utf8.decode(
            await target.read(
              BackupRemoteFile('${file.name}.complete', 0),
              limit: 4096,
            ),
          ),
        ),
      );
      require(
        marker.str('format') == 'asterlink-backup-complete-v1' &&
            marker.str('name') == file.name &&
            marker.integer('size') == bytes.length &&
            marker.str('sha256') == sha256.convert(bytes).toString(),
        '备份完成清单与文件不一致',
      );
    }
    return bytes;
  }
}
