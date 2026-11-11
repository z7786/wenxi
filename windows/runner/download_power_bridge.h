#ifndef RUNNER_DOWNLOAD_POWER_BRIDGE_H_
#define RUNNER_DOWNLOAD_POWER_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <set>
#include <string>

#include "download_power_request.h"

class DownloadPowerBridge {
 public:
  explicit DownloadPowerBridge(flutter::BinaryMessenger* messenger);
  ~DownloadPowerBridge();

 private:
  DownloadPowerRequest request_;
  DownloadPowerRequest cast_request_;
  std::set<std::string> cast_owners_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> cast_channel_;
};

#endif  // RUNNER_DOWNLOAD_POWER_BRIDGE_H_
