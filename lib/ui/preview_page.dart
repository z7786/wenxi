import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/operation_progress.dart';
import '../data/http.dart';
import '../data/resource_pool_preview.dart';
import '../domain/models.dart';
import '../download/image_preview_loader.dart';
import '../preview/document_format.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_sources.dart';
import 'common.dart';
import 'download_location_picker.dart';
import 'baidu_download_prompt.dart';
import 'operation_progress_view.dart';
import 'player_page.dart';
import 'uc_tv_authorization_page.dart';
import 'document_download_preview.dart';

class PreviewPage extends StatefulWidget {
  const PreviewPage(
    this.services,
    this.session,
    this.file, {
    super.key,
    this.playlist = const [],
    this.parentFolders = const {},
    this.poolPreview,
    this.sourceFolders = const [],
  });
  final AppServices services;
  final BrowseSession session;
  final CloudFile file;
  final List<CloudFile> playlist;
  final Map<String, String> parentFolders;
  final ResourcePoolPreview? poolPreview;
  final List<String> sourceFolders;
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  // Keep a bounded in-memory preview, but allow photographs larger than the
  // old 25 MiB limit used by several cloud providers.
  static const _maxImagePreviewBytes = 64 * 1024 * 1024;
  final scope = RequestScope();
  final progress = OperationProgress();
  DownloadSpec? spec;
  PlaybackController? playback;
  Uint8List? image;
  bool loading = true, adding = false;
  String error = '';
  late final kind = fileKind(widget.file.name);
  late BrowseSession session = widget.session;
  late CloudFile file = widget.file;
  late List<CloudFile> playlist = widget.playlist;
  late Map<String, String> parentFolders = widget.parentFolders;
  bool preparingPool = false, poolError = false;
  PoolPreviewTarget? initialPoolTarget;
  @override
  void initState() {
    super.initState();
    if (widget.poolPreview != null) {
      _preparePool();
    } else {
      _startPreview();
    }
  }

  void _startPreview() {
    if (kind == FileKind.video || kind == FileKind.audio) {
      setState(() {
        loading = false;
        playback = cloudPlayback(
          widget.services,
          session,
          file,
          playlist,
          parentFolders: parentFolders,
          poolPreview: widget.poolPreview,
          initialPoolTarget: initialPoolTarget,
          sourceFolders: widget.sourceFolders,
        );
      });
    } else {
      _load();
    }
  }

  Future<void> _preparePool() async {
    setState(() {
      preparingPool = true;
      poolError = false;
      loading = true;
      error = '';
    });
    try {
      final target = await progress.run(
        () => widget.poolPreview!.resolve(
          widget.session,
          widget.file,
          widget.sourceFolders,
          scope,
          sourceParentId: widget.parentFolders[widget.file.id],
        ),
      );
      if (!mounted || scope.token.isCancelled) return;
      if (kind == FileKind.video || kind == FileKind.audio) {
        initialPoolTarget = target;
      } else {
        session = target.session;
        file = target.file;
        playlist = target.siblings;
        parentFolders = {
          for (final sibling in target.siblings) sibling.id: target.parentId,
        };
      }
      setState(() => preparingPool = false);
      _startPreview();
    } catch (e) {
      if (!mounted || scope.token.isCancelled) return;
      progress.close(failed: true);
      setState(() {
        preparingPool = false;
        poolError = true;
        loading = false;
        error = errorText(e);
      });
    }
  }

  Future<void> _release(DownloadSpec value) async {
    await widget.services.cleanups.release(value.cleanup);
    await widget.services.cleanups.ready(value.cleanup);
    await widget.services.cleanups.drain();
  }

