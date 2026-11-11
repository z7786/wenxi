import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Matches system back so each route's PopScope owns directory/selection state.
class DesktopMouseBack extends StatelessWidget {
  const DesktopMouseBack({super.key, required this.child});
  final Widget child;
  static final _handled = Expando<bool>();
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      final original = event.original ?? event;
      if (Platform.isWindows &&
          Theme.of(context).platform == TargetPlatform.windows &&
          event.kind == PointerDeviceKind.mouse &&
          event.buttons == kBackMouseButton &&
          _handled[original] != true &&
          ModalRoute.of(context)?.isCurrent != false) {
        _handled[original] = true;
        Navigator.maybePop(context);
      }
    },
    child: child,
  );
}
