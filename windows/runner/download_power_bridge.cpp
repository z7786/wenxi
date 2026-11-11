#include "download_power_bridge.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <variant>

DownloadPowerBridge::DownloadPowerBridge(flutter::BinaryMessenger* messenger) {
  cast_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.asterlink.app/cast",
      &flutter::StandardMethodCodec::GetInstance());
  cast_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    using flutter::EncodableMap;
    using flutter::EncodableValue;
    if (call.method_name() != "active") {
      result->NotImplemented();
      return;
    }
    const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    const std::string* token = nullptr;
    const bool* enabled = nullptr;
    if (args) {
      const auto owner = args->find(EncodableValue("token"));
      const auto active = args->find(EncodableValue("enabled"));
      if (owner != args->end()) token = std::get_if<std::string>(&owner->second);
      if (active != args->end()) enabled = std::get_if<bool>(&active->second);
    }
    if (!token || token->empty() || token->size() > 128 || !enabled) {
      result->Error("arguments", "投屏保活参数无效");
      return;
    }
    auto owners = cast_owners_;
    if (*enabled) owners.insert(*token);
    else owners.erase(*token);
    if (!cast_request_.SetActive(!owners.empty())) {
      result->Error("active", "无法更新投屏保活状态");
      return;
    }
    cast_owners_ = std::move(owners);
    result->Success();
  });
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.asterlink.app/native",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    using flutter::EncodableMap;
    using flutter::EncodableValue;
    if (call.method_name() == "foreground") {
      const auto* args = call.arguments()
                             ? std::get_if<EncodableMap>(call.arguments())
                             : nullptr;
      int64_t active = -1;
      if (args) {
        const auto entry = args->find(EncodableValue("active"));
        if (entry != args->end()) {
          if (const auto* value = std::get_if<int32_t>(&entry->second)) {
            active = *value;
          } else if (const auto* value64 = std::get_if<int64_t>(&entry->second)) {
            active = *value64;
          }
        }
      }
      if (active < 0 || active > 10000) {
        result->Error("arguments", "下载任务状态无效");
      } else if (!request_.SetActive(active > 0)) {
        result->Error("foreground", "无法更新下载保活状态，请重试");
      } else {
        result->Success();
      }
      return;
    }
    if (call.method_name() == "downloadProtectionStatus") {
      SYSTEM_POWER_STATUS power{};
      const bool saving = GetSystemPowerStatus(&power) && power.SystemStatusFlag == 1;
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("desktop"), EncodableValue(true)},
          {EncodableValue("batteryUnrestricted"), EncodableValue(true)},
          {EncodableValue("notificationsEnabled"), EncodableValue(true)},
          {EncodableValue("backgroundRestricted"), EncodableValue(false)},
          {EncodableValue("serviceRunning"), EncodableValue(request_.active())},
          {EncodableValue("wakeLockHeld"), EncodableValue(request_.active())},
          {EncodableValue("powerSaveMode"), EncodableValue(saving)},
      }));
      return;
    }
    result->NotImplemented();
  });
}

DownloadPowerBridge::~DownloadPowerBridge() {
  cast_channel_->SetMethodCallHandler(nullptr);
  channel_->SetMethodCallHandler(nullptr);
}
