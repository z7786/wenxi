import Flutter
import UIKit
import MediaPlayer
import AVFoundation

final class ApplePlaybackVolume {
  private var volumeView: MPVolumeView?
  private var observation: NSKeyValueObservation?
  private var channel: FlutterMethodChannel?
  private var session = ""
  private var foreground = true

  var values: [String: Any] {
    ["systemVolumeSupported": volumeSlider != nil,
     "systemVolume": Double(AVAudioSession.sharedInstance().outputVolume) * 100]
  }

  private var volumeSlider: UISlider? {
    volumeView?.subviews.compactMap { $0 as? UISlider }.first
  }

  func begin(session: String, channel: FlutterMethodChannel) {
    end()
    self.session = session
    self.channel = channel
    foreground = true
    if let parent = AppleDocuments.presenter?.view {
      let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 160, height: 40))
      view.showsRouteButton = false
      view.isUserInteractionEnabled = false
      // Keep the system volume control in the hierarchy; hidden controls do
      // not reliably update the output volume on real devices.
      parent.addSubview(view)
      volumeView = view
      view.layoutIfNeeded()
    }
    observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self = self, !self.session.isEmpty else { return }
        var arguments: [String: Any] = self.values
        arguments["session"] = self.session
        self.channel?.invokeMethod("volume", arguments: arguments)
      }
    }
  }

  func set(_ value: Double, session: String, result: @escaping FlutterResult) {
    guard self.session == session, foreground, value.isFinite,
          let slider = volumeSlider else { result(values); return }
    slider.setValue(Float(min(100, max(0, value)) / 100), animated: false)
    slider.sendActions(for: .valueChanged)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      guard let self = self, self.session == session else { result(nil); return }
      result(self.values)
    }
  }

  func active(_ value: Bool) { foreground = value }

  func end() {
    observation?.invalidate()
    observation = nil
    volumeView?.removeFromSuperview()
    volumeView = nil
    channel = nil
    session = ""
  }
}
