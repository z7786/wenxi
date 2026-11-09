#include "gpu_preference.h"
#include <cstring>
#include <utility>

namespace {
constexpr DWORD kMaximumBytes = 64 * 1024;
constexpr DWORD kSignature = 0x31555047;

void Append(std::vector<BYTE>* data, DWORD value) {
  const auto* bytes = reinterpret_cast<const BYTE*>(&value);
  data->insert(data->end(), bytes, bytes + sizeof(value));
}

GpuRegistryValue Backup(const GpuRegistryValue& original, const GpuRegistryValue& applied) {
  GpuRegistryValue value{true, REG_BINARY, {}};
  Append(&value.data, kSignature);
  Append(&value.data, original.exists ? 1 : 0);
  Append(&value.data, original.type);
  Append(&value.data, static_cast<DWORD>(original.data.size()));
  Append(&value.data, static_cast<DWORD>(applied.data.size()));
  value.data.insert(value.data.end(), original.data.begin(), original.data.end());
  value.data.insert(value.data.end(), applied.data.begin(), applied.data.end());
  return value;
}

bool Unpack(const GpuRegistryValue& backup, GpuRegistryValue* original, GpuRegistryValue* applied) {
  if (!backup.exists || backup.type != REG_BINARY || backup.data.size() < 5 * sizeof(DWORD)) return false;
  DWORD fields[5]{};
  std::memcpy(fields, backup.data.data(), sizeof(fields));
  if (fields[0] != kSignature || fields[1] > 1 ||
      fields[3] > kMaximumBytes || fields[4] > kMaximumBytes ||
      backup.data.size() != sizeof(fields) + static_cast<size_t>(fields[3]) + fields[4] ||
      fields[4] < sizeof(wchar_t) || fields[4] % sizeof(wchar_t) != 0) return false;
  original->exists = fields[1] != 0;
  original->type = fields[2];
  original->data.assign(backup.data.begin() + sizeof(fields), backup.data.begin() + sizeof(fields) + fields[3]);
  applied->exists = true;
  applied->type = REG_SZ;
  applied->data.assign(backup.data.begin() + sizeof(fields) + fields[3], backup.data.end());
  return true;
}

LONG HighPerformance(const GpuRegistryValue& original, GpuRegistryValue* applied) {
  std::wstring setting;
  if (original.exists) {
    if (original.type != REG_SZ || original.data.size() < sizeof(wchar_t) ||
        original.data.size() % sizeof(wchar_t) != 0) return ERROR_INVALID_DATA;
    setting.resize(original.data.size() / sizeof(wchar_t));
    std::memcpy(setting.data(), original.data.data(), original.data.size());
    if (setting.back() != L'\0') return ERROR_INVALID_DATA;
    setting.pop_back();
    if (setting.find(L'\0') != std::wstring::npos) return ERROR_INVALID_DATA;
  }
  std::wstring result;
  for (size_t start = 0; start < setting.size();) {
    const auto end = setting.find(L';', start);
    const auto token = setting.substr(start, end == std::wstring::npos ? end : end - start);
    if (!token.empty() && token.compare(0, 14, L"GpuPreference=") != 0) result += token + L';';
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  result += L"GpuPreference=2;";
  if ((result.size() + 1) * sizeof(wchar_t) > kMaximumBytes) return ERROR_MORE_DATA;
  applied->exists = true;
  applied->type = REG_SZ;
  const auto* bytes = reinterpret_cast<const BYTE*>(result.c_str());
  applied->data.assign(bytes, bytes + (result.size() + 1) * sizeof(wchar_t));
  return ERROR_SUCCESS;
}
}  // namespace

GpuPreference::GpuPreference(std::wstring executable, std::wstring gpu_key, std::wstring backup_key)
    : executable_(std::move(executable)), gpu_key_(std::move(gpu_key)), backup_key_(std::move(backup_key)) {
  initial_error_ = executable_.empty() ? ERROR_INVALID_NAME : ReadValue(gpu_key_, &initial_);
}

LONG GpuPreference::ReadValue(const std::wstring& path, GpuRegistryValue* value) const {
  *value = {};
  HKEY key = nullptr;
  auto error = RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, KEY_QUERY_VALUE, &key);
  if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return ERROR_SUCCESS;
  if (error != ERROR_SUCCESS) return error;
  DWORD size = 0, type = REG_NONE;
  error = RegQueryValueExW(key, executable_.c_str(), nullptr, &type, nullptr, &size);
  if (error == ERROR_FILE_NOT_FOUND) { RegCloseKey(key); return ERROR_SUCCESS; }
  if (error == ERROR_SUCCESS && size <= 2 * kMaximumBytes + 20) {
    std::vector<BYTE> data(size);
    error = RegQueryValueExW(key, executable_.c_str(), nullptr, &type, data.data(), &size);
    if (error == ERROR_SUCCESS) { data.resize(size); *value = {true, type, std::move(data)}; }
  } else if (error == ERROR_SUCCESS) {
    error = ERROR_MORE_DATA;
  }
  RegCloseKey(key);
  return error;
}

LONG GpuPreference::WriteValue(const std::wstring& path, const GpuRegistryValue& value) const {
  HKEY key = nullptr;
  LONG error;
  if (value.exists) {
    error = RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr);
  } else {
    error = RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, KEY_SET_VALUE, &key);
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return ERROR_SUCCESS;
  }
  if (error != ERROR_SUCCESS) return error;
  error = value.exists ? RegSetValueExW(key, executable_.c_str(), 0, value.type,
      value.data.data(), static_cast<DWORD>(value.data.size())) : RegDeleteValueW(key, executable_.c_str());
  RegCloseKey(key);
  return error == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : error;
}

LONG GpuPreference::Read(bool* enabled, bool* restart_required) const {
  if (initial_error_ != ERROR_SUCCESS) return initial_error_;
  GpuRegistryValue actual, backup, original, applied;
  auto error = ReadValue(gpu_key_, &actual);
  if (error != ERROR_SUCCESS) return error;
  error = ReadValue(backup_key_, &backup);
  if (error != ERROR_SUCCESS) return error;
  const bool saved = Unpack(backup, &original, &applied);
  if (backup.exists && !saved) return ERROR_INVALID_DATA;
  *enabled = saved && actual == applied;
  *restart_required = !(actual == initial_);
  return ERROR_SUCCESS;
}

LONG GpuPreference::SetEnabled(bool enabled) {
  if (initial_error_ != ERROR_SUCCESS) return initial_error_;
  GpuRegistryValue actual, backup, original, applied;
  auto error = ReadValue(gpu_key_, &actual);
  if (error != ERROR_SUCCESS) return error;
  error = ReadValue(backup_key_, &backup);
  if (error != ERROR_SUCCESS) return error;
  const bool saved = Unpack(backup, &original, &applied);
  if (backup.exists && !saved) return ERROR_INVALID_DATA;
  const bool owned = saved && actual == applied;
  if (!enabled) {
    // Only restore our own write. A newer Windows setting belongs to the user.
    if (owned) {
      error = WriteValue(gpu_key_, original);
      if (error != ERROR_SUCCESS) return error;
    }
    return WriteValue(backup_key_, {});
  }
  if (owned) return ERROR_SUCCESS;
  if (actual.data.size() > kMaximumBytes) return ERROR_MORE_DATA;
  error = HighPerformance(actual, &applied);
  if (error != ERROR_SUCCESS) return error;
  // Save the previous value first; interruption can never lose the user's setting.
  error = WriteValue(backup_key_, Backup(actual, applied));
  if (error != ERROR_SUCCESS) return error;
  return WriteValue(gpu_key_, applied);
}
