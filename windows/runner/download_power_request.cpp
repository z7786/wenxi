#include "download_power_request.h"

DownloadPowerRequest::DownloadPowerRequest(DownloadPowerFunctions functions)
    : functions_(functions) {}

DownloadPowerRequest::~DownloadPowerRequest() { SetActive(false); }

bool DownloadPowerRequest::SetActive(bool active) {
  if (active && active_) return true;
  if (!active) {
    if (handle_ == INVALID_HANDLE_VALUE) return true;
    const BOOL cleared = !active_ || functions_.clear(handle_, PowerRequestSystemRequired);
    if (cleared) active_ = false;
    const BOOL closed = functions_.close(handle_);
    // Closing the request releases its OS ownership even if clearing failed.
    if (closed) {
      handle_ = INVALID_HANDLE_VALUE;
      active_ = false;
    }
    return cleared && closed;
  }

  if (handle_ != INVALID_HANDLE_VALUE && !SetActive(false)) return false;

  wchar_t reason[] = L"文析助手正在传输文件";
  REASON_CONTEXT context{};
  context.Version = POWER_REQUEST_CONTEXT_VERSION;
  context.Flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING;
  context.Reason.SimpleReasonString = reason;
  const HANDLE handle = functions_.create(&context);
  if (handle == INVALID_HANDLE_VALUE || handle == nullptr) return false;
  handle_ = handle;
  if (!functions_.set(handle_, PowerRequestSystemRequired)) {
    if (functions_.close(handle_)) handle_ = INVALID_HANDLE_VALUE;
    return false;
  }
  active_ = true;
  return true;
}
