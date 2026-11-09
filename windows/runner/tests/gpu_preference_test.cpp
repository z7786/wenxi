#include "../gpu_preference.h"
#include <iostream>
#include <stdexcept>

namespace {
const std::wstring base = L"Software\\AsterLinkTests\\GpuPreference-" + std::to_wstring(GetCurrentProcessId());
const std::wstring gpu = base + L"\\GPU", backup = base + L"\\Backup";
const std::wstring executable = L"D:\\Test Folder\\asterlink.exe";
void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
void Put(const std::wstring& path, const std::wstring& text, const std::wstring& name = executable) {
  HKEY key = nullptr;
  Check(RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS, "create test key");
  const auto error = RegSetValueExW(key, name.c_str(), 0, REG_SZ,
      reinterpret_cast<const BYTE*>(text.c_str()), static_cast<DWORD>((text.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  Check(error == ERROR_SUCCESS, "write test setting");
}
std::wstring Get(const std::wstring& path, const std::wstring& name = executable) {
  wchar_t data[1024]{};
  DWORD bytes = sizeof(data);
  const auto error = RegGetValueW(HKEY_CURRENT_USER, path.c_str(), name.c_str(), RRF_RT_REG_SZ, nullptr, data, &bytes);
  Check(error == ERROR_SUCCESS, "read test setting");
  return data;
}
bool Exists(const std::wstring& path, const std::wstring& name = executable) {
  DWORD bytes = 0;
  const auto error = RegGetValueW(HKEY_CURRENT_USER, path.c_str(), name.c_str(), RRF_RT_ANY, nullptr, nullptr, &bytes);
  Check(error == ERROR_SUCCESS || error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND, "query test setting");
  return error == ERROR_SUCCESS;
}
void State(const GpuPreference& preference, bool enabled, bool restart) {
  bool actual_enabled = false, actual_restart = false;
  Check(preference.Read(&actual_enabled, &actual_restart) == ERROR_SUCCESS, "read preference");
  Check(enabled == actual_enabled && restart == actual_restart, "preference state mismatch");
}
void Reset() { RegDeleteTreeW(HKEY_CURRENT_USER, base.c_str()); }
}

int main() {
  try {
    Reset();
    {
      GpuPreference preference(executable, gpu, backup);
      State(preference, false, false);
      Check(!Exists(gpu) && !Exists(backup), "default must not write registry");
      Check(preference.SetEnabled(true) == ERROR_SUCCESS, "enable");
      Check(Get(gpu) == L"GpuPreference=2;", "high performance value");
      State(preference, true, true);
      Check(preference.SetEnabled(true) == ERROR_SUCCESS, "repeated enable");
      Check(preference.SetEnabled(false) == ERROR_SUCCESS, "disable");
      Check(!Exists(gpu) && !Exists(backup), "remove only owned entries");
      State(preference, false, false);
    }
    Reset();
    {
      const auto previous = L"AutoHDREnable=1;GpuPreference=1;SwapEffectUpgradeEnable=0;";
      Put(gpu, previous);
      Put(gpu, L"GpuPreference=1;", L"D:\\Other App.exe");
      GpuPreference preference(executable, gpu, backup);
      Check(preference.SetEnabled(true) == ERROR_SUCCESS, "enable existing setting");
      Check(Get(gpu) == L"AutoHDREnable=1;SwapEffectUpgradeEnable=0;GpuPreference=2;", "preserve unrelated GPU flags");
      GpuPreference relaunched(executable, gpu, backup);
      State(relaunched, true, false);
      Check(relaunched.SetEnabled(false) == ERROR_SUCCESS, "restore after relaunch");
      Check(Get(gpu) == previous, "exact original setting restored");
      Check(Get(gpu, L"D:\\Other App.exe") == L"GpuPreference=1;", "preserve other applications");
      State(relaunched, false, true);
    }
    Reset();
    {
      Put(gpu, L"GpuPreference=1;");
      GpuPreference preference(executable, gpu, backup);
      Check(preference.SetEnabled(true) == ERROR_SUCCESS, "enable before external change");
      Put(gpu, L"GpuPreference=0;AutoHDREnable=0;");
      State(preference, false, true);
      Check(preference.SetEnabled(false) == ERROR_SUCCESS, "disable after external change");
      Check(Get(gpu) == L"GpuPreference=0;AutoHDREnable=0;", "external setting must not be overwritten");
      Check(preference.SetEnabled(true) == ERROR_SUCCESS, "enable with new baseline");
      Check(preference.SetEnabled(false) == ERROR_SUCCESS, "restore new baseline");
      Check(Get(gpu) == L"GpuPreference=0;AutoHDREnable=0;", "new baseline restored");
    }
    Reset();
    {
      Put(gpu, L"GpuPreference=2;");
      GpuPreference preference(executable, gpu, backup);
      State(preference, false, false);
      Check(preference.SetEnabled(false) == ERROR_SUCCESS, "disable unmanaged value");
      Check(Get(gpu) == L"GpuPreference=2;", "preserve manually selected high performance");
    }
    Reset();
    {
      Put(backup, L"corrupted backup");
      GpuPreference preference(executable, gpu, backup);
      bool enabled = false, restart = false;
      Check(preference.Read(&enabled, &restart) == ERROR_INVALID_DATA, "reject damaged backup");
      Check(preference.SetEnabled(true) == ERROR_INVALID_DATA, "damaged backup must not write GPU setting");
      Check(!Exists(gpu), "no GPU setting written on backup error");
    }
    Reset();
    std::cout << "GPU preference: 5 native scenarios passed\n";
    return 0;
  } catch (const std::exception& error) {
    Reset();
    std::cerr << error.what() << '\n';
    return 1;
  }
}
