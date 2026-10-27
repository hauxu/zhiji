#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run').
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // 单实例：已运行则唤起已有窗口。
  ::CreateMutexW(nullptr, TRUE, L"Judging_SingleInstance_Mutex");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    // 与 win32_window.cpp 的 kWindowClassName 一致（模板默认类名是所有
  // Flutter 桌面应用共用的，按它查找会误唤醒别的应用）。
  HWND existing = ::FindWindowW(L"JUDGING_WIN32_WINDOW", nullptr);
    if (existing) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // 禁用 Impeller：部分驱动在窗口缩放时崩溃。
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1200, 800);
  if (!window.Create(L"\u4E4B\u8BA1", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
