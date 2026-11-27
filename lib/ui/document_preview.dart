import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app_services.dart';
import '../data/http.dart';
import '../diagnostics/app_log.dart';
import '../platform/completed_file_actions.dart';
import '../preview/document_format.dart';
import '../preview/document_server.dart';
import 'common.dart';
import 'text_preview.dart';

class LocalDocumentPreviewPage extends StatefulWidget {
  const LocalDocumentPreviewPage({
    super.key,
    required this.services,
    required this.path,
    required this.name,
  });
  final AppServices services;
  final String path, name;

  @override
  State<LocalDocumentPreviewPage> createState() =>
      _LocalDocumentPreviewPageState();
}

class _LocalDocumentPreviewPageState extends State<LocalDocumentPreviewPage> {
  RequestScope _scope = RequestScope();
  DocumentServer? _server;
  WebViewEnvironment? _environment;
  bool _loading = true, _acting = false;
  String _error = '';
  int _generation = 0;
  Timer? _loadTimeout;
  final _actions = CompletedFileActions();

  @override
  void initState() {
    super.initState();
    if (documentFormat(widget.name) != DocumentFormat.text) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _scope.cancel();
    _scope = RequestScope();
    final scope = _scope;
    _loadTimeout?.cancel();
    final old = _server;
    setState(() {
      _server = null;
      _loading = true;
      _error = '';
    });
    if (documentFormat(widget.name) == DocumentFormat.external) {
      setState(() {
        _loading = false;
        _error = '此格式暂不支持内置预览，请使用其他应用打开';
      });
      return;
    }
    DocumentServer? server;
    try {
      await old?.close();
      if (!mounted || generation != _generation) return;
      server = await scope.run(
        () => DocumentServer.open(path: widget.path, name: widget.name),
      );
      final opened = server;
      scope.token.whenCancel.then((_) => opened?.close());
      if (!mounted || generation != _generation) {
        await server?.close();
        return;
      }
      final environment = await scope.run(
        () => RequestScope.cancellable(widget.services.webEnvironment()),
      );
      if (!mounted || generation != _generation) {
        await server?.close();
        return;
      }
      setState(() {
        _server = server;
        _environment = environment;
      });
      _loadTimeout = Timer(const Duration(seconds: 45), () {
        if (mounted && generation == _generation && _loading) {
          _failed('文档渲染时间较长，可重试或使用其他应用打开');
        }
      });
    } catch (error, stack) {
      await server?.close();
      DiagnosticLog.error('document.preview_failed', error, stack);
      if (mounted && generation == _generation) _failed(errorText(error));
    } finally {
      if (!mounted || generation != _generation) await server?.close();
    }
  }

  void _failed(String message) {
    _loadTimeout?.cancel();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
    // Removing the WebView also releases its worker/canvas memory.
    final server = _server;
    _server = null;
    if (server != null) unawaited(server.close());
  }

  Future<void> _fileAction(String action) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      if (action == 'share') {
        await _actions.share(widget.path, widget.name, origin: origin);
      } else {
        await _actions.openWith(widget.path, widget.name, origin: origin);
      }
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _scope.cancel();
    _loadTimeout?.cancel();
    final server = _server;
    if (server != null) unawaited(server.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (documentFormat(widget.name) == DocumentFormat.text) {
      return LocalTextPreviewPage(path: widget.path, name: widget.name);
    }
    final server = _server;
    final theme = Theme.of(context);
    String rgb(Color color) =>
        (color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0');
    final palette = {
      'theme': theme.brightness.name,
      'background': rgb(theme.colorScheme.surfaceContainerLow),
      'surface': rgb(theme.colorScheme.surface),
      'text': rgb(theme.colorScheme.onSurface),
      'muted': rgb(theme.colorScheme.onSurfaceVariant),
      'line': rgb(theme.colorScheme.outlineVariant),
      'accent': rgb(theme.colorScheme.primary),
    };
    return PageFrame(
      title: widget.name,
      actions: [
        PopupMenuButton<String>(
          tooltip: '文档操作',
          enabled: !_acting,
          onSelected: _fileAction,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'open-with', child: Text('用其他应用打开')),
            PopupMenuItem(value: 'share', child: Text('分享文件')),
          ],
        ),
      ],
      child: _error.isNotEmpty
          ? EmptyPanel(
              '暂时无法预览',
              _error,
              icon: CupertinoIcons.doc_text,
              action: Wrap(
                spacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (documentFormat(widget.name) != DocumentFormat.external)
                    TextButton(onPressed: _load, child: const Text('重试预览')),
                  FilledButton(
                    onPressed: _acting ? null : () => _fileAction('open-with'),
                    child: const Text('用其他应用打开'),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                if (server != null)
                  InAppWebView(
                    key: ValueKey('document-webview-$_generation-$palette'),
                    webViewEnvironment: _environment,
                    initialUrlRequest: URLRequest(
                      url: WebUri(
                        server.uri.replace(queryParameters: palette).toString(),
                      ),
                    ),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: false,
                      allowFileAccess: false,
                      allowContentAccess: false,
                      allowFileAccessFromFileURLs: false,
                      allowUniversalAccessFromFileURLs: false,
                      useShouldOverrideUrlLoading: true,
                      useOnRenderProcessGone: true,
                      supportMultipleWindows: false,
                      javaScriptCanOpenWindowsAutomatically: false,
                      thirdPartyCookiesEnabled: false,
                      cacheEnabled: false,
                      saveFormData: false,
                      useWideViewPort: true,
                      loadWithOverviewMode: false,
                      supportZoom: true,
                      builtInZoomControls: true,
                      displayZoomControls: false,
                      transparentBackground: false,
                      disableContextMenu: true,
                      mediaPlaybackRequiresUserGesture: true,
                    ),
                    onWebViewCreated: (controller) {
                      controller.addJavaScriptHandler(
                        handlerName: 'documentStatus',
                        callback: (arguments) {
                          if (!mounted ||
                              _server != server ||
                              arguments.isEmpty) {
                            return null;
                          }
                          final value = arguments.first;
                          if (value is Map && value['status'] == 'ready') {
                            _loadTimeout?.cancel();
                            setState(() => _loading = false);
                          } else if (value is Map &&
                              value['status'] == 'error') {
                            _failed('无法读取此文档，可能已损坏、加密或格式不受支持');
                          }
                          return null;
                        },
                      );
                    },
                    shouldOverrideUrlLoading: (_, action) async {
                      final url = action.request.url;
                      return url != null &&
                              url.origin == server.uri.origin &&
                              url.path.startsWith(
                                server.uri.path.substring(
                                  0,
                                  server.uri.path.lastIndexOf('/') + 1,
                                ),
                              )
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    onReceivedError: (_, request, _) {
                      if (request.isForMainFrame == true && _server == server) {
                        _failed('文档页面加载失败，可重试或使用其他应用打开');
                      }
                    },
                    onReceivedHttpError: (_, request, _) {
                      if (request.isForMainFrame == true && _server == server) {
                        _failed('文档页面加载失败，可重试或使用其他应用打开');
                      }
                    },
                    onRenderProcessGone: (_, _) async {
                      if (_server == server) {
                        _failed('系统已释放文档预览组件，可重试或使用其他应用打开');
                      }
                    },
                  ),
                if (_loading)
                  Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('正在读取文档…'),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
