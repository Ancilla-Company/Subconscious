#ifndef RUNNER_WINDOWS_FIREWALL_H_
#define RUNNER_WINDOWS_FIREWALL_H_

#include <windows.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct FirewallOperationResult {
  bool succeeded = false;
  bool cancelled = false;
  DWORD win32_error = ERROR_SUCCESS;
  DWORD helper_exit_code = 0;
};

struct FirewallOperationCompletion {
  uint64_t operation_id;
  FirewallOperationResult result;
};

// Returns an exit code when this process was launched in the private elevated
// firewall-helper mode, or nullopt for a normal Flutter launch.
std::optional<int> RunFirewallHelperIfRequested(
    const std::vector<std::string>& arguments);

// Launches an elevated copy of this executable and waits for it to add or
// remove the app-owned engine firewall rule.
FirewallOperationResult RunElevatedFirewallOperation(HWND owner,
                                                     bool enabled,
                                                     uint16_t port);

#endif  // RUNNER_WINDOWS_FIREWALL_H_