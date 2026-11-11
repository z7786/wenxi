#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "native_diagnostics.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // Clear the controller through OnDestroy before member destruction can
  // re-enter MessageHandler with a controller that is already being released.
  Destroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // Engine/plugin initialization may install its own process exception filter.
  // Keep it in the chain while ensuring our recorder still sees host failures.
  NativeDiagnostics::Instance().InstallExceptionHandler();
  diagnostics_ = std::make_unique<DiagnosticBridge>(
      flutter_controller_->engine()->messenger());
  gpu_preference_ = std::make_unique<GpuPreferenceBridge>(
      flutter_controller_->engine()->messenger());
  external_downloads_ = std::make_unique<ExternalDownloadBridge>(
      flutter_controller_->engine()->messenger());
  player_images_ = std::make_unique<PlayerImageBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());
  download_power_ = std::make_unique<DownloadPowerBridge>(
      flutter_controller_->engine()->messenger());
  file_actions_ = std::make_unique<FileActionsBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());
  theme_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.asterlink.app/window_theme",
          &flutter::StandardMethodCodec::GetInstance());
  theme_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "setTheme") {
      result->NotImplemented();
      return;
    }
    const auto* args = call.arguments()
                           ? std::get_if<flutter::EncodableMap>(call.arguments())
                           : nullptr;
    const bool* dark = nullptr;
    if (args) {
      const auto entry = args->find(flutter::EncodableValue("dark"));
      if (entry != args->end()) dark = std::get_if<bool>(&entry->second);
    }
    if (!dark) {
      result->Error("arguments", "Window theme requires a dark flag");
      return;
    }
    SetTheme(*dark);
    result->Success();
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (theme_channel_) {
    theme_channel_->SetMethodCallHandler(nullptr);
    theme_channel_.reset();
  }
  download_power_.reset();
  file_actions_.reset();
  external_downloads_.reset();
  player_images_.reset();
  diagnostics_.reset();
  gpu_preference_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_COPYDATA) {
    return external_downloads_ && external_downloads_->AcceptCopyData(
        reinterpret_cast<const COPYDATASTRUCT*>(lparam));
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
