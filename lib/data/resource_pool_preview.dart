import 'dart:convert';
import '../core/json.dart';
import '../core/operation_progress.dart';
import '../domain/baidu_share_route.dart';
import '../domain/models.dart';
import '../domain/resource_search.dart';
import 'cloud_repository.dart';
import 'http.dart';
import 'resource_search_api.dart';

class PoolPreviewTarget {
  const PoolPreviewTarget(
    this.session,
    this.file,
    this.siblings,
    this.parentId,
  );
  final BrowseSession session;
  final CloudFile file;
  final List<CloudFile> siblings;
  final String parentId;
}

/// Lives only with a searched share's browser. Listing folders never redeems
/// the grant; the preview route calls resolve when the user selects a file.
class ResourcePoolPreview {
  ResourcePoolPreview({
    required this.source,
    required this.api,
    required this.cloud,
    this.clock = DateTime.now,
  });
  final ResourceSearchHit source;
  final ResourceSearchApi api;
  final CloudRepository cloud;
  final DateTime Function() clock;
  int? _accountRevision;
  final _files =
      <
        String,
        ({PoolPreviewTarget target, DateTime openedAt, String shareUrl})
      >{};

  Future<PoolPreviewTarget> resolve(
    BrowseSession original,
    CloudFile file,
    List<String> folders,
    RequestScope scope, {
    String? sourceParentId,
  }) => scope.run(() async {
    require(
      original.mode == BrowseMode.share && !file.isDirectory,
      '请从分享文件列表中打开文件',
    );
    require(folders.length <= 64, '文件目录层级过深，请使用原分享打开');
    final sourceParent =
        sourceParentId ?? (folders.isEmpty ? original.rootId : file.parentId);
    require(folders.isEmpty || sourceParent.isNotEmpty, '文件目录信息缺失，请刷新列表');
    final selection = ResourceSearchFileSelection(
      fileId: file.id,
      // A root entry may expose the owner's private parent in its metadata.
      // Prefer the actual browser trail, which is scoped to this share.
      parentId: sourceParent,
      name: file.name,
      size: file.size,
    );
    final key = jsonEncode(selection.toJson());
    final revision = cloud.sessionCredential(original)?.updatedAt;
    void checkpoint() {
      require(!scope.token.isCancelled, '预览已取消');
      require(
        cloud.sessionCredential(original)?.updatedAt == revision,
        '账号已变化，请重新打开文件列表',
      );
    }

    return RequestScope.guarded(() async {
      checkpoint();
      if (_accountRevision != revision) _files.clear();
      _accountRevision = revision;
      _files.removeWhere(
        (_, entry) =>
            clock().difference(entry.openedAt) >= const Duration(minutes: 10),
      );
      final result = await OperationProgress.step(
        OperationStage.transfer,
        () => RequestScope.cancellable(
          api.open(source, scope.token, selection: selection),
        ),
      );
      checkpoint();
      if (!result.transferred &&
          result.mode == 'original' &&
          {
            'policy_disabled',
            'policy_probability',
            'backend_unavailable',
            'insufficient_space',
            'no_account',
          }.contains(result.reason)) {
        // Keep the current account/public-parser session and selected file when
        // the pool cannot store it. This creates no new share or cleanup task.
        return PoolPreviewTarget(original, file, [file], sourceParent);
      }
      require(result.transferred, result.message.ifEmpty('暂时未能生成新的分享链接'));
      require(
        result.transferScope == 'file' &&
            result.sourceFileId == selection.fileId,
        '转存服务未确认单文件范围，请更新服务端后重试',
      );
      final cached = _files[key];
      if (cached != null && cached.shareUrl == result.hit.url) {
        return cached.target;
      }
      final link = result.hit.link;
      require(
        link?.kind == LinkKind.cloudShare &&
            link?.platform == original.platform,
        '转存后的分享类型发生变化，请使用原分享打开',
      );
      final target = await cloud.share(
        link!,
        baiduRoute: BaiduShareRoute.fromSession(original),
        parserSiteId: original.meta('parserSiteId').isEmpty
            ? null
            : original.meta('parserSiteId'),
        parserPasswordGrant: original.meta('parserPasswordGrant'),
      );
      checkpoint();
      // The new share exposes just the selected file at its root, even when the
      // original file was nested. A larger share is rejected instead of searched.
      final parent = target.rootId;
      final siblings = await cloud.list(target, parent);
      checkpoint();
      require(
        siblings.length == 1 && !siblings.single.isDirectory,
        '新分享不是单文件分享，已停止预览，请重试',
      );
      final matches = siblings
          .where(
            (candidate) =>
                !candidate.isDirectory &&
                (file.size <= 0 ||
                    candidate.size <= 0 ||
                    file.size == candidate.size) &&
                (file.hashType == null ||
                    file.hashValue?.isNotEmpty != true ||
                    candidate.hashType != file.hashType ||
                    candidate.hashValue?.isNotEmpty != true ||
                    candidate.hashValue == file.hashValue),
          )
          .toList();
      require(matches.length == 1, '新分享中无法唯一定位“${file.name}”，请重试');
      checkpoint();
      final mapped = PoolPreviewTarget(
        target,
        matches.single,
        siblings,
        parent,
      );
      if (_files.length >= 64) _files.remove(_files.keys.first);
      _files[key] = (
        target: mapped,
        openedAt: clock(),
        shareUrl: result.hit.url,
      );
      return mapped;
    }, checkpoint);
  });
}
