import Flutter
import UIKit
import AVFoundation

final class AppleQrScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  private let capture = AVCaptureSession()
  private let cameraQueue = DispatchQueue(label: "com.asterlink.app.qr-camera")
  private var preview: AVCaptureVideoPreviewLayer?
  private var completed = false
  private var requestedCamera = false
  private var completion: ((String?, String?) -> Void)?

  init(completion: @escaping (String?, String?) -> Void) {
    self.completion = completion
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
    hint.text = "将设备二维码放入画面中"
    hint.textColor = .white
    hint.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hint)
    NSLayoutConstraint.activate([
      close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      close.widthAnchor.constraint(equalToConstant: 100),
      close.heightAnchor.constraint(equalToConstant: 44),
      hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
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
