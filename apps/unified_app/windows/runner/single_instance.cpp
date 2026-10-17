#include "single_instance.h"

#include <string>
#include <wchar.h>

namespace single_instance {

namespace {

// Must match the class used when the Flutter window is created. Every Flutter
// desktop app uses it, so a candidate must also belong to this executable.
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// How long a second launch waits for a starting or closing first instance.
constexpr int kWaitStepMilliseconds = 100;
constexpr int kMaxWaitSteps = 50;

// Local\ keeps the mutex per Windows session, so separate users (and Remote
// Desktop sessions) each get their own window.
std::wstring MutexName(const wchar_t* profile_id) {
  std::wstring name = L"Local\\Subconscious.Desktop";
  if (profile_id != nullptr && profile_id[0] != L'\0') {
    name += L".";
    name += profile_id;
  }
  return name;
}

std::wstring ExecutablePathOf(DWORD process_id) {
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return L"";
  }
  wchar_t buffer[MAX_PATH * 4];
  DWORD size = static_cast<DWORD>(sizeof(buffer) / sizeof(buffer[0]));
  std::wstring path;
  if (::QueryFullProcessImageNameW(process, 0, buffer, &size)) {
    path.assign(buffer, size);
  }
  ::CloseHandle(process);
  return path;
}

struct FindContext {
  std::wstring own_path;
  DWORD own_process_id;
  HWND found;
};

BOOL CALLBACK FindWindowProc(HWND window, LPARAM parameter) {
  auto* context = reinterpret_cast<FindContext*>(parameter);
  wchar_t class_name[64];
  if (::GetClassNameW(window, class_name, 64) == 0 ||
      std::wstring(class_name) != kWindowClassName) {
    return TRUE;
  }
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0 || process_id == context->own_process_id) {
    return TRUE;
  }
  if (_wcsicmp(ExecutablePathOf(process_id).c_str(),
               context->own_path.c_str()) != 0) {
    return TRUE;
  }
  // Prefer a visible window if the process has several.
  if (context->found == nullptr || ::IsWindowVisible(window)) {
    context->found = window;
  }
  return TRUE;
}

// The runner window of another process running this same executable.
HWND FindExistingWindow() {
  FindContext context{ExecutablePathOf(::GetCurrentProcessId()),
                      ::GetCurrentProcessId(), nullptr};
  if (context.own_path.empty()) {
    return nullptr;
  }
  ::EnumWindows(FindWindowProc, reinterpret_cast<LPARAM>(&context));
  return context.found;
}
HANDLE g_instance_mutex = nullptr;

void AskExistingWindowToShow(HWND existing) {
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(existing, &process_id);
  if (process_id != 0) {
    // This process was just started by the user, so it may hand the
    // foreground right to the running instance.
    ::AllowSetForegroundWindow(process_id);
  }
  ::PostMessage(existing, ShowWindowMessage(), 0, 0);
}

}  // namespace

UINT ShowWindowMessage() {
  static const UINT message =
      ::RegisterWindowMessageW(L"Subconscious.Desktop.ShowExistingWindow");
  return message;
}

bool AcquireSingleInstance(const wchar_t* profile_id) {
  const std::wstring name = MutexName(profile_id);
  HWND existing = nullptr;
  for (int step = 0; step < kMaxWaitSteps; ++step) {
    HANDLE mutex = ::CreateMutexW(nullptr, FALSE, name.c_str());
    if (mutex != nullptr && ::GetLastError() != ERROR_ALREADY_EXISTS) {
      g_instance_mutex = mutex;  // first instance: keep it until exit
      return true;
    }
    if (mutex != nullptr) {
      ::CloseHandle(mutex);
    } else {
      // The mutex could not be created at all; do not block the app.
      return true;
    }
    existing = FindExistingWindow();
    if (existing != nullptr && ::IsWindowVisible(existing)) {
      AskExistingWindowToShow(existing);
      return false;
    }
    // The first instance is still starting (no window yet) or is closing
    // (window already hidden). Wait: if it exits, this process takes over.
    ::Sleep(kWaitStepMilliseconds);
  }
  // Still starting after the wait: it will show itself, so do not open a
  // second window. Ask it to show in case its window now exists.
  if (existing != nullptr) {
    AskExistingWindowToShow(existing);
  }
  return false;
}

void BringToFront(HWND window) {
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetForegroundWindow(window);
}

}  // namespace single_instance
