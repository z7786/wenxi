import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../core/json.dart';
import '../domain/models.dart';
import '../data/state_store.dart';
import 'playback_controller.dart';
import 'independent_player_window.dart';

class FloatingPlaybackSession {
  FloatingPlaybackSession(
    this.controller, {
    this.restorePage,
    this.attached = true,
  }) : id = newId();
  final String id;
  final PlaybackController controller;
  final WidgetBuilder? restorePage;
  IndependentPlayerWindow? window;
  bool closing = false;
  Future<void>? closingTask;
  bool attached;
}

class FloatingPlaybackManager extends ChangeNotifier {
  FloatingPlaybackManager._();
  static final _stores = Expando<FloatingPlaybackManager>();
  static FloatingPlaybackManager of(StateStore store) =>
      _stores[store] ??= FloatingPlaybackManager._();
  static FloatingPlaybackManager? maybeOf(StateStore store) => _stores[store];
  final _sessions = <FloatingPlaybackSession>[];
  final _closingTasks = <Future<void>>{};
  final navigatorKey = GlobalKey<NavigatorState>(debugLabel: 'main navigator');
  List<FloatingPlaybackSession> get sessions => List.unmodifiable(_sessions);
  bool _closed = false;
  Future<void>? _closing;
  bool contains(PlaybackController controller) =>
      _sessions.any((s) => identical(s.controller, controller));

  FloatingPlaybackSession add(
    PlaybackController controller, {
    WidgetBuilder? restorePage,
    bool attached = true,
  }) {
    require(!_closed && !controller.closed && !contains(controller), '小窗播放已结束');
    final session = FloatingPlaybackSession(
      controller,
      restorePage: restorePage,
      attached: attached,
    );
    controller.floating = true;
    _sessions.add(session);
    notifyListeners();
    return session;
  }

  void attach(FloatingPlaybackSession session) {
    if (_closed || session.closing || !_sessions.contains(session)) return;
    session.attached = true;
    notifyListeners();
  }

  Future<void> openWindows(PlaybackController controller) async {
    final session = add(controller);
    try {
      final window = IndependentPlayerWindow(
        controller,
        onClosed: () => closeSession(session),
      );
      session.window = window;
      await window.open();
      require(!_closed && !session.closing, '小窗播放已结束');
    } catch (_) {
      _sessions.remove(session);
      if (!session.closing) controller.floating = false;
      notifyListeners();
      await session.window?.close();
      rethrow;
    }
  }

  void restore(FloatingPlaybackSession session) {
    require(!session.closing && _sessions.remove(session), '小窗已关闭');
    session.controller.floating = false;
    notifyListeners();
  }

  void raise(FloatingPlaybackSession session) {
    if (session.closing ||
        _sessions.lastOrNull == session ||
        !_sessions.remove(session)) {
      return;
    }
    _sessions.add(session);
    notifyListeners();
  }

  Future<void> closeSession(FloatingPlaybackSession session) {
    if (session.closingTask case final closing?) return closing;
    session.closing = true;
    _sessions.remove(session);
    notifyListeners();
    final task = () async {
      try {
        await session.window?.close();
      } finally {
        session.controller.floating = false;
        await session.controller.close(force: true);
      }
    }();
    session.closingTask = task;
    _closingTasks.add(task);
    unawaited(
      task.then<void>(
        (_) => _closingTasks.remove(task),
        onError: (Object _) => _closingTasks.remove(task),
      ),
    );
    return task;
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    _closed = true;
    // An idle host has no decoder or window cleanup to defer. Completing here
    // also avoids retaining a close scheduled by an already detached host.
    if (_sessions.isEmpty && _closingTasks.isEmpty) {
      return _closing = SynchronousFuture<void>(null);
    }
    return _closing = _close();
  }

  Future<void> _close() async {
    await Future.wait(_sessions.toList().map(closeSession));
    await Future.wait(_closingTasks.toList());
  }
}
