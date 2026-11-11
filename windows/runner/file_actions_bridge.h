#ifndef RUNNER_FILE_ACTIONS_BRIDGE_H_
#define RUNNER_FILE_ACTIONS_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class FileActionsBridge {
 public:
  FileActionsBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~FileActionsBridge();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool choosing_ = false;
};

#endif  // RUNNER_FILE_ACTIONS_BRIDGE_H_
