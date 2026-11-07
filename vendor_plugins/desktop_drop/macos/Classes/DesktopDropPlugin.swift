import Cocoa
import FlutterMacOS

public class DesktopDropPlugin: NSObject, FlutterPlugin {
  private let view: DropView
  private init(view: DropView) { self.view = view }
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "desktop_drop", binaryMessenger: registrar.messenger)
    guard let parent = registrar.view else { return }
    let view = DropView(frame: parent.bounds)
    view.channel = channel
    view.autoresizingMask = [.width, .height]
    parent.addSubview(view)
    registrar.addMethodCallDelegate(DesktopDropPlugin(view: view), channel: channel)
  }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}

private class DropView: NSView {
  var channel: FlutterMethodChannel?
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { super.init(coder: coder) }
  override func hitTest(_ point: NSPoint) -> NSView? { return nil }
  private func update(_ sender: NSDraggingInfo, method: String = "updated") {
    let point = convert(sender.draggingLocation, from: nil)
    channel?.invokeMethod(method, arguments: [Double(point.x), Double(bounds.height - point.y)])
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender, method: "entered"); return .copy }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender); return .copy }
  override func draggingExited(_ sender: NSDraggingInfo?) { channel?.invokeMethod("exited", arguments: nil) }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
    update(sender)
    channel?.invokeMethod("performOperation", arguments: urls.map { $0.path })
    return true
  }
}
