part of 'playback_controller.dart';

extension PlaybackCasting on PlaybackController {
  Future<void> castTo(
    CastDevice device, {
    bool? playWhenReady,
    bool reconnect = false,
    bool refreshSource = false,
  }) {
    require(_castTasks.isEmpty, '正在连接电视，请稍候');
    require(!disconnectingCast, '正在返回本机，请稍候');
    if (!reconnect && _cast?.device.id == device.id) return Future.value();
    final renew =
        refreshSource ||
        _cast?.sourceFailure?.kind == PlaybackFailureKind.expired;
    final generation = _generation;
    final task = () async {
      try {
        await _castTo(
          device,
          playWhenReady: playWhenReady,
          refreshSource: renew,
        );
      } on PlaybackFailure catch (e) {
        if (renew ||
            e.kind != PlaybackFailureKind.expired ||
            closed ||
            generation != _generation ||
            disconnectingCast ||
            _castSourceRefreshAttempted) {
          rethrow;
        }
        _castSourceRefreshAttempted = true;
        DiagnosticLog.event(
          'cast.source_refresh',
          fields: {'trigger': 'preparation', 'status': e.status},
        );
        await _castTo(
          device,
          playWhenReady: playWhenReady,
          refreshSource: true,
        );
      }
    }();
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

  Future<void> _castTo(
    CastDevice device, {
    bool? playWhenReady,
    bool refreshSource = false,
  }) async {
    require(!closed && !loading && hasVideo, '请等待视频地址准备完成');
    require(!connectingCast && !openingExternalPlayer, '正在连接播放器，请稍候');
    require(!usingSystemPip && !preparingSystemPip, '请先退出画中画');
    checkSource?.call();
    var position = state.position, duration = state.duration;
    var remotePlay = playWhenReady ?? _cast?.playWhenReady ?? state.playing;
    final wasPlaying = state.playing && !casting;
    final generation = _generation, sleepRevision = sleepTimer.stopRevision;
    final previousError = error;
    final previousCast = _cast;
    final previousSource = _castSource;
    if (previousCast != null) {
      final previousRevision = _castRevision;
      connectingCast = true;
      _changed();
      await previousCast.refresh();
      if (closed ||
          generation != _generation ||
          previousRevision != _castRevision ||
          !identical(_cast, previousCast)) {
        return;
      }
      position = previousCast.bookmarkState.position;
      duration = previousCast.state.duration;
      remotePlay = playWhenReady ?? previousCast.playWhenReady;
    }
    if (closed || generation != _generation) return;
    final revision = ++_castRevision;
    final scope = _castScope = RequestScope();
    _castTarget = device;
    connectingCast = true;
    DownloadSpec? unowned;
    CastSession? cast;
    var started = false;
    var published = false, oldReleased = false;
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
    DiagnosticLog.event(
      'cast.connect',
      fields: {
        'device': DiagnosticLog.reference(device.id),
        'reconnect': previousCast != null,
        'refresh_source': refreshSource,
      },
    );
    try {
      await _castClosing;
      await _stopExternalPlayback();
      check();
      final session = _session;
      if (!refreshSource &&
          previousSource != null &&
          previousCast?.sourceFailure == null) {
        retain(previousSource);
        unowned = previousSource;
      } else if (!refreshSource &&
          session != null &&
          session.backend.failure?.sourceFailure != true) {
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
      cast.streamConnections = preferences.connectionsFor(current.platform);
      cast.useControllerPlatform();
      await cast.start(
        title: current.name,
        position: position,
        duration: duration,
        playWhenReady: remotePlay,
        beforeSetMedia: () async {
          await previousCast?.suspend();
          check();
          previousCast?.removeListener(_onCastState);
          _cast = cast;
          _castSource = unowned;
          unowned = null;
          published = true;
          cast!.addListener(_onCastState);
          _changed();
        },
      );
      check();
      started = true;
      if (previousCast != null) {
        if (previousCast.device.id == device.id) {
          previousCast.relinquishTransport();
        }
        await previousCast.close();
        if (previousSource != null) await _releaseSafely(previousSource);
        oldReleased = true;
      }
      error = '';
      _playWhenReady = remotePlay;
      _discardPrepared();
      notice = '已连接 ${device.name}，可在此控制电视播放';
      DiagnosticLog.event(
        'player.cast_connected',
        fields: {
          'platform': current.platform?.key,
          'playback': DiagnosticLog.reference(current.key),
        },
      );
    } catch (failure) {
      DiagnosticLog.event(
        'cast.connect_failed',
        fields: {
          'device': DiagnosticLog.reference(device.id),
          'code': failure is CastSoapException ? failure.code : null,
          'error_type': failure.runtimeType.toString(),
        },
      );
      rethrow;
    } finally {
      if (!started || !currentRequest()) {
        if (cast != null && identical(_cast, cast)) {
          await _closeCast(cast);
        } else if (cast != null) {
          await cast.close();
        }
      }
      if (unowned case final unused?) await _releaseSafely(unused);
      if (previousCast != null && !oldReleased) {
        if (!started && currentRequest()) {
          try {
            if (published &&
                cast?.changedTransport == true &&
                previousCast.device.id == device.id) {
              await previousCast.restore();
            } else {
              previousCast.resumePolling();
            }
            check();
            _cast = previousCast;
            _castSource = previousSource;
            _castTarget = previousCast.device;
            if (published) previousCast.addListener(_onCastState);
            _session?.castBookmark = null;
            notice = '重连未成功，已保留原投屏会话和进度';
          } catch (restoreError) {
            DiagnosticLog.event(
              'cast.restore_failed',
              fields: {'error_type': restoreError.runtimeType.toString()},
            );
            if (published) {
              if (identical(_cast, previousCast)) {
                _cast = null;
                _castSource = null;
                _session?.castBookmark = previousCast.bookmarkState;
              }
              await previousCast.close();
              if (previousSource != null) await _releaseSafely(previousSource);
            }
          }
        } else {
          if (published) {
            if (previousCast.device.id == device.id) {
              previousCast.relinquishTransport();
            }
            await previousCast.close();
            if (previousSource != null) await _releaseSafely(previousSource);
          }
        }
      }
      if (identical(_castScope, scope)) _castScope = null;
      if (revision == _castRevision) connectingCast = false;
      if (!started && currentRequest() && _cast == null) {
        _castTarget = null;
        await _releaseCastPlatform();
        error = previousError;
        if (previousCast != null) {
          await backend?.seek(position);
          _session?.positionWasSet = true;
        }
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
    if (cast.transportReplaced || cast.connectionAbandoned) {
      notice = cast.error;
      unawaited(disconnectCast());
      _changed();
      return;
    }
    if (!connectingCast && !disconnectingCast && !cast.state.completed) {
      _playWhenReady = cast.playWhenReady;
    }
    if (cast.sourceFailure?.kind == PlaybackFailureKind.expired &&
        !connectingCast &&
        !disconnectingCast &&
        _castTasks.isEmpty &&
        !_castSourceRefreshAttempted) {
      _castSourceRefreshAttempted = true;
      unawaited(
        castTo(cast.device, reconnect: true, refreshSource: true).catchError((
          Object e,
        ) {
          notice = '自动刷新投屏链接失败，进度已保留，请刷新链接重试';
          DiagnosticLog.event(
            'cast.source_refresh_failed',
            fields: {'error_type': e.runtimeType.toString()},
          );
          _changed();
        }),
      );
    }
    _changed();
    final session = _session;
    if (!connectingCast &&
        !disconnectingCast &&
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
            cast.playWhenReady) {
          await load(nextIndex!, automaticAdvance: true);
        }
      }());
    }
  }

  Future<void> _closeCast(CastSession cast) {
    if (!identical(_cast, cast)) return _castClosing ?? Future.value();
    final source = _castSource;
    final session = _session;
    session?.castBookmark = cast.bookmarkState;
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

  Future<void> disconnectCast({bool resumeLocally = false}) {
    final pending = _castDisconnecting;
    if (pending != null) return pending;
    final task = _disconnectCast(resumeLocally: resumeLocally);
    _castDisconnecting = task;
    _changed();
    return task.whenComplete(() {
      if (identical(_castDisconnecting, task)) _castDisconnecting = null;
      _changed();
    });
  }

  Future<void> _disconnectCast({required bool resumeLocally}) async {
    _playWhenReady = false;
    final generation = _generation;
    final sleepRevision = sleepTimer.stopRevision;
    final revision = ++_castRevision;
    _castScope?.cancel();
    final cast = _cast;
    if (cast?.connected == true && !connectingCast) {
      cast!.removeListener(_onCastState);
      await cast.refresh();
      if (closed || generation != _generation || revision != _castRevision) {
        return;
      }
    }
    final position = cast?.bookmarkState.position ?? state.position;
    final playLocally = cast == null
        ? resumeLocally
        : cast.playWhenReady && !cast.state.completed;
    await _stopCast();
    if (closed || generation != _generation) return;
    if (cast != null) {
      // Do not overwrite this bookmark with the local decoder's old position.
      await backend?.seek(position);
      _session?.castBookmark = null;
      _session?.completionHandled = false;
      _session?.positionWasSet = true;
    }
    if (resumeLocally &&
        !_background &&
        !sleepTimer.stopped &&
        sleepRevision == sleepTimer.stopRevision) {
      if (_session?.initializing == true || backend?.failure != null) {
        await load(index, startPosition: position, playWhenReady: playLocally);
      } else if (playLocally) {
        await play();
      }
    }
    _changed();
  }
}
