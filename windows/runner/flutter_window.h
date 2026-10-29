#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"

// Declared in shobjidl_core.h; avoids pulling wrl.h.
struct ITaskbarList3;

// Hosts a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // judging/window 通道分发：setTheme / setProgress / clearProgress。
  void HandleWindowMethod(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 任务栏进度(下载更新时显示)。
  void UpdateTaskbarProgress(double value, bool show);

  // 关闭窗口时是隐藏到托盘还是直接退出（由 Dart 侧设置）。
  bool minimize_to_tray_ = false;
  bool quit_requested_ = false;

  flutter::DartProject project_;

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<
      flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // 任务栏进度接口，懒创建。
  ITaskbarList3* taskbar_list_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
