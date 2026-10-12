#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Synchronizes Flutter's active color scheme with the native DWM frame.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_frame_channel_;

  // Runs narrowly scoped, user-approved Windows Firewall operations.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      firewall_channel_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
      pending_firewall_result_;
  uint64_t next_firewall_operation_id_ = 0;
  uint64_t pending_firewall_operation_id_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
