#include "gpu_preference_bridge.h"
#include <flutter/standard_method_codec.h>

namespace {
std::wstring ExecutablePath() {
  std::wstring path(32768, L'\0');
  const auto size = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (size == 0 || size >= path.size()) return {};
  path.resize(size);
  return path;
}
}  // namespace

GpuPreferenceBridge::GpuPreferenceBridge(flutter::BinaryMessenger* messenger)
    : preference_(ExecutablePath()) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.asterlink.app/gpu_preference", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      LONG error = ERROR_SUCCESS;
      if (call.method_name() == "set") {
        const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
        const bool* enabled = nullptr;
        if (args) {
          const auto found = args->find(flutter::EncodableValue("enabled"));
          if (found != args->end()) enabled = std::get_if<bool>(&found->second);
        }
        if (!enabled) { result->Error("argument", "显卡设置参数无效"); return; }
        error = preference_.SetEnabled(*enabled);
      } else if (call.method_name() != "get") {
        result->NotImplemented(); return;
      }
      bool enabled = false, restart = false;
      if (error == ERROR_SUCCESS) error = preference_.Read(&enabled, &restart);
      if (error != ERROR_SUCCESS) {
        result->Error("gpu_preference", "无法读取或保存显卡设置", flutter::EncodableValue(static_cast<int32_t>(error)));
        return;
      }
      result->Success(flutter::EncodableMap{
          {flutter::EncodableValue("enabled"), flutter::EncodableValue(enabled)},
          {flutter::EncodableValue("restartRequired"), flutter::EncodableValue(restart)}});
    } catch (...) {
      result->Error("gpu_preference", "显卡设置操作失败");
    }
  });
}

GpuPreferenceBridge::~GpuPreferenceBridge() { channel_->SetMethodCallHandler(nullptr); }
