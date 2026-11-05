#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "external_download_request.h"
#include "native_diagnostics.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const auto launch_arguments = GetCommandLineArguments();
  const bool player_window = launch_arguments.size() == 2 &&
      launch_arguments[0] == "--asterlink-player-window";
  HANDLE single_instance = player_window ? nullptr :
      ::CreateMutexW(nullptr, FALSE, L"Local\\AsterLink.Flutter.v1");
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(nullptr, L"\u6587\u6790\u52a9\u624b");
    const auto request = DownloadLaunchArgument(GetCommandLineArguments());
    if (!request.empty()) {
      for (int attempt = 0; !existing && attempt < 40; ++attempt) {
        ::Sleep(50);
        existing = ::FindWindowW(nullptr, L"\u6587\u6790\u52a9\u624b");
      }
      COPYDATASTRUCT data{};
      data.dwData = kExternalDownloadMessage;
      data.cbData = static_cast<DWORD>(request.size() + 1);
      data.lpData = const_cast<char*>(request.c_str());
      DWORD_PTR accepted = 0;
      if (!existing || !::SendMessageTimeoutW(existing, WM_COPYDATA, 0,
          reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG | SMTO_BLOCK,
          3000, &accepted) || accepted == 0) {
        ::MessageBoxW(nullptr, L"外部链接暂未送达，请等待文析助手启动完成后重试。",
                      L"文析助手", MB_OK | MB_ICONINFORMATION);
      }
    }
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  NativeDiagnostics::Instance().Initialize();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(player_window ? 480 : 1280, player_window ? 330 : 720);
  if (!window.Create(player_window ? L"视频小窗" : L"\u6587\u6790\u52a9\u624b", origin, size)) {
    NativeDiagnostics::Instance().Record("windows.window_create_failed", 0, 0, 0);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // window_manager.destroy posts WM_QUIT without first destroying the HWND.
  // Tear down the view while the derived window and COM are still available.
  window.Destroy();
  ::CoUninitialize();
  NativeDiagnostics::Instance().Shutdown();
  if (single_instance != nullptr) ::CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
