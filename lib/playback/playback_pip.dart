part of 'playback_controller.dart';

class _SystemPipSession {
  _SystemPipSession(this.playback, this.stream, this.source, this.initialState);
  final SystemPipPlayback playback;
  final ExternalPlaybackStream stream;
  final DownloadSpec source;
  final PlayerState initialState;
  late VoidCallback listener;
  bool closed = false, restoring = false, prepared = false;
  Future<PlayerState>? closing;
  Future<void>? restoration;
  PlayerState get state =>
      prepared ? playback.state : initialState.copyWith(playing: false);
}

String _iosExternalUrl(DownloadSpec source) {
  require(source.networkPolicy == null, '此来源需要 App 校验网络权限，请使用内置播放器或下载完成后播放');
  final uri = Uri.tryParse(source.url);
  require(
    uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.host != 'localhost' &&
        InternetAddress.tryParse(uri.host)?.isLoopback != true,
    '此视频需要 App 保持运行，请使用内置播放器或先导出文件',
  );
  require(source.headers.isEmpty, '此视频需要网盘授权，请使用内置播放器或先下载再导出到其他播放器');
  return source.url;
}

extension PlaybackSystemPip on PlaybackController {
  Future<bool> enterSystemPip(
    SystemPipPlayback playback,
    Future<bool> Function() enter,
  ) async {
    require(ready && hasVideo && !closed, '请等待视频准备完成');
    require(
      !preparingSystemPip && !usingSystemPip && !openingExternalPlayer,
      '正在连接播放器，请稍候',
    );
    require(!casting && !connectingCast, '请先断开电视投屏');
    final session = _session!;
    checkSource?.call();
    preparingSystemPip = true;
    final scope = _pipScope = RequestScope();
    final revision = ++_pipRevision, generation = _generation;
    final initial = state;
    var entered = false;
    _SystemPipSession? pip;
    DownloadSpec? source;
    bool current() =>
        !closed &&
        _current(session) &&
        generation == _generation &&
        revision == _pipRevision &&
        !scope.token.isCancelled;
    void check() {
      require(current(), '视频已切换，画中画已取消');
      require(!sleepTimer.stopped, '定时停止已生效');
      checkSource?.call();
    }

    _changed();
    try {
      await _pipClosing;
      await _stopExternalPlayback();
      check();
      retain(session.source);
      source = session.source;
      await endBoost();
      await session.backend.pause();
      require(!session.backend.state.playing, '视频未能暂停，请重试画中画');
      await saveProgress();
      check();
      pip = _SystemPipSession(
        playback,
        externalStreamFactory(source),
        source,
        initial,
      );
      source = null;
      final active = pip;
      active.listener = () => _onSystemPip(active);
      _pipSession = active;
      playback.addListener(active.listener);
      _discardPrepared();
      _changed();
      await active.stream.start();
      check();
      final prepared = await playback.prepare(
        url: active.stream.url,
        title: session.entry.name,
        initialState: initial,
      );
      check();
      if (!prepared) {
        notice = playback.failureMessage.isNotEmpty
            ? playback.failureMessage
            : '系统暂不支持此视频画中画，已恢复内置播放器';
        return false;
      }
      active.prepared = true;
      entered = await enter();
      check();
      return entered;
    } finally {
      if (source != null) await _releaseSafely(source);
      if ((!entered || !current()) && pip != null) {
        await _closeSystemPip(pip);
        if (identical(_pipSession, pip)) _pipSession = null;
      }
      if (identical(_pipScope, scope)) _pipScope = null;
      preparingSystemPip = false;
      _changed();
      if (entered && current() && pip != null && playback.finished) {
        _onSystemPip(pip);
      }
      if (!entered && current()) {
        session.pipBookmark = initial.copyWith(playing: false);
        if (_visible) await _restorePipBookmark(session);
        if (initial.playing && !_background && !sleepTimer.stopped) {
          await play();
        }
      }
    }
  }

  void _onSystemPip(_SystemPipSession pip) {
    if (closed || pip.closed || !identical(_pipSession, pip)) return;
    _changed();
    if (pip.playback.finished && !preparingSystemPip && !pip.restoring) {
      pip.restoring = true;
      unawaited(
        restoreSystemPip(resume: pip.playback.restoreRequested).catchError((
          Object error,
          StackTrace stack,
        ) {
          DiagnosticLog.error('player.system_pip_restore', error, stack);
        }),
      );
    }
  }

  Future<PlayerState> _closeSystemPip(_SystemPipSession pip) =>
      pip.closing ??= () async {
        pip.closed = true;
        pip.playback.removeListener(pip.listener);
        try {
          return await pip.playback.stop();
        } finally {
          try {
            await pip.stream.close();
          } finally {
            await _releaseSafely(pip.source);
          }
        }
      }();

  Future<void> _stopSystemPip() async {
    final pip = _pipSession;
    if (pip == null) {
      await _pipClosing;
      return;
    }
    final closing = _closeSystemPip(pip).then<void>((_) {});
    _pipClosing = closing;
    try {
      await closing;
    } finally {
      if (identical(_pipSession, pip)) _pipSession = null;
      if (identical(_pipClosing, closing)) _pipClosing = null;
      _changed();
    }
  }

  Future<void> restoreSystemPip({required bool resume}) {
    final pip = _pipSession, session = _session;
    if (pip == null || session == null || closed) return Future.value();
    return pip.restoration ??= () async {
      session.pipBookmark = pip.state;
      await _stopSystemPip();
      if (!_current(session)) return;
      final finalState = pip.playback.state;
      session.pipBookmark = finalState.copyWith(playing: false);
      // Seeking a paused mpv video can still render a frame. iOS disallows GPU
      // work while suspended, so preserve the bookmark until the app is visible.
      if (_visible) await _restorePipBookmark(session);
      await saveProgress();
      if (resume &&
          finalState.playing &&
          !sleepTimer.stopped &&
          !_background &&
          _visible) {
        await play();
      }
      _changed();
    }();
  }

  Future<void> _restorePipBookmark(_Session session) async {
    if (!_current(session) || !_visible || session.pipBookmark == null) return;
    final running = session.pipRestoring;
    if (running != null) {
      await running;
      return;
    }
    final bookmark = session.pipBookmark!;
    final work = () async {
      await session.backend.seek(
        clampPlaybackPosition(
          bookmark.position,
          session.backend.state.duration,
        ),
      );
      if (!_current(session)) return;
      session.positionWasSet = true;
      if (identical(session.pipBookmark, bookmark)) session.pipBookmark = null;
      await saveProgress();
      _changed();
    }();
    session.pipRestoring = work;
    try {
      await work;
    } finally {
      if (identical(session.pipRestoring, work)) session.pipRestoring = null;
    }
  }
}
