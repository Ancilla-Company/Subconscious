#include "windows_firewall.h"

#include <netfw.h>
#include <shellapi.h>
#include <wrl/client.h>

#include <charconv>
#include <cstdlib>
#include <string>
#include <system_error>

namespace {

using Microsoft::WRL::ComPtr;

constexpr wchar_t kRuleName[] = L"Subconscious Engine LAN";
constexpr wchar_t kRuleDescription[] =
    L"Allows mobile Subconscious clients on the local subnet to reach the "
    L"engine.";
constexpr wchar_t kRuleGrouping[] = L"Subconscious";
constexpr char kHelperPrefix[] = "--subconscious-firewall-helper=";
constexpr char kPortPrefix[] = "--port=";
constexpr int kInvalidArgumentsExitCode = 2;
constexpr int kComFailureExitCode = 3;
constexpr int kFirewallFailureExitCode = 4;

bool HasPrefix(const std::string& value, const char* prefix) {
  return value.rfind(prefix, 0) == 0;
}

bool ParsePort(const std::string& value, uint16_t* port) {
  unsigned int parsed = 0;
  const auto result =
      std::from_chars(value.data(), value.data() + value.size(), parsed);
  if (result.ec != std::errc() || result.ptr != value.data() + value.size() ||
      parsed == 0 || parsed > 65535) {
    return false;
  }
  *port = static_cast<uint16_t>(parsed);
  return true;
}

template <typename Setter>
HRESULT SetBstr(const wchar_t* value, Setter setter) {
  BSTR string = ::SysAllocString(value);
  if (string == nullptr) {
    return E_OUTOFMEMORY;
  }
  const HRESULT result = setter(string);
  ::SysFreeString(string);
  return result;
}

HRESULT RemoveRule(INetFwRules* rules) {
  return SetBstr(kRuleName,
                 [rules](BSTR name) { return rules->Remove(name); });
}
HRESULT ConfigureFirewallRule(bool enabled, uint16_t port) {
  ComPtr<INetFwPolicy2> policy;
  HRESULT result = ::CoCreateInstance(CLSID_NetFwPolicy2, nullptr,
                                      CLSCTX_INPROC_SERVER,
                                      IID_PPV_ARGS(&policy));
  if (FAILED(result)) {
    return result;
  }

  ComPtr<INetFwRules> rules;
  result = policy->get_Rules(&rules);
  if (FAILED(result)) {
    return result;
  }

  const HRESULT remove_result = RemoveRule(rules.Get());
  if (!enabled) {
    if (SUCCEEDED(remove_result) ||
        remove_result == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) {
      return S_OK;
    }
    return remove_result;
  }

  ComPtr<INetFwRule> rule;
  result = ::CoCreateInstance(CLSID_NetFwRule, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&rule));
  if (FAILED(result)) {
    return result;
  }

  long active_profiles = 0;
  result = policy->get_CurrentProfileTypes(&active_profiles);
  if (FAILED(result)) {
    return result;
  }
  active_profiles &= NET_FW_PROFILE2_PRIVATE | NET_FW_PROFILE2_PUBLIC;
  if (active_profiles == 0) {
    active_profiles = NET_FW_PROFILE2_PRIVATE | NET_FW_PROFILE2_PUBLIC;
  }