  Future<void> _load() async {
    if (documentFormat(file.name) != null) {
      setState(() => loading = false);
      return;
    }
    if (kind != FileKind.image) {
      setState(() => loading = false);
      return;
    }
    try {
      final value = await scope.run(
        () => progress.run(() => widget.services.cloud.prepare(session, file)),
      );
      if (!mounted) {
        await _release(value);
        return;
      }
      spec = value;
      image = await scope.run(
        () => ImagePreviewLoader(widget.services.transfer).load(
          value,
          limit: _maxImagePreviewBytes,
          connections: widget.services.settings.connectionsFor(
            session.platform,
            value.profile,
          ),
        ),
      );
      if (mounted) setState(() => loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = errorText(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _download({bool chooseLocation = false}) async {
    if (adding || preparingPool || poolError) return;
    setState(() => adding = true);
    try {
      if (!await confirmBaiduDownload(
            context,
            widget.services,
            session.platform,
            session: session,
          ) ||
          !mounted) {
        return;
      }
      final location = await chooseDownloadLocation(
        context,
        widget.services,
        alwaysAsk: chooseLocation,
      );
      if (location == null || !mounted) return;
      var value = spec;
      if (value == null) {
        value = await widget.services.cloud.prepare(session, file);
      } else {
        widget.services.cleanups.retain(value.cleanup);
      }
      try {
        await widget.services.downloads.enqueue(value, location: location);
      } catch (_) {
        await widget.services.cleanups.release(value.cleanup);
        await widget.services.cleanups.ready(value.cleanup);
        rethrow;
      }
      if (mounted) {
        message(
          context,
          '已添加到下载队列',
          onTap: widget.services.requestDownloadManager,
        );
      }
    } on DownloadConfirmationCancelled {
      // The user declined mobile data; the prepared source was released above.
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => adding = false);
    }
  }

  @override
  void dispose() {
    scope.cancel();
    progress.dispose();
    final player = playback;
    if (player != null) {
      widget.services.finishPlaybackInBackground(player.close());
    }
    final current = spec;
    unawaited(
      () async {
        if (current != null) await _release(current);
      }().catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (playback != null) {
      final player = playback!, services = widget.services;
      final accountId = session.accountId;
      return PlayerPage(
        player,
        confirmDownload: (playerContext) => confirmBaiduDownload(
          playerContext,
          services,
          player.current.platform,
          session: player.current.source?.cloud?.session,
        ),
        onAuthorizeUcTv: session.platform == CloudPlatform.uc
            ? (playerContext) => openUcTvAuthorization(
                playerContext,
                services,
                accountId: accountId,
              )
            : null,
        subtitleDirectory: Directory(
          '${widget.services.cacheDirectory.path}/playback-subtitles',
        ),
        onDownload: (source) async {
          await enqueueDownloadFromUi(context, services, source);
        },
      );
    }
    if (!preparingPool && !poolError && documentFormat(file.name) != null) {
      return DocumentDownloadPreview(
        services: widget.services,
        session: session,
        file: file,
      );
    }
    return PageFrame(
      title: widget.file.displayName,
      actions: [
        IconButton(
          tooltip: kind == FileKind.image ? '下载文件' : '传输管理',
          onPressed: kind == FileKind.image
              ? (adding || loading || poolError ? null : _download)
              : widget.services.requestDownloadManager,
          icon: const Icon(CupertinoIcons.arrow_down_circle),
        ),
        if (supportsDownloadLocationChoice && kind == FileKind.image)
          PopupMenuButton<String>(
            tooltip: '更多',
            enabled: !adding && !loading && !poolError,
            onSelected: (_) => _download(chooseLocation: true),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'download-to', child: Text('下载到…')),
            ],
          ),
      ],
      child: Column(
        children: [
          Expanded(
            child: loading
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OperationProgressView(
                              progress: progress,
                              label: preparingPool ? '正在准备预览…' : '正在加载预览…',
                            ),
                            if (preparingPool) ...[
                              const SizedBox(height: 20),
                              TextButton(
                                key: const Key('pool-preview-cancel'),
                                onPressed: () {
                                  scope.cancel();
                                  Navigator.of(context).pop();
                                },
                                child: const Text('返回文件列表'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  )
                : poolError
                ? EmptyPanel(
                    '暂未完成资源准备',
                    error,
                    icon: CupertinoIcons.doc,
                    action: FilledButton(
                      key: const Key('pool-preview-retry'),
                      onPressed: _preparePool,
                      child: const Text('重试'),
                    ),
                  )
                : error.isNotEmpty
                ? EmptyPanel(
                    '暂时无法预览',
                    error,
                    icon: CupertinoIcons.doc,
                    action: FilledButton(
                      onPressed: adding ? null : _download,
                      child: const Text('下载文件'),
                    ),
                  )
                : image != null
                ? InteractiveViewer(
                    minScale: .5,
                    maxScale: 6,
                    child: Center(
                      // Decode very large photographs to a bounded preview
                      // size.  Keeping the compressed bytes while asking the
                      // codec for the full source dimensions can exceed the
                      // Android bitmap budget even when the download itself
                      // succeeded.
                      child: Image.memory(
                        image!,
                        fit: BoxFit.contain,
                        cacheWidth: 4096,
                        cacheHeight: 4096,
                      ),
                    ),
                  )
                : EmptyPanel(
                    widget.file.displayName,
                    '${formatBytes(widget.file.size)}\n此类型文件可下载后查看',
                    icon: CupertinoIcons.doc,
                    action: FilledButton.icon(
                      onPressed: adding ? null : _download,
                      icon: const Icon(CupertinoIcons.arrow_down, size: 17),
                      label: const Text('下载文件'),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
