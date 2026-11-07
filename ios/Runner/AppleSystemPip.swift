import Flutter
import UIKit
import AVFoundation
import AVKit

/// Each handoff owns its renderer until AVKit finishes closing its window.
/// The usual media_kit decoder stays paused while that handoff owns the video.
final class AppleSystemPip {
  private var session = ""
  private var channel: FlutterMethodChannel?
  private var current: ApplePipSession?
  private weak var pendingHost: ApplePipVideoView?
  private var revision = 0

  var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
  var active: Bool { current?.active == true }
  var keepsPlayingInBackground: Bool { current?.keepsPlayingInBackground == true }

  func begin(session: String, channel: FlutterMethodChannel) {
    end()
    self.session = session
    self.channel = channel
  }

  func handle(_ call: FlutterMethodCall, arguments: [String: Any], result: @escaping FlutterResult) -> Bool {
    let controls = ["enterPip", "exitPip", "isPip", "stopPip", "pipPlay", "pipPause", "pipSeek", "pipRate"]
    if controls.contains(call.method),
       current == nil || arguments["pipId"] as? String != current?.pipId {
      result(call.method == "enterPip" || call.method == "isPip" ? false : nil)
      return true
    }
    switch call.method {
    case "preparePip": prepare(arguments, result: result)
    case "enterPip": current?.enter(result: result)
    case "isPip": result(active)
    case "exitPip":
      current?.restore = true
      current?.stop { _ in result(nil) }
    case "stopPip":
      guard let playback = current else { result(nil); return true }
      playback.stop { [weak self] snapshot in
        if self?.current === playback { self?.current = nil }
        result(snapshot)
      }
    case "pipPlay": current?.play(); result(current?.values)
    case "pipPause": current?.pause(); result(current?.values)
    case "pipSeek":
      let milliseconds = (arguments["positionMs"] as? NSNumber)?.doubleValue ?? 0
      current?.seek(milliseconds: milliseconds, result: result)
    case "pipRate":
      current?.setRate((arguments["rate"] as? NSNumber)?.floatValue ?? 1)
      result(current?.values)
    default: return false
    }
    return true
  }

  private func prepare(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard !session.isEmpty, UIApplication.shared.applicationState == .active,
          let pipId = arguments["pipId"] as? String, !pipId.isEmpty,
          let text = arguments["url"] as? String, text.utf8.count <= 32768,
          let url = URL(string: text), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
      result(false); return
    }
    revision += 1
    let currentRevision = revision, currentSession = session
    let create = { [weak self] in
      guard let self = self, self.revision == currentRevision, self.session == currentSession,
            UIApplication.shared.applicationState == .active, let channel = self.channel else {
        result(false); return
      }
      do {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback)
        try audio.setActive(true)
      } catch { result(false); return }
      let playback = ApplePipSession(session: currentSession, pipId: pipId, url: url,
        arguments: arguments, channel: channel, result: result)
      self.current = playback
      if let host = self.pendingHost, host.session == currentSession, host.pipId == pipId {
        self.pendingHost = nil
        playback.attach(host)
      }
      playback.prepare()
    }
    if let previous = current { previous.stop { _ in create() } }
    else { create() }
  }

  func attach(_ view: ApplePipVideoView) {
    guard view.session == session else { return }
    if let current = current, current.pipId == view.pipId { current.attach(view) }
    else { pendingHost = view }
  }

  func layout(_ view: ApplePipVideoView) { current?.layout(view) }
  func visible(_ visible: Bool) { current?.visible(visible) }

  func end() {
    revision += 1
    let previous = current
    current = nil
    pendingHost = nil
    session = ""
    channel = nil
    previous?.end()
  }
}

private final class ApplePipSession: NSObject, AVPictureInPictureControllerDelegate {
  private enum Phase { case preparing, ready, requested, starting, active, stopping, finished }
  let session: String
  let pipId: String
  private var channel: FlutterMethodChannel?
  private let player: AVPlayer
  private let playerLayer: AVPlayerLayer
  private var controller: AVPictureInPictureController?
  private var phase = Phase.preparing
  private var observations: [NSKeyValueObservation] = []
  private var timeObserver: Any?
  private var endObservation: NSObjectProtocol?
  private var prepareResult: FlutterResult?
  private var enterResult: FlutterResult?
  private var prepareDeadline: DispatchWorkItem?
  private var enterDeadline: DispatchWorkItem?
  private var stopDeadline: DispatchWorkItem?
  private var stopResults: [([String: Any]) -> Void] = []
  private var retainedWhileStopping: ApplePipSession?
  private var initialPosition: CMTime
  private var initiallyPlaying: Bool
  private var itemPrepared = false
  private var initialSeekFinished = false
  private var failureCode = ""
  private var completed = false
  private var rate: Float
  private var stopWasPlaying = false
  private var finalValues: [String: Any]?
  private var stopNotified = false
  private weak var host: ApplePipVideoView?
  private weak var sourceView: UIView?
  var restore = false

