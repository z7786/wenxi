import Flutter
import UIKit

/// URL schemes open a directly accessible stream in the selected installed app.
/// App-local proxy URLs are rejected because iOS may suspend their server.
final class AppleExternalPlayer {
  private var session = ""
  private var result: FlutterResult?
  private weak var chooser: UIAlertController?

  func begin(session: String) { cancel(); self.session = session }

  func open(arguments: [String: Any], result: @escaping FlutterResult) {
    guard self.result == nil, arguments["session"] as? String == session,
          let text = arguments["url"] as? String, text.utf8.count <= 32768,
          let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !["localhost", "127.0.0.1", "::1"].contains(host.lowercased()),
          url.user == nil, url.password == nil,
          let parent = AppleDocuments.presenter else {
      result(FlutterError(code: "external", message: "此视频暂时无法交给外部播放器", details: nil)); return
    }
    let players = [
      ("Infuse", "infuse", "play"),
      ("VLC", "vlc-x-callback", "stream"),
    ].filter { UIApplication.shared.canOpenURL(URL(string: "\($0.1)://")!) }
    guard !players.isEmpty else {
      result(FlutterError(code: "external", message: "请先安装 Infuse 或 VLC 后再选择外部播放器", details: nil)); return
    }
    self.result = result
    let token = session
    let sheet = UIAlertController(title: "选择外部播放器", message: nil, preferredStyle: .actionSheet)
    chooser = sheet
    for (name, scheme, action) in players {
      sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
        guard let self = self, self.session == token, self.result != nil else { return }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "x-callback-url"
        components.path = "/\(action)"
        components.queryItems = [URLQueryItem(name: "url", value: text)]
        if scheme == "infuse" {
          components.queryItems?.append(URLQueryItem(name: "filename", value: arguments["title"] as? String ?? ""))
          let milliseconds = (arguments["positionMs"] as? NSNumber)?.doubleValue ?? 0
          if milliseconds.isFinite {
            components.queryItems?.append(URLQueryItem(name: "position", value: String(Int(min(1e12, max(0, milliseconds)) / 1000))))
          }
        }
        guard let destination = components.url else { self.complete(false); return }
        UIApplication.shared.open(destination, options: [:]) { [weak self] opened in
          DispatchQueue.main.async {
            guard let self = self, self.session == token else { return }
            self.complete(opened)
          }
        }
      })
    }
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.complete(false) })
    sheet.popoverPresentationController?.sourceView = parent.view
    sheet.popoverPresentationController?.sourceRect = CGRect(x: parent.view.bounds.midX, y: parent.view.bounds.midY, width: 1, height: 1)
    sheet.popoverPresentationController?.permittedArrowDirections = []
    parent.present(sheet, animated: true)
  }

  private func complete(_ value: Bool) {
    let callback = result
    result = nil
    chooser = nil
    callback?(value)
  }

  func cancel() {
    chooser?.dismiss(animated: false)
    complete(false)
    session = ""
  }
}
