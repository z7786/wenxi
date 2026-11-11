part of '../guangya.dart';

extension _GuangyaUpload on GuangyaConnector {
  Future<RapidTransferResult> _rapidTransfer(
    BrowseSession s,
    String parent,
    RapidTransferFile file,
    Credential c,
  ) async {
    _personal(s);
    cloudFileName(file.name);
    final session = await _session(c);
    final pre = await _post(
      '/nd.bizuserres.s/v1/get_res_center_token',
      {
        'capacity': 2,
        'name': file.name,
        'parentId': _parent(parent),
        'res': {'fileSize': file.size, 'md5': file.md5},
      },
      session: session,
      acceptedCodes: const {'156'},
    );
    if (pre.str('_uploadCode') != '156') {
      return const RapidTransferResult.missed();
    }
    final taskId = pre.str('taskId');
    require(taskId.isNotEmpty, '光鸭秒传回执缺少任务信息');
    for (var attempt = 0; attempt < 30; attempt++) {
      RequestScope.checkpoint();
      final result = await _post(
        '/nd.bizuserres.s/v1/file/get_info_by_task_id',
        {'taskId': taskId},
        session: session,
        read: true,
        acceptedCodes: const {'145', '146', '147', '155', '163'},
      );
      final id = result.str('fileId');
      if (id.isNotEmpty) {
        final matched = (await list(s, parent, c))
            .where(
              (f) =>
                  f.id == id &&
                  !f.isDirectory &&
                  f.name == file.name &&
                  f.size == file.size,
            )
            .toList();
        require(
          matched.length == 1 &&
              contentMd5(matched.single.hashValue) == file.md5,
          '光鸭秒传结果未能确认，请刷新目标目录',
        );
        return RapidTransferResult.reused(id);
      }
      await RequestScope.wait(const Duration(seconds: 1));
    }
    throw const RapidTransferUnavailable('光鸭仍在确认秒传结果，请稍后继续任务');
  }

  Future<CloudFile> _upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c,
    UploadProgressCallback? onProgress,
  ) async {
    _personal(s);
    cloudFileName(source.name);
    final session = await _session(c), io = UploadIO(http, source, onProgress);
    final pre = await _post(
      '/nd.bizuserres.s/v1/get_res_center_token',
      {
        'capacity': 2,
        'name': source.name,
        'parentId': _parent(parent),
        'res': {'fileSize': source.size, 'md5': await io.digest(md5)},
      },
      session: session,
      acceptedCodes: const {'156'},
    );
    final taskId = pre.str('taskId');
    require(taskId.isNotEmpty, '光鸭未创建上传任务');
    if (pre.str('_uploadCode') != '156') {
      String field(String key) =>
          pre.str(key).ifEmpty(pre.obj('creds').str(key));
      await io.oss(
        endpoint: pre.str('fullEndPoint').ifEmpty(pre.str('endPoint')),
        bucket: pre.str('bucketName'),
        object: pre.str('objectPath'),
        access: field('accessKeyID'),
        secret: field('secretAccessKey'),
        token: field('sessionToken'),
      );
    }
    io.progress(UploadPhase.finishing, source.size);
    for (var attempt = 0; attempt < 180; attempt++) {
      final result = await _post(
        '/nd.bizuserres.s/v1/file/get_info_by_task_id',
        {'taskId': taskId},
        session: session,
        read: true,
        acceptedCodes: const {'145', '146', '147', '155', '163'},
      );
      if (result.str('fileId').isNotEmpty) {
        return io.confirm(() => list(s, parent, c), id: result.str('fileId'));
      }
      await RequestScope.wait(const Duration(seconds: 1));
    }
    throw const AppException('光鸭正在校验上传内容，请稍后刷新列表');
  }
}
