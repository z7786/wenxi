import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../core/operation_progress.dart';
import '../data/http.dart';
import '../data/resource_pool_preview.dart';
import '../domain/models.dart';
import '../download/image_preview_loader.dart';
import '../preview/text_document.dart';
import '../preview/text_preview_loader.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_sources.dart';
import 'common.dart';
import 'baidu_download_prompt.dart';
import 'operation_progress_view.dart';
import 'player_page.dart';
import 'uc_tv_authorization_page.dart';
import 'text_preview.dart';
import 'login_webview.dart';

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
  TextDocument? text;
  bool loading = true, adding = false;
  String error = '';
  late final kind = fileKind(widget.file.name);
  late final office = isOfficeDocument(widget.file.name);
  late BrowseSession session = widget.session;
  late CloudFile file = widget.file;
  late List<CloudFile> playlist = widget.playlist;
  late Map<String, String> parentFolders = widget.parentFolders;
  bool preparingPool = false, poolError = false;
  bool onlineConfirmed = false;
  bool onlineWebError = false;
  Future<WebViewEnvironment?>? onlineEnvironment;
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
      session = target.session;
      file = target.file;
      playlist = target.siblings;
      parentFolders = {
        for (final sibling in target.siblings) sibling.id: target.parentId,
      };
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
    if (!{FileKind.image, FileKind.text, FileKind.pdf}.contains(kind) &&
        !office) {
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
      if (kind == FileKind.image) {
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
      } else if (kind == FileKind.text) {
        text = await scope.run(
          () => TextPreviewLoader.remote(widget.services.transfer, value),
        );
      }
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

  Future<void> _download() async {
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
      var value = spec;
      if (value == null) {
        value = await widget.services.cloud.prepare(session, file);
      } else {
        widget.services.cleanups.retain(value.cleanup);
      }
      try {
        await widget.services.downloads.enqueue(value);
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
      return PlayerPage(
        playback!,
        confirmDownload: () => confirmBaiduDownload(
          context,
          widget.services,
          playback!.current.platform,
          session: playback!.current.source?.cloud?.session,
        ),
        onAuthorizeUcTv: session.platform == CloudPlatform.uc
            ? () => openUcTvAuthorization(
                context,
                widget.services,
                accountId: session.accountId,
              )
            : null,
        subtitleDirectory: Directory(
          '${widget.services.cacheDirectory.path}/playback-subtitles',
        ),
        onDownload: (source) async {
          await widget.services.downloads.enqueue(source);
        },
      );
    }
    return PageFrame(
      title: widget.file.name,
      actions: [
        IconButton(
          tooltip:
              kind == FileKind.image ||
                  kind == FileKind.text ||
                  kind == FileKind.pdf ||
                  office
              ? '下载文件'
              : '传输管理',
          onPressed:
              kind == FileKind.image ||
                  kind == FileKind.text ||
                  kind == FileKind.pdf ||
                  office
              ? (adding || loading || poolError ? null : _download)
              : widget.services.requestDownloadManager,
          icon: const Icon(CupertinoIcons.arrow_down_circle),
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
                : text != null
                ? TextPreview(text!)
                : (kind == FileKind.pdf || office) && spec != null
                ? _onlinePreview(spec!)
                : EmptyPanel(
                    widget.file.name,
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

  String get _onlineProvider =>
      kind == FileKind.pdf ? 'Google 文档查看器' : 'Microsoft Office Online';

  Uri? _onlineViewerUri(DownloadSpec source) {
    final sourceUri = Uri.tryParse(source.url);
    if (sourceUri == null ||
        sourceUri.scheme != 'https' ||
        sourceUri.host.isEmpty ||
        sourceUri.userInfo.isNotEmpty ||
        source.headers.isNotEmpty ||
        source.networkPolicy != null) {
      return null;
    }
    final uri = kind == FileKind.pdf
        ? Uri.https('docs.google.com', '/gview', {
            'embedded': '1',
            'url': source.url,
          })
        : Uri.https('view.officeapps.live.com', '/op/view.aspx', {
            'src': source.url,
          });
    return uri.toString().length > 8000 ? null : uri;
  }

  Widget _onlinePreview(DownloadSpec source) {
    if (source.networkPolicy != null || source.headers.isNotEmpty) {
      return EmptyPanel(
        '此链接暂不支持在线预览',
        source.networkPolicy != null
            ? '此来源限制了下载地址权限，不能交给第三方查看器。'
            : '此临时链接需要应用专用请求头，在线查看器无法访问。',
        icon: CupertinoIcons.doc_text,
        action: FilledButton.icon(
          onPressed: adding ? null : _download,
          icon: const Icon(CupertinoIcons.arrow_down, size: 17),
          label: const Text('下载文件'),
        ),
      );
    }
    final uri = _onlineViewerUri(source);
    if (uri == null) {
      return EmptyPanel(
        widget.file.name,
        '临时链接过长或格式不受支持，请下载后查看',
        icon: CupertinoIcons.doc_text,
        action: FilledButton.icon(
          onPressed: adding ? null : _download,
          icon: const Icon(CupertinoIcons.arrow_down, size: 17),
          label: const Text('下载文件'),
        ),
      );
    }
    if (!onlineConfirmed) {
      return EmptyPanel(
        '在线预览提示',
        '此文件将通过 $_onlineProvider 打开。临时下载链接和文件内容会发送给第三方；仅继续预览非敏感文件，且链接需可直接访问。',
        icon: CupertinoIcons.globe,
        action: FilledButton(
          key: const Key('online-preview-confirm'),
          onPressed: () => setState(() {
            onlineConfirmed = true;
            onlineEnvironment = widget.services.webEnvironment();
          }),
          child: const Text('继续在线预览'),
        ),
      );
    }
    if (onlineWebError) {
      return EmptyPanel(
        '在线预览失败',
        '$_onlineProvider 无法读取此临时链接，请下载文件后查看',
        icon: CupertinoIcons.globe,
        action: FilledButton.icon(
          onPressed: adding ? null : _download,
          icon: const Icon(CupertinoIcons.arrow_down, size: 17),
          label: const Text('下载文件'),
        ),
      );
    }
    return FutureBuilder<WebViewEnvironment?>(
      future: onlineEnvironment,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return EmptyPanel(
            '网页组件不可用',
            errorText(snapshot.error!),
            icon: CupertinoIcons.globe,
            action: FilledButton(
              onPressed: adding ? null : _download,
              child: const Text('下载文件'),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return InAppWebView(
          key: const Key('online-preview-webview'),
          webViewEnvironment: snapshot.data,
          initialUrlRequest: URLRequest(url: WebUri(uri.toString())),
          initialSettings: webSettings(desktopMode: true, isPopup: true),
          onLoadStart: (_, _) {
            if (mounted && onlineWebError) {
              setState(() => onlineWebError = false);
            }
          },
          onReceivedError: (_, request, _) {
            if (request.isForMainFrame == true && mounted) {
              setState(() => onlineWebError = true);
            }
          },
        );
      },
    );
  }
}
