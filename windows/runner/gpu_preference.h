#ifndef RUNNER_GPU_PREFERENCE_H_
#define RUNNER_GPU_PREFERENCE_H_

#include <windows.h>
#include <string>
#include <vector>

struct GpuRegistryValue {
  bool exists = false;
  DWORD type = REG_NONE;
  std::vector<BYTE> data;
  bool operator==(const GpuRegistryValue& other) const {
    return exists == other.exists && (!exists || (type == other.type && data == other.data));
  }
};

// Registry paths can be substituted by native tests without touching GPU settings.
class GpuPreference {
 public:
  explicit GpuPreference(std::wstring executable,
      std::wstring gpu_key = L"Software\\Microsoft\\DirectX\\UserGpuPreferences",
      std::wstring backup_key = L"Software\\AsterLink\\GpuPreferences");
  LONG Read(bool* enabled, bool* restart_required) const;
  LONG SetEnabled(bool enabled);
 private:
  LONG ReadValue(const std::wstring& path, GpuRegistryValue* value) const;
  LONG WriteValue(const std::wstring& path, const GpuRegistryValue& value) const;
  std::wstring executable_, gpu_key_, backup_key_;
  GpuRegistryValue initial_;
  LONG initial_error_ = ERROR_SUCCESS;
};
#endif
