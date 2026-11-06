import Flutter
import UIKit
import Photos

final class AppleDocuments: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  private let queue = DispatchQueue(label: "com.asterlink.app.documents")
  private let bookmarkKey = "asterlink.directoryBookmarks"
  private var folders = [String: URL]()
  private var movedPaths = [String: String]()
  private var exportPreparing = false
  private var picker: UIDocumentPickerViewController?
  private var pickerResult: FlutterResult?
  private var exportDirectory: URL?

  override init() {
    super.init()
    movedPaths = UserDefaults.standard.dictionary(forKey: "asterlink.storageMoves") as? [String: String] ?? [:]
    let home = NSHomeDirectory()
    if let oldHome = UserDefaults.standard.string(forKey: "asterlink.previousHome"), oldHome != home {
      movedPaths[oldHome] = home
    }
    UserDefaults.standard.set(home, forKey: "asterlink.previousHome")
    restoreDirectories()
    for path in Array(movedPaths.keys) {
      movedPaths[path] = resolvedPath(movedPaths[path]!)
    }
    UserDefaults.standard.set(movedPaths, forKey: "asterlink.storageMoves")
  }

  static var presenter: UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    var view = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = view?.presentedViewController { view = presented }
    return view
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "chooseDirectory": chooseDirectory(result)
    case "restoreStorage":
      let storage: [String: Any] = ["paths": movedPaths, "home": NSHomeDirectory()]
      result(storage)
    case "resolveDirectory":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "directory", message: "文件夹路径无效", details: nil)); return true
      }
      result(resolvedPath(path))
    case "saveDocument": export(args, result: result)
    case "savePlayerScreenshot": saveImage(args, result: result)
    case "storageVolume": storageVolume(args, result: result)
    case "createHardLink": createHardLink(args, result: result)
    default: return false
    }
    return true
  }

  private func resolvedPath(_ path: String) -> String {
    var value = path
    var visited = Set<String>()
    let prefixes = movedPaths.keys.sorted { $0.count > $1.count }
    for _ in 0..<prefixes.count {
      visited.insert(value)
      guard let prefix = prefixes.first(where: { value == $0 || value.hasPrefix($0 + "/") }),
            let replacement = movedPaths[prefix] else { break }
      let next = replacement + String(value.dropFirst(prefix.count))
      if visited.contains(next) { return path }
      value = next
    }
    return value
  }

  private func chooseDirectory(_ result: @escaping FlutterResult) {
    guard !exportPreparing else {
      result(FlutterError(code: "busy", message: "正在准备文件，请稍后重试", details: nil)); return
    }
    let view = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    view.allowsMultipleSelection = false
    present(view, result: result)
  }

  private func present(_ view: UIDocumentPickerViewController, result: @escaping FlutterResult) {
    guard picker == nil, let parent = Self.presenter,
          parent.viewIfLoaded?.window != nil, !parent.isBeingDismissed else {
      result(FlutterError(code: "busy", message: "请先关闭当前文件窗口后重试", details: nil))
      return
    }
    picker = view
    pickerResult = result
    view.delegate = self
    view.modalPresentationStyle = .formSheet
    parent.present(view, animated: true)
    view.presentationController?.delegate = self
  }

  private func export(_ args: [String: Any], result: @escaping FlutterResult) {
    guard picker == nil, !exportPreparing,
          let bytes = args["bytes"] as? FlutterStandardTypedData,
          !bytes.data.isEmpty, let name = args["name"] as? String,
          name == URL(fileURLWithPath: name).lastPathComponent,
          !["", ".", ".."].contains(name) else {
      result(FlutterError(code: "arguments", message: "文件名或保存内容无效", details: nil))
      return
    }
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("document-export-" + UUID().uuidString, isDirectory: true)
    let file = folder.appendingPathComponent(name)
    exportPreparing = true
    queue.async {
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.data.write(to: file, options: .atomic)
        DispatchQueue.main.async {
          self.exportPreparing = false
          // .exportToService copies the temporary document rather than moving
          // an existing user file; it is available on the minimum iOS version.
          let view = UIDocumentPickerViewController(url: file, in: .exportToService)
          self.exportDirectory = folder
          self.present(view, result: result)
          if self.picker !== view { self.clearExport() }
        }
      } catch {
        try? FileManager.default.removeItem(at: folder)
        DispatchQueue.main.async {
          self.exportPreparing = false
          result(FlutterError(code: "export", message: "无法准备导出文件，请检查剩余空间", details: nil))
        }
      }
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard picker === controller else { return }
    if controller.documentPickerMode == .open {
      guard let url = urls.first else { complete(nil); return }
      let accessed = url.startAccessingSecurityScopedResource()
      do {
        guard accessed || url.path.hasPrefix(NSHomeDirectory() + "/") else {
          complete(FlutterError(code: "directory", message: "文件夹授权失败，请重新选择或使用应用内下载目录", details: nil))
          return
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
          if accessed { url.stopAccessingSecurityScopedResource() }
          complete(FlutterError(code: "directory", message: "请选择可读写的文件夹", details: nil))
          return
        }
        let bookmark = try url.bookmarkData(options: .minimalBookmark,
          includingResourceValuesForKeys: nil, relativeTo: nil)
        var saved = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
        saved[url.path] = bookmark
        UserDefaults.standard.set(saved, forKey: bookmarkKey)
        if accessed {
          if let previous = folders.updateValue(url, forKey: url.path) {
            previous.stopAccessingSecurityScopedResource()
          }
        }
        complete(url.path)
      } catch {
        if accessed { url.stopAccessingSecurityScopedResource() }
        complete(FlutterError(code: "directory", message: "无法获得文件夹权限，请重新选择", details: nil))
      }
    } else {
      complete(urls.first?.path)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if picker === controller { complete(nil) }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if picker === presentationController.presentedViewController { complete(nil) }
  }

  private func complete(_ value: Any?) {
    let callback = pickerResult
    pickerResult = nil
    picker = nil
    clearExport()
    callback?(value)
  }

  private func clearExport() {
    if let directory = exportDirectory {
      exportDirectory = nil
      queue.async { try? FileManager.default.removeItem(at: directory) }
    }
  }

  private func restoreDirectories() {
    var saved = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
    for (path, bookmark) in saved {
      do {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [],
          relativeTo: nil, bookmarkDataIsStale: &stale)
        // Multiple saved bookmarks can resolve to the same moved directory.
        // Keep one scope per current path so each start has a matching stop.
        let accessed = folders[url.path] != nil || url.startAccessingSecurityScopedResource()
        guard accessed || url.path.hasPrefix(NSHomeDirectory() + "/") else { continue }
        if accessed { folders[url.path] = folders[url.path] ?? url }
        if url.path != path { movedPaths[path] = url.path }
        let data: Data
        if stale {
          data = try url.bookmarkData(options: .minimalBookmark,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        } else {
          data = bookmark
        }
        if url.path != path {
          saved.removeValue(forKey: path)
        }
        saved[url.path] = data
      } catch {
        // Retain the bookmark so a temporarily unavailable cloud provider does
        // not erase the user's directory choice; access can be granted again.
      }
    }
    UserDefaults.standard.set(saved, forKey: bookmarkKey)
  }

  private func saveImage(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let bytes = args["bytes"] as? FlutterStandardTypedData,
          bytes.data.count <= 32 * 1024 * 1024, UIImage(data: bytes.data) != nil else {
      result(FlutterError(code: "image", message: "截图内容无效", details: nil)); return
    }
    func save(_ status: PHAuthorizationStatus) {
      let allowed: Bool
      if #available(iOS 14, *) { allowed = status == .authorized || status == .limited }
      else { allowed = status == .authorized }
      guard allowed else {
        DispatchQueue.main.async {
          result(FlutterError(code: "photos", message: "请在系统设置中允许文析助手添加照片", details: nil))
        }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = args["name"] as? String
        request.addResource(with: .photo, data: bytes.data, options: options)
      }) { success, _ in
        DispatchQueue.main.async {
          if success { result("photos") }
          else { result(FlutterError(code: "photos", message: "截图保存失败，请检查相册权限和剩余空间", details: nil)) }
        }
      }
    }
    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: save)
    } else {
      PHPhotoLibrary.requestAuthorization(save)
    }
  }

  private func storageVolume(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, path.hasPrefix("/") else {
      result(FlutterError(code: "storage", message: "存储路径无效", details: nil)); return
    }
    queue.async {
      do {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsHardLinksKey])
        guard let identifier = attributes[.systemNumber] as? NSNumber else {
          DispatchQueue.main.async { result(nil) }; return
        }
        let value: [String: Any] = [
          "id": identifier.stringValue,
          "hardLinks": values.volumeSupportsHardLinks ?? false
        ]
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async { result(nil) }
      }
    }
  }

  private func createHardLink(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let source = args["source"] as? String, let target = args["target"] as? String,
          source.hasPrefix("/"), target.hasPrefix("/"), source != target else {
      result(FlutterError(code: "storage", message: "文件保存位置无效", details: nil)); return
    }
    queue.async {
      do {
        try FileManager.default.linkItem(atPath: source, toPath: target)
        DispatchQueue.main.async { result(true) }
      } catch {
        // The Dart copy path remains available for cloud providers and volumes
        // that report hard-link support but refuse this specific operation.
        DispatchQueue.main.async { result(false) }
      }
    }
  }

  deinit {
    for url in folders.values { url.stopAccessingSecurityScopedResource() }
  }
}
