#include <windows.h>
#include <delayimp.h>
#include <iostream>
#include <string>
#include <client.h>

// Verify a delayed native client and Dart-style explicit DLL loading share the
// same module. Each variant runs in its own fresh process.
int wmain(int argc, wchar_t** argv) {
  if (argc != 3 || ::GetModuleHandleW(L"libmpv-2.dll") != nullptr) return 1;
  const auto plugin = ::LoadLibraryW(argv[2]);
  if (!plugin || ::GetModuleHandleW(L"libmpv-2.dll") != nullptr) return 2;
  const auto selected = ::LoadLibraryW(argv[1]);
  if (!selected) return 3;
  using Create = mpv_handle* (*)();
  const auto create = reinterpret_cast<Create>(::GetProcAddress(selected, "mpv_create"));
  if (!create) return 4;
  const auto handle = create();
  if (!handle) return 5;
  // This import resolves only now, after the explicit module is selected.
  const auto version = mpv_client_api_version();
  if (version == 0 || ::GetModuleHandleW(L"libmpv-2.dll") != selected) return 6;
  if (mpv_set_option_string(handle, "vo", "null") < 0 ||
      mpv_set_option_string(handle, "ao", "null") < 0 ||
      mpv_initialize(handle) < 0) return 7;
  char* text = nullptr;
  if (mpv_get_property(handle, "mpv-version", MPV_FORMAT_STRING, &text) < 0 || !text)
    return 8;
  std::cout << "Selected module shared by native client: " << text << std::endl;
  mpv_free(text);
  mpv_terminate_destroy(handle);
  return 0;
}
