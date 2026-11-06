import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import IOKit.pwr_mgt
import OpenGL

class MainFlutterWindow: NSWindow {
  private var nativeChannel: FlutterMethodChannel?
  private var externalChannel: FlutterMethodChannel?
  private var pendingOpens = [[String: Any]]()
  private var sleepAssertion: IOPMAssertionID = 0
  private var externalPanel: NSOpenPanel?
  private let fileQueue = DispatchQueue(label: "com.asterlink.app.files")

  override func awakeFromNib() {
    // media_kit's native OpenGL output assumes this pixel format exists.
    // Virtual Macs may have no accelerated OpenGL device; keep decoding
    // enabled and use its pixel buffer output on those machines.
    let attributes: [CGLPixelFormatAttribute] = [
      kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
      kCGLPFAAccelerated, kCGLPFADoubleBuffer,
      kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 64), kCGLPFAColorFloat,
      kCGLPFABackingStore, kCGLPFAAllowOfflineRenderers,
      kCGLPFASupportsAutomaticGraphicsSwitching, CGLPixelFormatAttribute(rawValue: 0)
    ]
    var pixelFormat: CGLPixelFormatObj?
    var count: GLint = 0
    let status = CGLChoosePixelFormat(attributes, &pixelFormat, &count)
    if status != kCGLNoError || pixelFormat == nil {
      setenv("ASTERLINK_MACOS_SOFTWARE_RENDERING", "1", 1)
      NSLog("AsterLink: accelerated OpenGL unavailable; using compatible video output")
    }
    if let pixelFormat = pixelFormat { CGLDestroyPixelFormat(pixelFormat) }
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    nativeChannel = FlutterMethodChannel(name: "com.asterlink.app/native", binaryMessenger: flutterViewController.engine.binaryMessenger)
    nativeChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(FlutterError(code: "closed", message: "窗口已关闭", details: nil)) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "storageVolume":
        guard let path = args["path"] as? String, path.hasPrefix("/") else {
          return result(FlutterError(code: "storage", message: "存储路径无效", details: nil))
        }
        self.fileQueue.async {
          do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsHardLinksKey])
            guard let identifier = attributes[.systemNumber] as? NSNumber else {
              DispatchQueue.main.async { result(nil) }; return
            }
            let value: [String: Any] = ["id": identifier.stringValue, "hardLinks": values.volumeSupportsHardLinks ?? false]
            DispatchQueue.main.async { result(value) }
          } catch { DispatchQueue.main.async { result(nil) } }
        }
      case "createHardLink":
        guard let source = args["source"] as? String, let target = args["target"] as? String,
              source.hasPrefix("/"), target.hasPrefix("/"), source != target else {
          return result(FlutterError(code: "storage", message: "文件保存位置无效", details: nil))
        }
        self.fileQueue.async {
          do {
            try FileManager.default.linkItem(atPath: source, toPath: target)
            DispatchQueue.main.async { result(true) }
          } catch { DispatchQueue.main.async { result(false) } }
        }
      case "foreground":
        self.preventSleep((args["active"] as? Int ?? 0) > 0)
        result(nil)
      case "downloadProtectionStatus":
        result(["desktop": true, "wakeLockHeld": self.sleepAssertion != 0])
      case "selectExternalPlayer":
        guard self.externalPanel == nil else { return result(nil) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "选择播放器"
        self.externalPanel = panel
        panel.beginSheetModal(for: self) { [weak self] response in
          self?.externalPanel = nil
          result(response == .OK ? panel.url?.path : nil)
        }
      case "openExternalPlayer":
        guard let path = args["application"] as? String, path.hasSuffix(".app"),
              let text = args["url"] as? String, let url = URL(string: text),
              ["http", "https", "file"].contains(url.scheme ?? "") else {
          return result(FlutterError(code: "invalid", message: "播放器或播放地址无效", details: nil))
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: config) { app, error in
          DispatchQueue.main.async {
            if error == nil && app != nil { result(true) }
            else { result(FlutterError(code: "launch", message: "无法启动所选播放器", details: nil)) }
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
    externalChannel = FlutterMethodChannel(name: "com.asterlink.app/external_open", binaryMessenger: flutterViewController.engine.binaryMessenger)
    externalChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takeExternalOpens" else { return result(FlutterMethodNotImplemented) }
      let values = self?.pendingOpens ?? []
      self?.pendingOpens.removeAll()
      result(values)
    }
    let images = FlutterMethodChannel(name: "com.asterlink.app/player_images", binaryMessenger: flutterViewController.engine.binaryMessenger)
    images.setMethodCallHandler { call, result in
      guard call.method == "copyImage", let args = call.arguments as? [String: Any],
            let width = args["width"] as? Int, let height = args["height"] as? Int,
            width > 0, height > 0, width <= 16384, height <= 16384,
            width * height <= 16 * 1024 * 1024,
            let bytes = args["rgba"] as? FlutterStandardTypedData,
            bytes.data.count == width * height * 4,
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
            let destination = image.bitmapData else {
        return result(FlutterError(code: "image", message: "无法读取截图", details: nil))
      }
      bytes.data.copyBytes(to: destination, count: bytes.data.count)
      let picture = NSImage(size: NSSize(width: CGFloat(width), height: CGFloat(height)))
      picture.addRepresentation(image)
      NSPasteboard.general.clearContents()
      result(NSPasteboard.general.writeObjects([picture]) ? nil : FlutterError(code: "clipboard", message: "无法复制截图", details: nil))
    }

    super.awakeFromNib()
  }

  func receive(urls: [URL]) {
    for url in urls.prefix(16) {
      var item: [String: Any] = ["id": UUID().uuidString]
      if url.isFileURL {
        item["kind"] = "play"
        item["uri"] = url.absoluteString
        item["name"] = url.lastPathComponent
      } else {
        item["launchUri"] = url.absoluteString
      }
      if pendingOpens.count >= 16 { pendingOpens.removeFirst() }
      pendingOpens.append(item)
    }
    externalChannel?.invokeMethod("externalOpenAvailable", arguments: nil)
    makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func preventSleep(_ active: Bool) {
    if active && sleepAssertion == 0 {
      IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
          IOPMAssertionLevel(kIOPMAssertionLevelOn), "文析助手正在传输文件" as CFString, &sleepAssertion)
    } else if !active && sleepAssertion != 0 {
      IOPMAssertionRelease(sleepAssertion)
      sleepAssertion = 0
    }
  }

  deinit {
    if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
  }
}
