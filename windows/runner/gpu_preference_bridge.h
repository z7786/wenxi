#ifndef RUNNER_GPU_PREFERENCE_BRIDGE_H_
#define RUNNER_GPU_PREFERENCE_BRIDGE_H_
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include "gpu_preference.h"

class GpuPreferenceBridge {
 public:
  explicit GpuPreferenceBridge(flutter::BinaryMessenger* messenger);
  ~GpuPreferenceBridge();
 private:
  GpuPreference preference_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