  var active: Bool { controller?.isPictureInPictureActive == true }
  var keepsPlayingInBackground: Bool { active || phase == .starting }
  private var surfaceAttached: Bool {
    guard let host = host, let window = host.window else { return false }
    return !host.isHidden && host.alpha > 0 && !window.isHidden &&
      window.windowScene?.activationState == .foregroundActive &&
      host.bounds.width > 0 && host.bounds.height > 0 &&
      sourceView?.window === window && playerLayer.superlayer === sourceView?.layer
  }

  var values: [String: Any] {
    if let snapshot = finalValues { return snapshot }
    let position = player.currentTime().seconds
    let duration = player.currentItem?.duration.seconds ?? 0
    return [
      "session": session, "pipId": pipId,
      "positionMs": position.isFinite ? max(0, position * 1000) : 0,
      "durationMs": duration.isFinite ? max(0, duration * 1000) : 0,
      "playing": !completed && (player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate),
      "buffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      "completed": completed, "rate": Double(rate),
      "finished": phase == .finished, "restore": restore,
      "surfaceAttached": surfaceAttached, "readyForDisplay": playerLayer.isReadyForDisplay,
      "statusBarHidden": host?.window?.windowScene?.statusBarManager?.isStatusBarHidden ?? false,
      "failureCode": failureCode,
    ]
  }

  init(session: String, pipId: String, url: URL, arguments: [String: Any],
       channel: FlutterMethodChannel, result: @escaping FlutterResult) {
    self.session = session
    self.pipId = pipId
    self.channel = channel
    prepareResult = result
    initiallyPlaying = arguments["playing"] as? Bool ?? true
    let milliseconds = (arguments["positionMs"] as? NSNumber)?.doubleValue ?? 0
    initialPosition = CMTime(seconds: milliseconds.isFinite ? max(0, milliseconds / 1000) : 0, preferredTimescale: 600)
    let speed = (arguments["rate"] as? NSNumber)?.floatValue ?? 1
    rate = speed.isFinite ? min(5, max(0.25, speed)) : 1
    let item = AVPlayerItem(url: url)
    item.preferredForwardBufferDuration = 10
    let player = AVPlayer(playerItem: item)
    let layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    layer.opacity = 0
    layer.needsDisplayOnBoundsChange = true
    self.player = player
    playerLayer = layer
    super.init()
  }

