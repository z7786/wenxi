import Flutter
import UIKit
import Photos
import Darwin

final class AppleDocuments: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  private let queue = DispatchQueue(label: "com.asterlink.app.documents")
  private let bookmarkKey = "asterlink.directoryBookmarks"
  private var folders = [String: URL]()
  private var movedPaths = [String: String]()
  private var exportPreparing = false
  private var picker: UIDocumentPickerViewController?
  private var pickerResult: FlutterResult?
  private var exportDirectory: URL?
  var channel: FlutterMethodChannel?
  private let transferLock = NSLock()
  private var transfers = [String: AppleDocumentTransfer]()

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
    case "saveDownloadedFile": saveDownload(args, result: result)
    case "cancelExport":
      if let id = args["id"] as? String {
        transferLock.lock()
        let transfer = transfers[id]
        transferLock.unlock()
        transfer?.cancel()
      }
      result(nil)
    case "fileAvailability": inspectFile(args, result: result)
    case "deleteFile": deleteFile(args, result: result)
    case "savePlayerScreenshot": saveImage(args, result: result)
    case "storageVolume": storageVolume(args, result: result)
    case "createHardLink": createHardLink(args, result: result)
    default: return false
    }
    return true
  }

  private func fileURL(_ path: String) -> URL {
    let local = URL(string: path).flatMap { $0.isFileURL ? $0.path : nil } ?? path
    return URL(fileURLWithPath: resolvedPath(local)).standardizedFileURL
  }

  private func isLocal(_ url: URL) -> Bool {
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    let path = url.resolvingSymlinksInPath().path
    return path == home || path.hasPrefix(home + "/")
  }

  private func permitted(_ url: URL) -> Bool {
    if isLocal(url) { return true }
    let path = url.resolvingSymlinksInPath().path
    return folders.values.contains {
      let root = $0.resolvingSymlinksInPath().path
      return path == root || path.hasPrefix(root + "/")
    }
  }

  private func saveDownload(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let id = args["id"] as? String, !id.isEmpty,
          let sourcePath = args["source"] as? String, sourcePath.hasPrefix("/"),
          let targetPath = args["destination"] as? String ?? args["defaultDirectory"] as? String,
          targetPath.hasPrefix("/"), let name = args["name"] as? String,
          !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
          name != ".", name != ".." else {
      result(FlutterError(code: "storage", message: "下载文件保存参数无效", details: nil)); return
    }
    let relative = args["relativePath"] as? String ?? ""
    let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !relative.hasPrefix("/"), !relative.contains("\\"),
          !components.contains(".."), !components.contains("."),
          !name.contains("\\") else {
      result(FlutterError(code: "storage", message: "下载路径超出所选目录", details: nil)); return
    }
    let source = fileURL(sourcePath), root = fileURL(targetPath)
    guard permitted(source), permitted(root) else {
      result(FlutterError(code: "storage", message: "下载目录授权已失效，请重新选择目录；下载内容已保留", details: nil)); return
    }
    let transfer = AppleDocumentTransfer()
    transferLock.lock()
    let previous = transfers.updateValue(transfer, forKey: id)
    transferLock.unlock()
    previous?.cancel()
    let token = args["token"] as? NSNumber ?? 0
    queue.async {
      var saved: URL?
      do {
        try transfer.check()
        let manager = FileManager.default
        let size = try manager.attributesOfItem(atPath: source.path)[.size] as? NSNumber ?? 0
        let total = size.int64Value
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard sourceValues.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
        var directory = root
        var coordinateError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: root, options: [], error: &coordinateError) { located in
          do {
            try transfer.check()
            let realRoot = located.resolvingSymlinksInPath().path
            directory = components.reduce(located) { $0.appendingPathComponent($1, isDirectory: true) }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let realDirectory = directory.resolvingSymlinksInPath().path
            guard realDirectory == realRoot || realDirectory.hasPrefix(realRoot + "/") else {
              throw CocoaError(.fileWriteNoPermission)
            }
          } catch { operationError = error }
        }
        if let error = coordinateError { throw error }
        if let error = operationError { throw error }
        let original = URL(fileURLWithPath: name)
        let ext = original.pathExtension, base = original.deletingPathExtension().lastPathComponent
        for index in 0..<10000 {
          try transfer.check()
          let candidate = directory.appendingPathComponent(index == 0 ? name :
            base + " (\(index))" + (ext.isEmpty ? "" : "." + ext))
          coordinateError = nil
          operationError = nil
          var collision = false
          NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges,
            writingItemAt: candidate, options: .forReplacing, error: &coordinateError) { input, output in
              do {
                try transfer.check()
                guard !manager.fileExists(atPath: output.path) else { collision = true; return }
                // LocalSend completes cached transfers before publication.
                // Providers require an independent coordinated document, even
                // when their underlying volume advertises hard-link support.
                if self.isLocal(input) && self.isLocal(output) {
                  do {
                    try manager.linkItem(at: input, to: output)
                    saved = output
                    try transfer.check()
                    self.progress(id, token: token, copied: total, total: total)
                    return
                  } catch {
                    if saved != nil { throw error }
                    if manager.fileExists(atPath: output.path) { collision = true; return }
                  }
                }
                let inputHandle = try FileHandle(forReadingFrom: input)
                defer { inputHandle.closeFile() }
                let descriptor = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
                guard descriptor >= 0 else {
                  if errno == EEXIST { collision = true; return }
                  throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                saved = output
                let outputHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { outputHandle.closeFile() }
                var copied: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                var lastProgress = ProcessInfo.processInfo.systemUptime
                while copied < total {
                  try transfer.check()
                  // POSIX I/O preserves the supported iOS 13 deployment target
                  // and reports disk/provider failures without NSExceptions.
                  let received = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(inputHandle.fileDescriptor, bytes.baseAddress,
                      min(bytes.count, Int(min(total - copied, Int64(bytes.count)))))
                  }
                  if received < 0 {
                    let failure = errno
                    if failure == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
                  }
                  guard received > 0 else { throw CocoaError(.fileReadUnknown) }
                  try buffer.withUnsafeBytes { bytes in
                    var written = 0
                    while written < received {
                      try transfer.check()
                      let count = Darwin.write(outputHandle.fileDescriptor,
                        bytes.baseAddress!.advanced(by: written), received - written)
                      if count < 0 {
                        let failure = errno
                        if failure == EINTR { continue }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
                      }
                      guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                      written += count
                    }
                  }
                  copied += Int64(received)
                  let now = ProcessInfo.processInfo.systemUptime
                  if now - lastProgress >= 0.25 || copied == total {
                    lastProgress = now
                    self.progress(id, token: token, copied: copied, total: total)
                  }
                }
                try transfer.check()
                try outputHandle.synchronize()
                guard copied == total else { throw CocoaError(.fileWriteUnknown) }
              } catch {
                operationError = error
                if let created = saved { try? manager.removeItem(at: created); saved = nil }
              }
            }
          if let error = coordinateError { throw error }
          if let error = operationError { throw error }
          if !collision { break }
        }
        guard let saved = saved else { throw CocoaError(.fileWriteFileExists) }
        // Reply only after handles close and the coordinator publishes changes.
        DispatchQueue.main.async {
          self.finishTransfer(id, transfer)
          result(saved.path)
        }
      } catch {
        DispatchQueue.main.async {
          self.finishTransfer(id, transfer)
          let cancelled = transfer.cancelled
          result(FlutterError(code: cancelled ? "cancelled" : "storage",
            message: cancelled ? "文件保存已取消，下载内容已保留" :
              "无法保存到所选目录，请检查文件 App 的目录权限和剩余空间；下载内容已保留",
            details: nil))
        }
      }
    }
  }

  private func finishTransfer(_ id: String, _ transfer: AppleDocumentTransfer) {
    transferLock.lock()
    if transfers[id] === transfer { transfers.removeValue(forKey: id) }
    transferLock.unlock()
  }

  private func progress(_ id: String, token: NSNumber, copied: Int64, total: Int64) {
    DispatchQueue.main.async {
      self.channel?.invokeMethod("exportProgress", arguments: [
        "id": id, "token": token, "copied": copied, "total": total,
      ])
    }
  }

  private func inspectFile(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String else { result("missing"); return }
    let url = fileURL(path)
    guard permitted(url) else { result("inaccessible"); return }
    queue.async {
      var availability = "inaccessible"
      var coordination: NSError?
      NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
        error: &coordination) { item in
          do {
            let handle = try FileHandle(forReadingFrom: item)
            handle.closeFile()
            availability = "present"
          } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain &&
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
              availability = "missing"
            }
          }
        }
      if let error = coordination, error.domain == NSCocoaErrorDomain &&
          [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
        availability = "missing"
      }
      DispatchQueue.main.async { result(availability) }
    }
  }

  private func deleteFile(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String else { result(nil); return }
    let url = fileURL(path)
    guard permitted(url) else {
      result(FlutterError(code: "storage", message: "目录权限已失效，请重新选择目录", details: nil)); return
    }
    queue.async {
      var coordination: NSError?, operation: Error?
      NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting,
        error: &coordination) { item in
          do {
            if FileManager.default.fileExists(atPath: item.path) {
              guard try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileWriteNoPermission)
              }
              try FileManager.default.removeItem(at: item)
            }
          } catch { operation = error }
        }
      DispatchQueue.main.async {
        if coordination != nil || operation != nil {
          result(FlutterError(code: "storage", message: "文件正在使用或无法删除，下载记录已保留", details: nil))
        } else { result(nil) }
      }
    }
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
          "hardLinks": self.isLocal(URL(fileURLWithPath: path)) && (values.volumeSupportsHardLinks ?? false)
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

private final class AppleDocumentTransfer {
  private let lock = NSLock()
  private var stopped = false
  var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
  func cancel() { lock.lock(); stopped = true; lock.unlock() }
  func check() throws { if cancelled { throw CocoaError(.userCancelled) } }
}
