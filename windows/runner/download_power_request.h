#ifndef RUNNER_DOWNLOAD_POWER_REQUEST_H_
#define RUNNER_DOWNLOAD_POWER_REQUEST_H_

#include <windows.h>

struct DownloadPowerFunctions {
  decltype(&PowerCreateRequest) create = PowerCreateRequest;
  decltype(&PowerSetRequest) set = PowerSetRequest;
  decltype(&PowerClearRequest) clear = PowerClearRequest;
  decltype(&CloseHandle) close = CloseHandle;
};

// A separate power request does not overwrite the player's display wake lock
// or rely on a Dart isolate remaining on the same operating-system thread.
class DownloadPowerRequest {
 public:
  explicit DownloadPowerRequest(DownloadPowerFunctions functions = {},
                                POWER_REQUEST_TYPE type = PowerRequestSystemRequired);
  ~DownloadPowerRequest();
  DownloadPowerRequest(const DownloadPowerRequest&) = delete;
  DownloadPowerRequest& operator=(const DownloadPowerRequest&) = delete;

  bool SetActive(bool active);
  bool active() const { return active_; }

 private:
  DownloadPowerFunctions functions_;
  POWER_REQUEST_TYPE type_;
  HANDLE handle_ = INVALID_HANDLE_VALUE;
  bool active_ = false;
};

#endif  // RUNNER_DOWNLOAD_POWER_REQUEST_H_