  func prepare() {
    guard let item = player.currentItem else { completePreparation(false); return }
    observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, self.phase != .finished, self.phase != .stopping,
              self.player.currentItem === item else { return }
        if item.status == .readyToPlay && !self.itemPrepared {
          self.itemPrepared = true
          let duration = item.duration.seconds
          if duration.isFinite && duration > 0 && self.initialPosition.seconds >= duration {
            self.initialPosition = .zero
          }
          self.player.seek(to: self.initialPosition, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] ok in
            DispatchQueue.main.async {
              guard let self = self, self.phase == .preparing else { return }
              if ok && self.initiallyPlaying && UIApplication.shared.applicationState == .active {
                self.player.playImmediately(atRate: self.rate)
              }
              self.initialSeekFinished = ok
              if ok { self.displayChanged() }
              else { self.fail("item_failed") }
            }
          }
        } else if item.status == .failed {
          self.fail("item_failed", error: item.error)
        }
      }
    })
    observations.append(player.observe(\.rate, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.playbackChanged() }
    })
    observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.playbackChanged() }
    })
    observations.append(playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.displayChanged() }
    })
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
      self?.publish()
    }
    endObservation = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
      self?.completed = true
      self?.publish()
    }
    diagnostic("prepare")
    let deadline = DispatchWorkItem { [weak self] in self?.fail("prepare_timeout") }
    prepareDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
  }

  private func displayChanged() {
    guard phase != .stopping && phase != .finished else { return }
    playerLayer.opacity = playerLayer.isReadyForDisplay ? 1 : 0
    if phase == .preparing && initialSeekFinished && surfaceAttached && playerLayer.isReadyForDisplay {
      diagnostic("prepared")
      completePreparation(true)
    }
    attemptEntry()
  }

  private func fail(_ code: String, error: Error? = nil) {
    guard phase != .stopping && phase != .finished else { return }
    failureCode = code
    restore = true
    diagnostic(code, error: error)
    completePreparation(false)
    completeEntry(false)
    stop { _ in }
  }

  private func diagnostic(_ stage: String, error: Error? = nil) {
    let size = player.currentItem?.presentationSize ?? .zero
    var value: [String: Any] = [
      "session": session, "pipId": pipId, "stage": stage, "phase": String(describing: phase),
      "surfaceAttached": surfaceAttached, "readyForDisplay": playerLayer.isReadyForDisplay,
      "pipPossible": controller?.isPictureInPicturePossible ?? false,
      "itemStatus": player.currentItem?.status.rawValue ?? -1,
      "videoWidth": Double(size.width), "videoHeight": Double(size.height),
    ]
    if let error = error {
      let native = error as NSError
      value["errorDomain"] = native.domain
      value["errorCode"] = native.code
    }
    channel?.invokeMethod("pipDiagnostic", arguments: value)
  }

  private func completePreparation(_ ok: Bool) {
    guard let callback = prepareResult else { return }
    prepareResult = nil
    prepareDeadline?.cancel()
    prepareDeadline = nil
    if phase == .preparing { phase = .ready }
    if !ok { player.pause() }
    publish()
    callback(ok)
  }

  func enter(result: @escaping FlutterResult) {
    if active && phase == .active { result(true); return }
    guard phase == .ready, UIApplication.shared.applicationState == .active,
          controller != nil, player.currentItem?.status == .readyToPlay else { result(false); return }
    enterResult = result
    phase = .requested
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self, self.enterResult != nil else { return }
      // A pending foreground request must not turn into an automatic background start.
      self.fail("enter_timeout")
    }
    enterDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    attemptEntry()
  }

  private func attemptEntry() {
    guard phase == .requested, enterResult != nil else { return }
    guard UIApplication.shared.applicationState == .active else {
      completeEntry(false)
      stop { _ in }
      return
    }
    guard surfaceAttached, playerLayer.isReadyForDisplay,
          let controller = controller, controller.isPictureInPicturePossible else { return }
    phase = .starting
    diagnostic("start")
    controller.startPictureInPicture()
  }

  private func completeEntry(_ ok: Bool) {
    enterDeadline?.cancel()
    enterDeadline = nil
    let callback = enterResult
    enterResult = nil
    callback?(ok)
  }

  func visible(_ visible: Bool) {
    if visible { attemptEntry() }
    else if phase == .requested || phase == .preparing {
      completePreparation(false)
      completeEntry(false)
      stop { _ in }
    }
  }

  private func playbackChanged() {
    guard phase != .finished else { return }
    if phase == .stopping {
      // A retired system window cannot resume audio after Flutter takes ownership.
      if player.rate != 0 { player.pause() }
      return
    }
    if player.rate > 0 { rate = player.rate }
    publish()
  }

  func play() {
    guard phase != .stopping && phase != .finished else { return }
    initiallyPlaying = true
    completed = false
    player.playImmediately(atRate: rate)
    publish()
  }

  func pause() { initiallyPlaying = false; player.pause(); publish() }

  func setRate(_ value: Float) {
    guard phase != .stopping && phase != .finished else { return }
    rate = value.isFinite ? min(5, max(0.25, value)) : 1
    if player.rate != 0 { player.playImmediately(atRate: rate) }
    publish()
  }

  func seek(milliseconds: Double, result: @escaping FlutterResult) {
    guard phase != .stopping && phase != .finished, milliseconds.isFinite else { result(values); return }
    let duration = player.currentItem?.duration.seconds ?? .infinity
    let target = min(duration.isFinite ? max(0, duration) : .infinity, max(0, milliseconds / 1000))
    completed = false
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        self?.publish()
        result(self?.values)
      }
    }
  }

  func attach(_ view: ApplePipVideoView) {
    guard view.session == session, view.pipId == pipId, phase != .finished else { return }
    host = view
    // BetterPlayer mounts its PiP source on the scene's root view. Flutter
    // platform-view clipping and texture rebuilds must not own this AVKit layer.
    guard let root = view.window?.rootViewController?.view else { return }
    sourceView = root
    if playerLayer.superlayer !== root.layer {
      playerLayer.removeFromSuperlayer()
      root.layer.addSublayer(playerLayer)
    }
    if controller == nil && AVPictureInPictureController.isPictureInPictureSupported() {
      controller = AVPictureInPictureController(playerLayer: playerLayer)
      controller?.delegate = self
      if #available(iOS 14.2, *) { controller?.canStartPictureInPictureAutomaticallyFromInline = false }
      if let controller = controller {
        observations.append(controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
          DispatchQueue.main.async { self?.attemptEntry() }
        })
      }
    }
    layout(view)
  }

  func layout(_ view: ApplePipVideoView) {
    guard host === view, let root = sourceView, view.window != nil else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = view.convert(view.bounds, to: root)
    CATransaction.commit()
    DispatchQueue.main.async { [weak self] in self?.displayChanged() }
  }

  func stop(_ completion: @escaping ([String: Any]) -> Void) {
    if phase == .finished || stopNotified { completion(values); return }
    stopResults.append(completion)
    guard phase != .stopping else { return }
    let awaitingStart = phase == .starting
    beginStopping()
    if active || awaitingStart {
      controller?.stopPictureInPicture()
      scheduleStopDeadline()
    } else { finishStop() }
  }

  private func beginStopping() {
    stopWasPlaying = values["playing"] as? Bool ?? false
    retainedWhileStopping = self
    phase = .stopping
    completePreparation(false)
    completeEntry(false)
    player.pause()
  }

  private func scheduleStopDeadline() {
    stopDeadline?.cancel()
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self, self.phase == .stopping else { return }
      if !self.active { self.finishStop(); return }
      // Keep the renderer alive if AVKit's scene transition outlives the callback.
      // Paused audio and a bounded reply keep the foreground player usable.
      if !self.stopNotified {
        self.finalValues = self.stoppedValues()
        self.publishPip(false)
        self.notifyStopped()
      }
      self.controller?.stopPictureInPicture()
      self.scheduleStopDeadline()
    }
    stopDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: deadline)
  }

  private func stoppedValues() -> [String: Any] {
    var snapshot = values
    snapshot["playing"] = stopWasPlaying
    snapshot["buffering"] = false
    snapshot["finished"] = true
    snapshot["restore"] = restore
    return snapshot
  }

  private func finishStop() {
    guard phase != .finished else { return }
    finalValues = stoppedValues()
    phase = .finished
    prepareDeadline?.cancel()
    enterDeadline?.cancel()
    stopDeadline?.cancel()
    prepareDeadline = nil
    enterDeadline = nil
    stopDeadline = nil
    observations.forEach { $0.invalidate() }
    observations.removeAll()
    if let observer = timeObserver { player.removeTimeObserver(observer) }
    timeObserver = nil
    if let observer = endObservation { NotificationCenter.default.removeObserver(observer) }
    endObservation = nil
    controller?.delegate = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    playerLayer.player = nil
    playerLayer.removeFromSuperlayer()
    publishPip(false)
    publish()
    notifyStopped()
    retainedWhileStopping = nil
  }

  private func notifyStopped() {
    stopNotified = true
    let callbacks = stopResults
    stopResults.removeAll()
    let snapshot = values
    callbacks.forEach { $0(snapshot) }
  }

  func end() {
    channel = nil
    stop { _ in }
  }

  private func publish() {
    guard phase != .stopping else { return }
    channel?.invokeMethod("pipState", arguments: values)
  }

  private func publishPip(_ active: Bool) {
    channel?.invokeMethod("pip", arguments: ["session": session, "pipId": pipId, "active": active])
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller else { return }
    if phase == .stopping {
      pictureInPictureController.stopPictureInPicture()
      return
    }
    guard phase == .starting else { return }
    phase = .active
    diagnostic("started")
    publishPip(true)
    publish()
    completeEntry(true)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) {
    guard pictureInPictureController === controller else { return }
    fail("enter_failed", error: error)
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller, phase != .finished else { return }
    if phase != .stopping { beginStopping(); scheduleStopDeadline() }
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller else { return }
    if phase != .stopping { beginStopping() }
    finishStop()
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    guard pictureInPictureController === controller, phase != .finished else { completionHandler(false); return }
    restore = true
    completionHandler(AppleDocuments.presenter != nil)
  }
}

final class ApplePipVideoView: UIView, FlutterPlatformView {
  let session: String
  let pipId: String
  private weak var playback: AppleSystemPip?
  init(frame: CGRect, session: String, pipId: String, playback: AppleSystemPip) {
    self.session = session
    self.pipId = pipId
    self.playback = playback
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    playback.attach(self)
  }
  required init?(coder: NSCoder) { fatalError("Use the platform view factory") }
  func view() -> UIView { self }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    playback?.attach(self)
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    playback?.layout(self)
  }
}

final class ApplePipVideoFactory: NSObject, FlutterPlatformViewFactory {
  private let playback: AppleSystemPip
  init(playback: AppleSystemPip) { self.playback = playback; super.init() }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let arguments = args as? [String: Any] ?? [:]
    return ApplePipVideoView(frame: frame, session: arguments["session"] as? String ?? "", pipId: arguments["pipId"] as? String ?? "", playback: playback)
  }
}
