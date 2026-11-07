import Flutter
import UIKit
import AsterLinkCore

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let coreQueue = DispatchQueue(label: "com.asterlink.app.download")
  private var originalBrightness: CGFloat?
  private lazy var documents = AppleDocuments()
  private var scanner: AppleQrScanner?
  private var externalChannel: FlutterMethodChannel?
  private var pendingOpens = [[String: Any]]()
  private var recentOpens = [String: TimeInterval]()
  private let playbackVolume = ApplePlaybackVolume()
  private let systemPip = AppleSystemPip()
  private let externalPlayer = AppleExternalPlayer()
  private var playbackSession = ""
  private var playbackChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    engineBridge.applicationRegistrar.register(
      ApplePipVideoFactory(playback: systemPip), withId: "com.asterlink.app/pip_video")
    externalChannel = FlutterMethodChannel(name: "com.asterlink.app/external_open", binaryMessenger: messenger)
    externalChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takeExternalOpens" else { result(FlutterMethodNotImplemented); return }
      let values = self?.pendingOpens ?? []
      self?.pendingOpens.removeAll()
      result(values)
    }
    let native = FlutterMethodChannel(name: "com.asterlink.app/native", binaryMessenger: messenger)
    documents.channel = native
    native.setMethodCallHandler { [weak self] call, result in
        guard let self else { result(FlutterMethodNotImplemented); return }
        let args = call.arguments as? [String: Any] ?? [:]
        if self.documents.handle(call, result: result) { return }
        if call.method == "openExternalPlayer" {
          self.externalPlayer.open(arguments: args, result: result)
        } else if call.method == "cancelExternalPlayer" {
          if args["session"] as? String == self.playbackSession { self.externalPlayer.cancel() }
          result(nil)
        } else if call.method == "lanScanQr" {
          guard self.scanner == nil, let parent = AppleDocuments.presenter else {
            result(FlutterError(code: "busy", message: "请先关闭当前扫码窗口", details: nil)); return
          }
          let scanner = AppleQrScanner { [weak self] value, error in
            self?.scanner = nil
            if let error = error { result(FlutterError(code: "camera", message: error, details: nil)) }
            else { result(value) }
          }
          self.scanner = scanner
          parent.present(scanner, animated: true)
        } else if call.method == "freeSpace" {
          guard let path = args["path"] as? String else {
            result(FlutterError(code: "arguments", message: "存储路径无效", details: nil)); return
          }
          var folder = URL(fileURLWithPath: path)
          while !FileManager.default.fileExists(atPath: folder.path) && folder.path != "/" {
            folder.deleteLastPathComponent()
          }
          do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
            result(["bytes": attributes[.systemFreeSize] as? NSNumber ?? -1])
          } catch { result(FlutterError(code: "storage", message: "无法读取剩余空间", details: nil)) }
        } else if call.method == "gopeed" {
          guard let method = args["method"] as? String,
                let encoded = args["args"] as? String else {
            result(FlutterError(code: "arguments", message: "下载请求格式错误", details: nil)); return
          }
          coreQueue.async {
            let text = method.withCString { name in
              encoded.withCString { input -> String in
                guard let pointer = AsterLinkCall(UnsafeMutablePointer(mutating: name), UnsafeMutablePointer(mutating: input)) else { return "{}" }
                defer { AsterLinkFree(pointer) }
                return String(cString: pointer)
              }
            }
            let response = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            DispatchQueue.main.async {
              if let error = response["error"] as? String {
                result(FlutterError(code: "download", message: error, details: nil))
              } else { result(response["result"]) }
            }
          }
        } else { result(FlutterMethodNotImplemented) }
      }
    let playback = FlutterMethodChannel(name: "com.asterlink.app/playback", binaryMessenger: messenger)
    playbackChannel = playback
    playback.setMethodCallHandler { [weak self] call, result in
        guard let self else { result(FlutterMethodNotImplemented); return }
        let args = call.arguments as? [String: Any] ?? [:]
        let session = args["session"] as? String ?? ""
        if call.method != "begin" && session != self.playbackSession { result(nil); return }
        if self.systemPip.handle(call, arguments: args, result: result) { return }
        switch call.method {
        case "begin":
          if self.originalBrightness == nil { self.originalBrightness = UIScreen.main.brightness }
          self.playbackSession = session
          if let channel = self.playbackChannel {
            self.playbackVolume.begin(session: session, channel: channel)
            self.systemPip.begin(session: session, channel: channel)
          }
          self.externalPlayer.begin(session: session)
          UIApplication.shared.isIdleTimerDisabled = true
          var values: [String: Any] = self.playbackVolume.values
          values["pip"] = (args["video"] as? Bool ?? false) && self.systemPip.supported
          values["brightness"] = Double(UIScreen.main.brightness)
          result(values)
        case "volume":
          self.playbackVolume.set((args["value"] as? NSNumber)?.doubleValue ?? .nan, session: session, result: result)
        case "brightness":
          if let value = args["value"] as? Double { UIScreen.main.brightness = CGFloat(min(1, max(0, value))) }
          result(nil)
        case "end":
          if let brightness = self.originalBrightness { UIScreen.main.brightness = brightness }
          self.originalBrightness = nil
          self.systemPip.end()
          self.externalPlayer.cancel()
          self.playbackVolume.end()
          self.playbackSession = ""
          UIApplication.shared.isIdleTimerDisabled = false
          result(nil)
        case "state", "fullscreen": result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
  }

  func playbackVisible(_ visible: Bool) {
    playbackVolume.active(visible)
    systemPip.visible(visible)
    if !visible && !playbackSession.isEmpty && !systemPip.keepsPlayingInBackground {
      playbackChannel?.invokeMethod("action", arguments: ["session": playbackSession, "action": "hidden"])
    }
  }

  @discardableResult
  func receive(urls: [URL]) -> Bool {
    var accepted = false
    let now = ProcessInfo.processInfo.systemUptime
    recentOpens = recentOpens.filter { now - $0.value < 2 }
    for url in urls.prefix(16) where url.scheme?.lowercased() == "wenxi" {
      let text = url.absoluteString
      guard text.utf8.count <= 16384 else { continue }
      accepted = true
      // Scene and application callbacks may report the same launch. Keep one
      // request while still allowing the link to be opened again later.
      guard recentOpens[text] == nil else { continue }
      if recentOpens.count >= 32 { recentOpens.removeAll() }
      recentOpens[text] = now
      if pendingOpens.count >= 16 { pendingOpens.removeFirst() }
      pendingOpens.append(["id": UUID().uuidString, "launchUri": text])
    }
    if accepted { externalChannel?.invokeMethod("externalOpenAvailable", arguments: nil) }
    return accepted
  }

  override func application(_ app: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if receive(urls: [url]) { return true }
    return super.application(app, open: url, options: options)
  }
}