  const std::wstring port_string = std::to_wstring(port);
  result = SetBstr(kRuleName,
                   [&rule](BSTR value) { return rule->put_Name(value); });
  if (SUCCEEDED(result)) {
    result = SetBstr(kRuleDescription, [&rule](BSTR value) {
      return rule->put_Description(value);
    });
  }
  if (SUCCEEDED(result)) {
    result = SetBstr(kRuleGrouping,
                     [&rule](BSTR value) { return rule->put_Grouping(value); });
  }
  if (SUCCEEDED(result)) {
    result = rule->put_Protocol(NET_FW_IP_PROTOCOL_TCP);
  }
  if (SUCCEEDED(result)) {
    result = SetBstr(port_string.c_str(), [&rule](BSTR value) {
      return rule->put_LocalPorts(value);
    });
  }
  if (SUCCEEDED(result)) {
    result = SetBstr(L"LocalSubnet", [&rule](BSTR value) {
      return rule->put_RemoteAddresses(value);
    });
  }
  if (SUCCEEDED(result)) {
    result = rule->put_Direction(NET_FW_RULE_DIR_IN);
  }
  if (SUCCEEDED(result)) {
    result = rule->put_Action(NET_FW_ACTION_ALLOW);
  }
  if (SUCCEEDED(result)) {
    result = rule->put_Profiles(active_profiles);
  }
  if (SUCCEEDED(result)) {
    result = rule->put_EdgeTraversal(VARIANT_FALSE);
  }
  if (SUCCEEDED(result)) {
    result = rule->put_Enabled(VARIANT_TRUE);
  }
  return SUCCEEDED(result) ? rules->Add(rule.Get()) : result;
}
std::wstring CurrentExecutablePath() {
  std::wstring path(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return std::wstring();
  }
  path.resize(length);
  return path;
}

}  // namespace

std::optional<int> RunFirewallHelperIfRequested(
    const std::vector<std::string>& arguments) {
  if (arguments.empty() || !HasPrefix(arguments[0], kHelperPrefix)) {
    return std::nullopt;
  }
  if (arguments.size() != 2 || !HasPrefix(arguments[1], kPortPrefix)) {
    return kInvalidArgumentsExitCode;
  }

  const std::string action = arguments[0].substr(sizeof(kHelperPrefix) - 1);
  const std::string port_value = arguments[1].substr(sizeof(kPortPrefix) - 1);
  const bool enabled = action == "add";
  if (!enabled && action != "remove") {
    return kInvalidArgumentsExitCode;
  }

  uint16_t port = 0;
  if (enabled && !ParsePort(port_value, &port)) {
    return kInvalidArgumentsExitCode;
  }
  if (!enabled && port_value != "0") {
    return kInvalidArgumentsExitCode;
  }

  const HRESULT result = ConfigureFirewallRule(enabled, port);
  if (SUCCEEDED(result)) {
    return EXIT_SUCCESS;
  }
  return result == CO_E_NOTINITIALIZED ? kComFailureExitCode
                                       : kFirewallFailureExitCode;
}

FirewallOperationResult RunElevatedFirewallOperation(HWND owner,
                                                     bool enabled,
                                                     uint16_t port) {
  FirewallOperationResult result;
  const std::wstring executable = CurrentExecutablePath();
  if (executable.empty()) {
    result.win32_error = ::GetLastError();
    return result;
  }

  const std::wstring parameters =
      std::wstring(L"--subconscious-firewall-helper=") +
      (enabled ? L"add" : L"remove") + L" --port=" +
      std::to_wstring(enabled ? port : 0);
  SHELLEXECUTEINFOW execute_info = {};
  execute_info.cbSize = sizeof(execute_info);
  execute_info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  execute_info.hwnd = owner;
  execute_info.lpVerb = L"runas";
  execute_info.lpFile = executable.c_str();
  execute_info.lpParameters = parameters.c_str();
  execute_info.nShow = SW_HIDE;
  if (!::ShellExecuteExW(&execute_info)) {
    result.win32_error = ::GetLastError();
    result.cancelled = result.win32_error == ERROR_CANCELLED;
    return result;
  }

  const DWORD wait_result =
      ::WaitForSingleObject(execute_info.hProcess, INFINITE);
  if (wait_result != WAIT_OBJECT_0) {
    result.win32_error = ::GetLastError();
    ::CloseHandle(execute_info.hProcess);
    return result;
  }

  DWORD exit_code = kFirewallFailureExitCode;
  if (!::GetExitCodeProcess(execute_info.hProcess, &exit_code)) {
    result.win32_error = ::GetLastError();
    ::CloseHandle(execute_info.hProcess);
    return result;
  }
  ::CloseHandle(execute_info.hProcess);
  result.helper_exit_code = exit_code;
  result.succeeded = exit_code == EXIT_SUCCESS;
  return result;
}
