import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class DocumentTestController extends PlatformInAppWebViewController {
  DocumentTestController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 601),
      );
  final handlers = <String, JavaScriptHandlerCallback>{};
  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) {
    handlers[handlerName] = callback;
  }
}

class DocumentTestView extends PlatformInAppWebViewWidget {
  DocumentTestView(super.params) : super.implementation();
  bool disposed = false;
  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.white, child: Text('本地文档阅读器'));
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;
  @override
  void dispose() => disposed = true;
}

class DocumentTestWebPlatform extends InAppWebViewPlatform {
  final views = <DocumentTestView>[];
  final controller = DocumentTestController();
  void ready() {
    final view = views.last;
    view.params.onWebViewCreated!(
      view.controllerFromPlatform<InAppWebViewController>(controller),
    );
    controller.handlers['documentStatus']!([
      {'status': 'ready'},
    ]);
  }

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) => controller;
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = DocumentTestView(params);
    views.add(view);
    return view;
  }
}
