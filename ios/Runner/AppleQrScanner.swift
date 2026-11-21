import Flutter
import UIKit
import AVFoundation
import PhotosUI

final class AppleQrScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  private let capture = AVCaptureSession()
  private let cameraQueue = DispatchQueue(label: "com.asterlink.app.qr-camera")
  private var preview: AVCaptureVideoPreviewLayer?
  private var completed = false
  private var requestedCamera = false
  private var completion: ((String?, String?) -> Void)?
  private let scanHint: String

  init(hint: String = "将设备二维码放入画面中", completion: @escaping (String?, String?) -> Void) {
    self.completion = completion
    self.scanHint = hint
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError("Use init(completion:)") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    let close = UIButton(type: .system)
    close.setTitle("取消扫码", for: .normal)
    close.setTitleColor(.white, for: .normal)
    close.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    close.layer.cornerRadius = 10
    close.translatesAutoresizingMaskIntoConstraints = false
    close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    view.addSubview(close)
    let hint = UILabel()
    hint.text = scanHint
    hint.textColor = .white
    hint.numberOfLines = 0
    hint.textAlignment = .center
    hint.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hint)
    NSLayoutConstraint.activate([
      close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      close.widthAnchor.constraint(equalToConstant: 100),
      close.heightAnchor.constraint(equalToConstant: 44),
      hint.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      hint.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -36)
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !completed, !requestedCamera else { return }
    requestedCamera = true
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: configure()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { allowed in
        DispatchQueue.main.async {
          if allowed { self.configure() }
          else { self.finish(nil, "请在系统设置中允许文析助手使用摄像头") }
        }
      }
    default: finish(nil, "请在系统设置中允许文析助手使用摄像头")
    }
  }

  private func configure() {
    guard !completed else { return }
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device) else {
      finish(nil, "当前设备无法使用摄像头"); return
    }
    capture.beginConfiguration()
    capture.sessionPreset = .hd1280x720
    guard capture.canAddInput(input) else {
      capture.commitConfiguration(); finish(nil, "无法开启摄像头"); return
    }
    capture.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard capture.canAddOutput(output) else {
      capture.commitConfiguration(); finish(nil, "无法初始化扫码"); return
    }
    capture.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]
    capture.commitConfiguration()
    let layer = AVCaptureVideoPreviewLayer(session: capture)
    layer.videoGravity = .resizeAspectFill
    layer.frame = view.bounds
    view.layer.insertSublayer(layer, at: 0)
    preview = layer
    view.setNeedsLayout()
    cameraQueue.async { [capture] in capture.startRunning() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
    if let orientation = view.window?.windowScene?.interfaceOrientation,
       let connection = preview?.connection, connection.isVideoOrientationSupported {
      switch orientation {
      case .landscapeLeft: connection.videoOrientation = .landscapeLeft
      case .landscapeRight: connection.videoOrientation = .landscapeRight
      case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
      default: connection.videoOrientation = .portrait
      }
    }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    let code = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
    if let code = code, code.utf8.count <= 16384 { finish(code, nil) }
  }
  @objc private func cancel() { finish(nil, nil) }

  private func finish(_ value: String?, _ error: String?) {
    guard !completed else { return }
    completed = true
    cameraQueue.async { [capture] in capture.stopRunning() }
    let callback = completion
    completion = nil
    dismiss(animated: true) { callback?(value, error) }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if !completed { finish(nil, nil) }
  }
}

/// System photo selection returns only the chosen image; no full-library access.
final class AppleQrImagePicker: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  private var pending: FlutterResult?
  private var picker: UIViewController?
  private var photoDelegate: AnyObject?
  private var generation = UUID()
  private static let maxBytes = 24 * 1024 * 1024

  func pick(result: @escaping FlutterResult) {
    guard pending == nil, let parent = AppleDocuments.presenter else {
      result(FlutterError(code: "qr_busy", message: "请先关闭当前图片选择窗口", details: nil)); return
    }
    pending = result
    let request = UUID()
    generation = request
    let view: UIViewController
    if #available(iOS 14.0, *) {
      var configuration = PHPickerConfiguration()
      configuration.filter = .images
      configuration.selectionLimit = 1
      configuration.preferredAssetRepresentationMode = .compatible
      let photos = PHPickerViewController(configuration: configuration)
      let delegate = AppleQrPhotoDelegate { [weak self] provider in
        guard let self, self.generation == request else { return }
        self.selected(provider, request: request)
      }
      photos.delegate = delegate
      photoDelegate = delegate
      view = photos
    } else {
      let documents = UIDocumentPickerViewController(documentTypes: ["public.image"], in: .import)
      documents.delegate = self
      documents.allowsMultipleSelection = false
      view = documents
    }
    picker = view
    parent.present(view, animated: true)
    view.presentationController?.delegate = self
  }

  private func selected(_ provider: NSItemProvider?, request: UUID) {
    guard let provider else { complete(nil); return }
    guard provider.hasItemConformingToTypeIdentifier("public.image") else {
      complete(FlutterError(code: "qr_image", message: "请选择二维码图片", details: nil)); return
    }
    // Provider files are temporary and must be read inside its completion handler.
    provider.loadFileRepresentation(forTypeIdentifier: "public.image") { [weak self] url, error in
      guard let self else { return }
      let response: Any?
      do {
        guard error == nil, let url else { throw ImageReadError.unavailable }
        response = try self.readImage(url)
      } catch ImageReadError.tooLarge {
        response = FlutterError(code: "qr_image", message: "请选择不超过 24 MB 的二维码图片", details: nil)
      } catch {
        response = FlutterError(code: "qr_image", message: "无法读取图片，请检查图片是否已下载到本机后重试", details: nil)
      }
      DispatchQueue.main.async {
        if self.generation == request { self.complete(response) }
      }
    }
  }

  private func readImage(_ url: URL) throws -> FlutterStandardTypedData {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= Self.maxBytes else { throw ImageReadError.tooLarge }
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    guard bytes.count <= Self.maxBytes else { throw ImageReadError.tooLarge }
    guard !bytes.isEmpty else { throw ImageReadError.unavailable }
    return FlutterStandardTypedData(bytes: bytes)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard picker === controller, let url = urls.first else { complete(nil); return }
    do { complete(try readImage(url)) }
    catch ImageReadError.tooLarge {
      complete(FlutterError(code: "qr_image", message: "请选择不超过 24 MB 的二维码图片", details: nil))
    } catch {
      complete(FlutterError(code: "qr_image", message: "无法读取这张图片，请重新选择", details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if picker === controller { complete(nil) }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if picker === presentationController.presentedViewController { complete(nil) }
  }

  private func complete(_ value: Any?) {
    guard let callback = pending else { return }
    pending = nil
    generation = UUID()
    photoDelegate = nil
    let view = picker
    picker = nil
    if let view, view.presentingViewController != nil {
      view.dismiss(animated: true) { callback(value) }
    } else { callback(value) }
  }

  private enum ImageReadError: Error { case unavailable, tooLarge }
}

@available(iOS 14.0, *)
private final class AppleQrPhotoDelegate: NSObject, PHPickerViewControllerDelegate {
  private let completion: (NSItemProvider?) -> Void
  init(completion: @escaping (NSItemProvider?) -> Void) { self.completion = completion }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    completion(results.first?.itemProvider)
  }
}
