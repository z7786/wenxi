part of 'playback_controller.dart';

extension PlaybackCasting on PlaybackController {
  Future<void> castTo(CastDevice device) {
    require(_castTasks.isEmpty, '正在连接电视，请稍候');
    final task = _castTo(device);
    _castTasks.add(task);
    unawaited(
      task.then<void>(
        (_) => _castTasks.remove(task),
        onError: (Object _, StackTrace _) {
          _castTasks.remove(task);
        },
      ),
    );
    return task;
  }

  Future<void> _castTo(CastDevice device) async {
    require(!closed && !loading && hasVideo, '请等待视频地址准备完成');
    require(!connectingCast && !openingExternalPlayer, '正在连接播放器，请稍候');
    checkSource?.call();
    final position = state.position, duration = state.duration;
    final wasPlaying = state.playing && !casting;
    final generation = _generation, sleepRevision = sleepTimer.stopRevision;
    final previousError = error;
    final previousCast = _cast;
    if (previousCast != null) {
      await _stopCast(keepPlatform: true);
      if (!closed && generation == _generation) {
        await backend?.seek(position);
        _session?.castBookmark = null;
      }
    }
    if (closed || generation != _generation) return;
    final revision = ++_castRevision;
    final scope = _castScope = RequestScope();
    _castTarget = device;
    connectingCast = true;
    DownloadSpec? unowned;
    CastSession? cast;
    var started = false;
    bool currentRequest() =>
        !closed &&
        generation == _generation &&
        revision == _castRevision &&
        !scope.token.isCancelled;
    void check() {
      require(currentRequest(), '投屏已取消或视频已切换');
      require(
        !sleepTimer.stopped && sleepRevision == sleepTimer.stopRevision,
        '定时停止已生效，投屏已取消',
      );
      checkSource?.call();
    }

    _changed();
    try {
      await _castClosing;
      await _stopExternalPlayback();
      check();
      final session = _session;
      if (session != null && session.backend.failure?.sourceFailure != true) {
        retain(session.source);
        unowned = session.source;
      } else {
        unowned = await (refresh ?? prepare)(current, scope);
      }
      check();
      // Pause the actual local decoder before publishing remote state.
      await endBoost();
      await backend?.pause();
      await saveProgress();
      check();
      // A controller owns one platform lease across episode changes. Keeping
      // the foreground service alive avoids a forbidden background FGS restart
      // when the TV advances while the phone is locked.
      _castPlatformUsed = true;
      await castPlatform.active(true);
      check();
      cast = castSessionFactory(device, unowned);
      _cast = cast;
      _castSource = unowned;
      unowned = null;
      cast.useControllerPlatform();
      cast.addListener(_onCastState);
      _changed();
      await cast.start(
        title: current.name,
        position: position,
        duration: duration,
      );
      check();
      started = true;
      error = '';
      _playWhenReady = true;
      _discardPrepared();
      notice = '已连接 ${device.name}，可在此控制电视播放';
      DiagnosticLog.event(
        'player.cast_connected',
        fields: {
          'platform': current.platform?.key,
          'playback': DiagnosticLog.reference(current.key),
        },
      );
    } finally {
      if (!started || !currentRequest()) {
        if (cast != null && identical(_cast, cast)) await _closeCast(cast);
      }
      if (unowned != null) await _releaseSafely(unowned);
      if (identical(_castScope, scope)) _castScope = null;
      if (revision == _castRevision) connectingCast = false;
      if (!started && currentRequest()) {
        _castTarget = null;
        await _releaseCastPlatform();
        error = previousError;
        _session?.castBookmark = null;
        if (wasPlaying && canResumeAfterPanel(generation, sleepRevision)) {
          await play();
        }
      }
      _changed();
    }
  }

  void _onCastState() {
    final cast = _cast;
    if (closed || cast == null) return;
    if (cast.transportReplaced) {
      notice = cast.error;
      unawaited(disconnectCast());
      _changed();
      return;
    }
    _changed();
    final session = _session;
    if (!connectingCast &&
        cast.state.completed &&
        session != null &&
        !session.completionHandled) {
      session.completionHandled = true;
      unawaited(() async {
        await _save(session, completed: true);
        if (sleepTimer.mode == PlaybackSleepMode.episode) {
          await sleepTimer.finishEpisode();
        }
        if (identical(_cast, cast) &&
            !closed &&
            !sleepTimer.stopped &&
            preferences.autoNext &&
            canNext &&
            _playWhenReady) {
          await load(nextIndex!, automaticAdvance: true);
        }
      }());
    }
  }

  Future<void> _closeCast(CastSession cast) {
    if (!identical(_cast, cast)) return _castClosing ?? Future.value();
    final source = _castSource;
    final session = _session;
    session?.castBookmark = cast.state;
    cast.removeListener(_onCastState);
    // Preserve the remote bookmark before the native backend becomes current.
    _cast = null;
    _castSource = null;
    final task = () async {
      if (session != null) await _save(session);
      try {
        await cast.close();
      } finally {
        if (source != null) await _releaseSafely(source);
      }
    }();
    _castClosing = task;
    unawaited(
      task.then<void>(
        (_) {
          if (identical(_castClosing, task)) _castClosing = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_castClosing, task)) _castClosing = null;
        },
      ),
    );
    return task;
  }

  Future<void> _stopCast({bool keepPlatform = false}) async {
    _castRevision++;
    _castScope?.cancel();
    connectingCast = false;
    final cast = _cast;
    if (!keepPlatform) _castTarget = null;
    try {
      if (cast != null) {
        await _closeCast(cast);
      } else {
        await _castClosing;
      }
    } finally {
      if (!keepPlatform) await _releaseCastPlatform();
    }
  }

  Future<void> _releaseCastPlatform() async {
    if (!_castPlatformUsed) return;
    _castPlatformUsed = false;
    await castPlatform.active(false);
  }

  Future<void> _settleCastTasks() async {
    // The original caller still receives its connection error. Cancellation
    // must not interrupt the controller's remaining teardown and store flush.
    await Future.wait(
      _castTasks.toList().map(
        (task) => task.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
  }

  Future<void> disconnectCast({bool resumeLocally = false}) async {
    _playWhenReady = false;
    final generation = _generation;
    final position = state.position;
    final cast = _cast;
    await _stopCast();
    if (closed || generation != _generation) return;
    if (cast != null) {
      // Do not overwrite this bookmark with the local decoder's old position.
      await backend?.seek(position);
      _session?.castBookmark = null;
      _session?.completionHandled = false;
      _session?.positionWasSet = true;
    }
    if (resumeLocally && !_background && !sleepTimer.stopped) {
      if (_session?.initializing == true || backend?.failure != null) {
        await load(index, startPosition: position, playWhenReady: true);
      } else {
        await play();
      }
    }
    _changed();
  }
}
