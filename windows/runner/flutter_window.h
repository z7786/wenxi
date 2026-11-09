#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"
#include "download_power_bridge.h"
#include "player_image_bridge.h"
#include "external_download_bridge.h"
#include "diagnostic_bridge.h"
#include "gpu_preference_bridge.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<DownloadPowerBridge> download_power_;
  std::unique_ptr<PlayerImageBridge> player_images_;
  std::unique_ptr<ExternalDownloadBridge> external_downloads_;
  std::unique_ptr<DiagnosticBridge> diagnostics_;
  std::unique_ptr<GpuPreferenceBridge> gpu_preference_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> theme_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
