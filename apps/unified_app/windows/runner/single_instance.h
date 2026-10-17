#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// Keeps a single Subconscious desktop window per Windows session.
//
// The first process owns a named mutex. Any later launch (tray menu, Start
// menu, a double click, the execution alias) asks the first window to come
// to the front and exits instead of opening a second window.
//
// To allow one window per account or profile later, pass a profile id to
// AcquireSingleInstance; it becomes part of the mutex name and the window
// lookup, so different profiles do not block each other.
namespace single_instance {

// Registered window message sent to the running window to show itself.
UINT ShowWindowMessage();

// Returns true when this process is the only instance and should start the
// app. Returns false when another instance exists (it has been asked to show
// its window) and this process should exit. The mutex handle is kept for the
// life of the process.
bool AcquireSingleInstance(const wchar_t* profile_id = L"");

// Restores and focuses [window]. Called by the window on ShowWindowMessage().
void BringToFront(HWND window);

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_
