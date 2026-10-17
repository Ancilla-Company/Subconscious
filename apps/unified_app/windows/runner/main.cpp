#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"
#include "windows_firewall.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  if (const std::optional<int> helper_result =
          RunFirewallHelperIfRequested(command_line_arguments)) {
    if (SUCCEEDED(com_result)) {
      ::CoUninitialize();
    }
    return *helper_result;
  }

  // One desktop window per Windows session: a second launch (for example the
  // engine tray's "Open Desktop") brings the running window to the front and
  // exits. This is after the firewall helper above, which is the same exe
  // started elevated with its own arguments.
  if (!single_instance::AcquireSingleInstance()) {
    if (SUCCEEDED(com_result)) {
      ::CoUninitialize();
    }
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Subconscious", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (SUCCEEDED(com_result)) {
    ::CoUninitialize();
  }
  return EXIT_SUCCESS;
}
