import Flutter
import UIKit
import AVFoundation
import AVKit

/// AVKit owns decoding only while an explicitly requested PiP session is open.
/// The usual Flutter media_kit decoder pauses before this bridge receives a URL.
final class AppleSystemPip: NSObject, AVPictureInPictureControllerDelegate {
  private var session = ""
  private var pipId = ""
  private var channel: FlutterMethodChannel?
  private var player: AVPlayer?
  private let playerLayer = AVPlayerLayer()
  private var controller: AVPictureInPictureController?
  private var statusObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var prepareResult: FlutterResult?
  private var enterResult: FlutterResult?
  private var prepareDeadline: DispatchWorkItem?
  private var enterDeadline: DispatchWorkItem?
  private var endObservation: NSObjectProtocol?
  private var revision = 0
  private var rate: Float = 1
  private var initialPosition = CMTime.zero
  private var initiallyPlaying = false
  private var requested = false
  private var finished = false
  private var restore = false
  private var completed = false
  private var stopping = false
  private var ending = false
  private var itemPrepared = false
  private var finalValues: [String: Any]?
  private weak var host: ApplePipVideoView?
  private weak var pendingHost: ApplePipVideoView?

  var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
  var active: Bool { controller?.isPictureInPictureActive == true }
  var keepsPlayingInBackground: Bool { requested || active }

  var values: [String: Any] {
    if let snapshot = finalValues { return snapshot }
    let position = player?.currentTime().seconds ?? 0
    let duration = player?.currentItem?.duration.seconds ?? 0
    return [
      "session": session,
      "pipId": pipId,
      "positionMs": position.isFinite ? max(0, position * 1000) : 0,
      "durationMs": duration.isFinite ? max(0, duration * 1000) : 0,
      "playing": player?.rate != 0 && player != nil && !completed,
      "buffering": player?.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      "completed": completed,
      "rate": Double(rate),
      "finished": finished,
      "restore": restore,
    ]
  }

  func begin(session: String, channel: FlutterMethodChannel) {
    end()
    ending = false
    self.session = session
    self.channel = channel
  }

