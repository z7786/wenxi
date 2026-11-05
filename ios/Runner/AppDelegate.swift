import Flutter
import UIKit
import AsterLinkCore

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let coreQueue = DispatchQueue(label: "com.asterlink.app.download")
  private var originalBrightness: CGFloat?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterMethodChannel(name: "com.asterlink.app/native", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self else { result(FlutterMethodNotImplemented); return }
        let args = call.arguments as? [String: Any] ?? [:]
        if call.method == "freeSpace" {
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
    FlutterMethodChannel(name: "com.asterlink.app/playback", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self else { result(FlutterMethodNotImplemented); return }
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "begin":
          originalBrightness = UIScreen.main.brightness
          UIApplication.shared.isIdleTimerDisabled = true
          result(["pip": false, "brightness": Double(UIScreen.main.brightness), "systemVolumeSupported": false])
        case "brightness":
          if let value = args["value"] as? Double { UIScreen.main.brightness = CGFloat(min(1, max(0, value))) }
          result(nil)
        case "end":
          if let brightness = originalBrightness { UIScreen.main.brightness = brightness }
          originalBrightness = nil
          UIApplication.shared.isIdleTimerDisabled = false
          result(nil)
        case "state", "fullscreen": result(nil)
        case "isPip", "enterPip": result(false)
        default: result(FlutterMethodNotImplemented)
        }
      }
  }
}
