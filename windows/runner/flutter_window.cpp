#include "flutter_window.h"

#include <windowsx.h>
#include <cstdio>
#include <string>

#include <dwmapi.h>
#include <objidl.h>
#include <shobjidl_core.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "flutter/method_channel.h"
#include "flutter/standard_method_codec.h"

namespace {

// 之计窗口桥：标题栏主题/颜色 + 任务栏下载进度。
constexpr char kWindowChannelName[] = "judging/window";

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif

// Win10/11 的亚克力（Accent）结构，user32 未公开但有文档化用法。
struct AccentPolicy {
  int accent_state;
  int accent_flags;
  int gradient_color;
  int animation_id;
};
struct WindowCompositionAttributeData {
  int attribute;
  void* data;
  unsigned long size_of_data;
};
enum {
  WCA_ACCENT_POLICY = 19,
  ACCENT_DISABLED = 0,
  ACCENT_ENABLE_BLURBEHIND = 3,
  ACCENT_ENABLE_ACRYLICBLURBEHIND = 4,
};

BOOL ApplyAccent(HWND hwnd, int state, int gradient_color) {
  using SetWindowCompositionAttributeFn =
      BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);
  auto user32 = GetModuleHandleW(L"user32.dll");
  if (!user32) return FALSE;
  auto fn = reinterpret_cast<SetWindowCompositionAttributeFn>(
      GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (!fn) return FALSE;
  AccentPolicy policy{state, 2, gradient_color, 0};
  WindowCompositionAttributeData data{WCA_ACCENT_POLICY, &policy,
                                     sizeof(policy)};
  return fn(hwnd, &data);
}

// ARGB (Dart 0xAARRGGBB) -> COLORREF (0x00BBGGRR)。
COLORREF ArgbToColorRef(int64_t argb) {
  const int r = (argb >> 16) & 0xFF;
  const int g = (argb >> 8) & 0xFF;
  const int b = argb & 0xFF;
  return RGB(r, g, b);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  // 明确按普通窗口排序，避免被其它工具或上次运行设成置顶。
  HWND self = GetHandle();
  if (self) {
    ::SetWindowPos(self, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  RECT frame = GetClientArea();

  // Size must match the window to avoid surface churn at startup.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleWindowMethod(call, std::move(result));
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Ensure a frame is pending so the window is shown.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (taskbar_list_) {
    taskbar_list_->Release();
    taskbar_list_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleWindowMethod(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "setTheme") {
    // 参数：dark(bool), caption(int64 ARGB), captionText(int64 ARGB)。
    bool dark = false;
    int64_t caption = 0xFF101018;
    int64_t caption_text = 0xFFF0F0F5;
    const auto* args = method_call.arguments();
    if (args && std::holds_alternative<flutter::EncodableMap>(*args)) {
      const auto& map = std::get<flutter::EncodableMap>(*args);
      auto dark_it = map.find(flutter::EncodableValue("dark"));
      if (dark_it != map.end() && std::holds_alternative<bool>(dark_it->second)) {
        dark = std::get<bool>(dark_it->second);
      }
      auto cap_it = map.find(flutter::EncodableValue("caption"));
      if (cap_it != map.end() && std::holds_alternative<int64_t>(cap_it->second)) {
        caption = std::get<int64_t>(cap_it->second);
      }
      auto text_it = map.find(flutter::EncodableValue("captionText"));
      if (text_it != map.end() && std::holds_alternative<int64_t>(text_it->second)) {
        caption_text = std::get<int64_t>(text_it->second);
      }
    }
    HWND hwnd = GetHandle();
    if (hwnd) {
      BOOL use_dark = dark ? TRUE : FALSE;
      // 旧系统不支持时静默忽略。
      DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &use_dark,
                            sizeof(use_dark));
      // caption < 0 表示交给 DWM 自己决定（开毛玻璃时用，避免画出实底白条）。
      if (caption >= 0) {
        COLORREF cap = ArgbToColorRef(caption);
        DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &cap, sizeof(cap));
      }
      COLORREF cap_text = ArgbToColorRef(caption_text);
      DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, &cap_text,
                            sizeof(cap_text));
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setBackdrop") {
    // 参数：mode("mica"/"acrylic"/"solid") + tint(int64 ARGB)。
    // Win11 用系统 Mica；失败或旧系统退回 Accent 亚克力；再不行就是纯色。
    std::string mode = "solid";
    int64_t tint = 0xCC101018;  // 默认深色半透明
    const auto* args = method_call.arguments();
    if (args && std::holds_alternative<flutter::EncodableMap>(*args)) {
      const auto& map = std::get<flutter::EncodableMap>(*args);
      auto mode_it = map.find(flutter::EncodableValue("mode"));
      if (mode_it != map.end() &&
          std::holds_alternative<std::string>(mode_it->second)) {
        mode = std::get<std::string>(mode_it->second);
      }
      auto tint_it = map.find(flutter::EncodableValue("tint"));
      if (tint_it != map.end() &&
          std::holds_alternative<int64_t>(tint_it->second)) {
        tint = std::get<int64_t>(tint_it->second);
      }
    }
    HWND hwnd = GetHandle();
    bool applied = false;
    if (hwnd) {
      // 不要把 DWM 窗框扩到客户区：一扩系统标题栏就又画回来了。
      MARGINS margins{0, 0, 0, 0};
      DwmExtendFrameIntoClientArea(hwnd, &margins);
      // 优先用系统材质：Win11 22H2 起 DWM 的原生亚克力带模糊和噪点，
      // 比自己拿 Accent 抹一层要好看得多。
      if (mode == "acrylic") {
        int type = 3;  // DWMSBT_TRANSIENTWINDOW（亚克力）
        if (SUCCEEDED(DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE,
                                            &type, sizeof(type)))) {
          applied = true;
        }
      }
      if (!applied && mode == "mica") {
        int type = 2;  // DWMSBT_MAINWINDOW
        if (SUCCEEDED(DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE,
                                            &type, sizeof(type)))) {
          applied = true;
        }
      }
      // 深色主题要告诉 DWM，否则系统材质按浅色画。
      if (applied) {
        BOOL dark = (tint & 0x00FFFFFF) < 0x00808080 ? TRUE : FALSE;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark,
                              sizeof(dark));
      }
      if (!applied && (mode == "mica" || mode == "acrylic")) {
        // 0xAABBGGRR 的 ABGR 顺序（Accent 用的是 0xAABBGGRR）。
        const int r = (tint >> 16) & 0xFF;
        const int g = (tint >> 8) & 0xFF;
        const int b = tint & 0xFF;
        const int a = (tint >> 24) & 0xFF;
        int gradient = (a << 24) | (b << 16) | (g << 8) | r;
        applied = ApplyAccent(hwnd, ACCENT_ENABLE_ACRYLICBLURBEHIND, gradient) != 0;
        if (!applied) {
          applied = ApplyAccent(hwnd, ACCENT_ENABLE_BLURBEHIND, gradient) != 0;
        }
      }
      if (!applied) {
        MARGINS zero{0, 0, 0, 0};
        DwmExtendFrameIntoClientArea(hwnd, &zero);
        ApplyAccent(hwnd, ACCENT_DISABLED, 0);
      }
      // 扩展了窗框之后客户区变大，Flutter 子窗口要重新贴合，
      // 否则窗口边缘会留一条没被盖住的缝。
      ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                         SWP_FRAMECHANGED);
      RECT rc{};
      ::GetClientRect(hwnd, &rc);
      if (child_content() != nullptr) {
        ::MoveWindow(child_content(), rc.left, rc.top,
                     rc.right - rc.left, rc.bottom - rc.top, TRUE);
      }
      ::InvalidateRect(hwnd, nullptr, TRUE);
    }
    result->Success(flutter::EncodableValue(applied));
    return;
  }

  if (method == "setMinimizeToTray") {
    const auto* args = method_call.arguments();
    bool value = true;
    if (args && std::holds_alternative<bool>(*args)) {
      value = std::get<bool>(*args);
    }
    minimize_to_tray_ = value;
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "quitApp") {
    // 托盘「退出」：先关掉拦截，再走正常关闭流程。
    minimize_to_tray_ = false;
    quit_requested_ = true;
    HWND hwnd = GetHandle();
    if (hwnd) {
      ::PostMessage(hwnd, WM_CLOSE, 0, 0);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "resetFrame") {
    // flutter_acrylic 会把 DWM 窗框扩进客户区（系统标题栏会重新出现），
    // 设完材质再清零，保持自绘标题栏。
    HWND hwnd = GetHandle();
    if (hwnd) {
      MARGINS zero{0, 0, 0, 0};
      DwmExtendFrameIntoClientArea(hwnd, &zero);
      ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
      RECT rc{};
      ::GetClientRect(hwnd, &rc);
      if (child_content() != nullptr) {
        ::MoveWindow(child_content(), rc.left, rc.top, rc.right - rc.left,
                     rc.bottom - rc.top, TRUE);
      }
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "closeWindow") {
    // 走正常的 WM_CLOSE：收托盘、通知 Dart 侧都由那一条路径负责。
    HWND hwnd = GetHandle();
    if (hwnd) ::PostMessage(hwnd, WM_CLOSE, 0, 0);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "minimize") {
    HWND hwnd = GetHandle();
    if (hwnd) ::ShowWindow(hwnd, SW_MINIMIZE);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "toggleMaximize") {
    HWND hwnd = GetHandle();
    if (hwnd) {
      ::ShowWindow(hwnd, ::IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "hideToTray" || method == "showFromTray") {
    HWND hwnd = GetHandle();
    if (hwnd) {
      if (method == "hideToTray") {
        ::ShowWindow(hwnd, SW_HIDE);
      } else {
        ::ShowWindow(hwnd, SW_SHOW);
        ::SetForegroundWindow(hwnd);
      }
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setProgress" || method == "clearProgress") {
    double value = 0.0;
    if (method == "setProgress") {
      const auto* args = method_call.arguments();
      if (args && std::holds_alternative<double>(*args)) {
        value = std::get<double>(*args);
      } else if (args && std::holds_alternative<int64_t>(*args)) {
        value = static_cast<double>(std::get<int64_t>(*args));
      }
    }
    UpdateTaskbarProgress(value, method == "setProgress");
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}

void FlutterWindow::UpdateTaskbarProgress(double value, bool show) {
  if (!taskbar_list_) {
    HRESULT hr = CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&taskbar_list_));
    if (FAILED(hr)) return;
  }
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  if (!show) {
    taskbar_list_->SetProgressState(hwnd, TBPF_NOPROGRESS);
    return;
  }
  taskbar_list_->SetProgressState(hwnd, TBPF_NORMAL);
  taskbar_list_->SetProgressValue(
      hwnd, static_cast<ULONGLONG>(value * 100.0 + 0.5), 100);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 自绘边框相关的消息要在转发给引擎之前处理，否则会被它先消费掉。
  switch (message) {
    // 客户区铺满整个窗口：系统标题栏和边框都不要了，材质才能连成一片。
    case WM_NCCALCSIZE:
      if (wparam == TRUE) {
        // 客户区 = 整个窗口；最大化时对齐工作区，别被屏幕边缘裁掉。
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        if (::IsZoomed(hwnd)) {
          HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
          MONITORINFO mi{};
          mi.cbSize = sizeof(mi);
          if (::GetMonitorInfo(monitor, &mi)) {
            params->rgrc[0] = mi.rcWork;
          }
        }
        return 0;
      }
      break;
    // 最大化按工作区算，别盖住任务栏（自绘边框后系统算不准）。
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      UINT dpi = ::GetDpiForWindow(hwnd);
      if (dpi == 0) dpi = 96;
      info->ptMinTrackSize.x = ::MulDiv(900, dpi, 96);
      info->ptMinTrackSize.y = ::MulDiv(640, dpi, 96);
      HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      MONITORINFO mi{};
      mi.cbSize = sizeof(mi);
      if (::GetMonitorInfo(monitor, &mi)) {
        info->ptMaxPosition.x = mi.rcWork.left - mi.rcMonitor.left;
        info->ptMaxPosition.y = mi.rcWork.top - mi.rcMonitor.top;
        info->ptMaxSize.x = mi.rcWork.right - mi.rcWork.left;
        info->ptMaxSize.y = mi.rcWork.bottom - mi.rcWork.top;
      }
      return 0;
    }
    // 系统把最大化算到屏幕边界（自绘边框后多出 8px），这里按工作区摆正。
    case WM_SIZE:
      if (wparam == SIZE_MAXIMIZED && !maximizing_) {
        maximizing_ = true;
        HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        MONITORINFO mi{};
        mi.cbSize = sizeof(mi);
        if (::GetMonitorInfo(monitor, &mi)) {
          ::SetWindowPos(hwnd, nullptr, mi.rcWork.left, mi.rcWork.top,
                         mi.rcWork.right - mi.rcWork.left,
                         mi.rcWork.bottom - mi.rcWork.top,
                         SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
        maximizing_ = false;
      }
      break;
    // 自己算拖动区和缩放边：顶部 38dp 是标题栏，右侧按钮区留出来给 Flutter。
    case WM_NCHITTEST: {
      POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      RECT wr{};
      ::GetWindowRect(hwnd, &wr);
      UINT dpi = ::GetDpiForWindow(hwnd);
      if (dpi == 0) dpi = 96;
      const int border = ::MulDiv(6, dpi, 96);
      const int caption = ::MulDiv(38, dpi, 96);
      const int buttons = ::MulDiv(150, dpi, 96);
      const bool left = pt.x < wr.left + border;
      const bool right = pt.x >= wr.right - border;
      const bool top = pt.y < wr.top + border;
      const bool bottom = pt.y >= wr.bottom - border;
      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;
      if (pt.y < wr.top + caption && pt.x < wr.right - buttons) {
        return HTCAPTION;
      }
      break;
    }
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
    case WM_CLOSE:
      // 开了「最小化到托盘」就隐藏窗口，交给托盘继续后台同步。
      if (minimize_to_tray_ && !quit_requested_) {
        if (window_channel_) {
          window_channel_->InvokeMethod(
              "onCloseRequested",
              std::make_unique<flutter::EncodableValue>(true));
        }
        ::ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