  func handle(_ call: FlutterMethodCall, arguments: [String: Any], result: @escaping FlutterResult) -> Bool {
    if ["stopPip", "pipPlay", "pipPause", "pipSeek", "pipRate"].contains(call.method),
       arguments["pipId"] as? String != pipId { result(nil); return true }
    switch call.method {
    case "preparePip": prepare(arguments, result: result)
    case "enterPip": enter(result: result)
    case "isPip": result(active || requested)
    case "exitPip":
      restore = true
      if active { controller?.stopPictureInPicture() }
      result(nil)
    case "stopPip":
      let snapshot = values
      cleanup()
      publishPip(false)
      result(snapshot)
    case "pipPlay":
      initiallyPlaying = true
      completed = false
      player?.playImmediately(atRate: rate)
      publish()
      result(nil)
    case "pipPause":
      initiallyPlaying = false
      player?.pause()
      publish()
      result(nil)
    case "pipSeek":
      let milliseconds = (arguments["positionMs"] as? NSNumber)?.doubleValue ?? 0
      seek(milliseconds: milliseconds, result: result)
    case "pipRate":
      let value = (arguments["rate"] as? NSNumber)?.floatValue ?? 1
      rate = value.isFinite ? min(5, max(0.25, value)) : 1
      if player?.rate != 0 { player?.playImmediately(atRate: rate) }
      publish()
      result(nil)
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
    cleanup()
    self.pipId = pipId
    finished = false
    restore = false
    completed = false
    stopping = false
    itemPrepared = false
    finalValues = nil
    let current = revision
    prepareResult = result
    initiallyPlaying = arguments["playing"] as? Bool ?? true
    let milliseconds = (arguments["positionMs"] as? NSNumber)?.doubleValue ?? 0
    initialPosition = CMTime(seconds: milliseconds.isFinite ? max(0, milliseconds / 1000) : 0, preferredTimescale: 600)
    let speed = (arguments["rate"] as? NSNumber)?.floatValue ?? 1
    rate = speed.isFinite ? min(5, max(0.25, speed)) : 1
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .moviePlayback)
      try audio.setActive(true)
    } catch { completePreparation(false); return }
    let item = AVPlayerItem(url: url)
    item.preferredForwardBufferDuration = 10
    let player = AVPlayer(playerItem: item)
    self.player = player
    playerLayer.videoGravity = .resizeAspect
    playerLayer.player = player
    controller = AVPictureInPictureController(playerLayer: playerLayer)
    controller?.delegate = self
    if #available(iOS 14.2, *) { controller?.canStartPictureInPictureAutomaticallyFromInline = false }
    if let pending = pendingHost, pending.pipId == pipId { attach(pending) }
    else if let host = host { attach(host) }
    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, self.revision == current, self.player?.currentItem === item else { return }
        if item.status == .readyToPlay && !self.itemPrepared {
          self.itemPrepared = true
          let duration = item.duration.seconds
          if duration.isFinite && duration > 0 && self.initialPosition.seconds >= duration {
            self.initialPosition = .zero
          }
          player.seek(to: self.initialPosition, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] ok in
            DispatchQueue.main.async {
              guard let self = self, self.revision == current else { return }
              if ok && self.initiallyPlaying && UIApplication.shared.applicationState == .active {
                player.playImmediately(atRate: self.rate)
              }
              self.completePreparation(ok)
            }
          }
        } else if item.status == .failed {
          self.completePreparation(false)
          if self.requested || self.active {
            let snapshot = self.values
            self.finished = true
            self.restore = true
            self.finalValues = snapshot.merging(["finished": true, "restore": true]) { _, new in new }
            self.controller?.stopPictureInPicture()
            self.publish()
          }
        }
      }
    }
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
      guard let self = self, self.revision == current else { return }
      self.publish()
    }
    endObservation = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
      guard let self = self, self.revision == current else { return }
      self.completed = true
      self.publish()
    }
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self, self.revision == current else { return }
      self.completePreparation(false)
    }
    prepareDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
  }

  private func completePreparation(_ ok: Bool) {
    prepareDeadline?.cancel()
    prepareDeadline = nil
    let callback = prepareResult
    prepareResult = nil
    if !ok { player?.pause() }
    if callback != nil { publish() }
    callback?(ok)
  }

  private func enter(result: @escaping FlutterResult) {
    guard supported, UIApplication.shared.applicationState == .active,
          enterResult == nil, let controller = controller, player?.currentItem?.status == .readyToPlay else {
      result(false); return
    }
    if active { result(true); return }
    enterResult = result
    requested = true
    let current = revision
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self, self.revision == current else { return }
      self.requested = false
      self.player?.pause()
      self.completeEntry(false)
    }
    enterDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    attemptEntry(controller, revision: current, attempts: 60)
  }

  private func attemptEntry(_ controller: AVPictureInPictureController, revision: Int, attempts: Int) {
    guard self.revision == revision, enterResult != nil, requested else { return }
    if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
    } else if attempts > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.attemptEntry(controller, revision: revision, attempts: attempts - 1)
      }
    } else {
      requested = false
      player?.pause()
      completeEntry(false)
    }
  }

  private func completeEntry(_ ok: Bool) {
    enterDeadline?.cancel()
    enterDeadline = nil
    let callback = enterResult
    enterResult = nil
    callback?(ok)
  }

  private func seek(milliseconds: Double, result: @escaping FlutterResult) {
    guard let player = player, milliseconds.isFinite else { result(nil); return }
    let duration = player.currentItem?.duration.seconds ?? .infinity
    let target = min(duration.isFinite ? max(0, duration) : .infinity, max(0, milliseconds / 1000))
    let current = revision
    completed = false
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        if self?.revision == current { self?.publish() }
        result(nil)
      }
    }
  }

  private func publish() {
    guard !ending, !stopping, !session.isEmpty else { return }
    channel?.invokeMethod("pipState", arguments: values)
  }

  private func publishPip(_ active: Bool) {
    guard !ending, !session.isEmpty else { return }
    channel?.invokeMethod("pip", arguments: ["session": session, "pipId": pipId, "active": active])
  }

  func attach(_ view: ApplePipVideoView) {
    guard view.session == session else { return }
    guard view.pipId == pipId else { pendingHost = view; return }
    pendingHost = nil
    host = view
    playerLayer.removeFromSuperlayer()
    view.layer.addSublayer(playerLayer)
    layout(view)
  }

  func layout(_ view: ApplePipVideoView) {
    guard host === view else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = view.bounds
    CATransaction.commit()
  }

  private func cleanup() {
    revision += 1
    stopping = true
    requested = false
    statusObservation?.invalidate()
    statusObservation = nil
    completePreparation(false)
    completeEntry(false)
    if let token = timeObserver { player?.removeTimeObserver(token) }
    timeObserver = nil
    if let token = endObservation { NotificationCenter.default.removeObserver(token) }
    endObservation = nil
    let retired = controller
    retired?.delegate = nil
    if active {
      retired?.stopPictureInPicture()
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = retired }
    }
    controller = nil
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    playerLayer.player = nil
    playerLayer.removeFromSuperlayer()
  }

  func end() {
    ending = true
    cleanup()
    session = ""
    pipId = ""
    channel = nil
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller, !stopping else { return }
    requested = false
    publishPip(true)
    publish()
    completeEntry(true)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    guard pictureInPictureController === controller else { return }
    requested = false
    player?.pause()
    publishPip(false)
    completeEntry(false)
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller, !stopping else { return }
    // Retain the last playback state until Dart has captured its bookmark.
    publish()
    finalValues = values
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller, !stopping else { return }
    finished = true
    requested = false
    var snapshot = finalValues ?? values
    snapshot["finished"] = true
    snapshot["restore"] = restore
    finalValues = snapshot
    publishPip(false)
    publish()
    player?.pause()
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    guard pictureInPictureController === controller else { completionHandler(false); return }
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
    backgroundColor = .black
    playback.attach(self)
  }
  required init?(coder: NSCoder) { fatalError("Use the platform view factory") }
  func view() -> UIView { self }
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
