#include "file_actions_bridge.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>

#include <string>

FileActionsBridge::FileActionsBridge(flutter::BinaryMessenger* messenger,
                                     HWND window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.asterlink.app/file_actions",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this, window](const auto& call, auto result) {
    if (call.method_name() != "openWith") {
      result->NotImplemented();
      return;
    }
    if (choosing_) {
      result->Error("busy", "请先关闭当前应用选择窗口");
      return;
    }
    const auto* args = call.arguments()
                           ? std::get_if<flutter::EncodableMap>(call.arguments())
                           : nullptr;
    const std::string* path = nullptr;
    if (args) {
      const auto entry = args->find(flutter::EncodableValue("path"));
      if (entry != args->end()) path = std::get_if<std::string>(&entry->second);
    }
    if (!path || path->empty() || path->find('\0') != std::string::npos) {
      result->Error("location", "无法识别文件位置");
      return;
    }
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         path->data(), static_cast<int>(path->size()),
                                         nullptr, 0);
    if (count <= 0) {
      result->Error("location", "文件路径编码无效");
      return;
    }
    std::wstring location(count, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(),
                        static_cast<int>(path->size()), location.data(), count);
    const DWORD attributes = GetFileAttributesW(location.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
      result->Error("missing", "文件不存在或无法访问");
      return;
    }
    OPENASINFO options{};
    options.pcszFile = location.c_str();
    // Execute once; do not silently change the user's default association.
    options.oaifInFlags = OAIF_EXEC;
    choosing_ = true;
    const HRESULT status = SHOpenWithDialog(window, &options);
    choosing_ = false;
    if (SUCCEEDED(status) || status == HRESULT_FROM_WIN32(ERROR_CANCELLED) ||
        status == E_ABORT) {
      result->Success();
    } else {
      result->Error("open_with", "无法打开应用选择窗口，请检查文件和系统设置");
    }
  });
}

FileActionsBridge::~FileActionsBridge() {
  channel_->SetMethodCallHandler(nullptr);
}
