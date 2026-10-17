#include "flutter_window.h"

#include <windows.h>

#include <cstdint>
#include <optional>
#include <string>
#include <thread>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"
#include "windows_firewall.h"

namespace {

constexpr UINT kFirewallCompletionMessage = WM_APP + 42;

std::optional<int64_t> ReadInteger(
    const flutter::EncodableMap& arguments,
    const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&iterator->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&iterator->second)) {
    return *value;
  }
  return std::nullopt;
}

std::optional<uint32_t> ReadColor(const flutter::EncodableMap& arguments,
                                  const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&iterator->second)) {
    return static_cast<uint32_t>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&iterator->second)) {
    return static_cast<uint32_t>(*value);
  }
  return std::nullopt;
}

COLORREF ColorRefFromArgb(uint32_t argb) {
  return RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  window_frame_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "company.ancilla.subconscious/window_frame",
          &flutter::StandardMethodCodec::GetInstance());
  window_frame_channel_->SetMethodCallHandler(
      [this](const auto& method_call, auto result) {
        if (method_call.method_name() != "setAppearance") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(method_call.arguments());
        if (!arguments) {
          result->Error("invalid_arguments", "Expected an argument map.");
          return;
        }
        const std::optional<uint32_t> border_color =
            ReadColor(*arguments, "borderColor");
        const std::optional<uint32_t> caption_color =
            ReadColor(*arguments, "captionColor");
        const auto dark_iterator =
            arguments->find(flutter::EncodableValue("dark"));
        const bool* use_dark_mode =
            dark_iterator == arguments->end()
                ? nullptr
                : std::get_if<bool>(&dark_iterator->second);
        if (!border_color || !caption_color || !use_dark_mode) {
          result->Error("invalid_arguments",
                        "Expected borderColor, captionColor, and dark.");
          return;
        }
        SetFrameAppearance(ColorRefFromArgb(*border_color),
                           ColorRefFromArgb(*caption_color), *use_dark_mode);
        result->Success();
      });

  firewall_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "company.ancilla.subconscious/windows_firewall",
          &flutter::StandardMethodCodec::GetInstance());
  firewall_channel_->SetMethodCallHandler(
      [this](const auto& method_call, auto result) {
        if (method_call.method_name() != "setEngineRule") {
          result->NotImplemented();
          return;
        }
        if (pending_firewall_result_) {
          result->Error("busy", "A firewall operation is already pending.");
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(method_call.arguments());
        if (!arguments) {
          result->Error("invalid_arguments", "Expected an argument map.");
          return;
        }
        const auto enabled_iterator =
            arguments->find(flutter::EncodableValue("enabled"));
        const bool* enabled =
            enabled_iterator == arguments->end()
                ? nullptr
                : std::get_if<bool>(&enabled_iterator->second);
        const std::optional<int64_t> requested_port =
            ReadInteger(*arguments, "port");
        if (!enabled ||
            (*enabled && (!requested_port || *requested_port < 1 ||
                          *requested_port > 65535))) {
          result->Error("invalid_arguments",
                        "Add requires a TCP port from 1 to 65535.");
          return;
        }

        const uint16_t port =
            *enabled ? static_cast<uint16_t>(*requested_port) : 0;
        const uint64_t operation_id = ++next_firewall_operation_id_;
        pending_firewall_operation_id_ = operation_id;
        pending_firewall_result_ = std::move(result);
        const HWND owner = GetHandle();
        std::thread([owner, enabled = *enabled, port, operation_id]() {
          const HRESULT com_result =
              ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
          FirewallOperationResult operation_result =
              RunElevatedFirewallOperation(owner, enabled, port);
          if (SUCCEEDED(com_result)) {
            ::CoUninitialize();
          }
          auto* completion = new FirewallOperationCompletion{
              operation_id, operation_result};
          if (!::PostMessage(owner, kFirewallCompletionMessage, 0,
                             reinterpret_cast<LPARAM>(completion))) {
            delete completion;
          }
        }).detach();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (pending_firewall_result_) {
    pending_firewall_result_->Error(
        "window_closed", "The app closed before the firewall operation ended.");
    pending_firewall_result_.reset();
  }
  firewall_channel_.reset();
  window_frame_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kFirewallCompletionMessage) {
    auto* completion = reinterpret_cast<FirewallOperationCompletion*>(lparam);
    if (completion != nullptr && pending_firewall_result_ &&
        completion->operation_id == pending_firewall_operation_id_) {
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result =
          std::move(pending_firewall_result_);
      const FirewallOperationResult operation_result = completion->result;
      if (operation_result.succeeded) {
        result->Success();
      } else if (operation_result.cancelled) {
        result->Error("cancelled", "The Windows administrator prompt was cancelled.");
      } else if (operation_result.win32_error != ERROR_SUCCESS) {
        result->Error(
            "windows_error", "Windows could not start the firewall helper.",
            flutter::EncodableValue(
                static_cast<int64_t>(operation_result.win32_error)));
      } else {
        result->Error(
            "firewall_error", "Windows could not update the firewall rule.",
            flutter::EncodableValue(
                static_cast<int64_t>(operation_result.helper_exit_code)));
      }
    }
    delete completion;
    return 0;
  }

  // A second launch asks this window to show itself instead of opening one.
  if (message == single_instance::ShowWindowMessage()) {
    single_instance::BringToFront(hwnd);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
