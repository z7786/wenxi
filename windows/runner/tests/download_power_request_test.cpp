#include "../download_power_request.h"

#include <iostream>
#include <stdexcept>

namespace {
int created, set, cleared, closed;
POWER_REQUEST_TYPE expected_type = PowerRequestSystemRequired;
bool fail_create, fail_set, fail_clear, fail_close;
void Check(bool value) {
  if (!value) throw std::runtime_error("power request lifecycle check failed");
}
HANDLE WINAPI Create(PREASON_CONTEXT context) {
  Check(context->Flags == POWER_REQUEST_CONTEXT_SIMPLE_STRING);
  Check(context->Reason.SimpleReasonString != nullptr);
  ++created;
  return fail_create ? INVALID_HANDLE_VALUE : reinterpret_cast<HANDLE>(1);
}
BOOL WINAPI Set(HANDLE, POWER_REQUEST_TYPE type) {
  Check(type == expected_type);
  ++set;
  return !fail_set;
}
BOOL WINAPI Clear(HANDLE, POWER_REQUEST_TYPE type) {
  Check(type == expected_type);
  ++cleared;
  return !fail_clear;
}
BOOL WINAPI Close(HANDLE) { ++closed; return !fail_close; }
DownloadPowerFunctions functions{Create, Set, Clear, Close};
void Reset() {
  created = set = cleared = closed = 0;
  fail_create = fail_set = fail_clear = fail_close = false;
}
}  // namespace

int main() {
  try {
    Reset();
    expected_type = PowerRequestDisplayRequired;
    {
      DownloadPowerRequest display(functions, PowerRequestDisplayRequired);
      Check(display.SetActive(true) && display.active());
      Check(display.SetActive(true) && set == 1);
      Check(display.SetActive(false) && !display.active());
    }
    Check(set == 1 && cleared == 1 && closed == 1);
    expected_type = PowerRequestSystemRequired;
    Reset();
    {
      DownloadPowerRequest request(functions);
      Check(request.SetActive(false) && created == 0);
      for (int i = 0; i < 5; ++i) Check(request.SetActive(true));
      Check(request.active() && created == 1 && set == 1);
      Check(request.SetActive(false) && !request.active());
      Check(cleared == 1 && closed == 1);
      Check(request.SetActive(false) && closed == 1);
      Check(request.SetActive(true));
    }
    Check(created == 2 && cleared == 2 && closed == 2);

    Reset();
    {
      DownloadPowerRequest request(functions);
      fail_create = true;
      Check(!request.SetActive(true) && !request.active());
      Check(set == 0 && closed == 0);
      fail_create = false;
      fail_set = true;
      Check(!request.SetActive(true) && !request.active());
      Check(set == 1 && closed == 1);
      fail_set = false;
      Check(request.SetActive(true) && request.active());
    }
    Check(cleared == 1 && closed == 2);

    Reset();
    {
      DownloadPowerRequest request(functions);
      Check(request.SetActive(true));
      fail_clear = true;
      Check(!request.SetActive(false) && !request.active());
      Check(cleared == 1 && closed == 1);
    }
    Check(closed == 1);

    Reset();
    {
      DownloadPowerRequest request(functions);
      Check(request.SetActive(true));
      fail_close = true;
      Check(!request.SetActive(false) && !request.active());
      fail_close = false;
    }
    Check(closed == 2);

    // Briefly exercise the real Windows API, then release before exit.
    {
      DownloadPowerRequest request;
      Check(request.SetActive(true) && request.active());
      Check(request.SetActive(false) && !request.active());
    }
    std::cout << "5 power request checks passed (including Windows API)\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
