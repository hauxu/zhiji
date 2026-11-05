#include "flutter_window.h"

#include <windowsx.h>

#include <dwmapi.h>
#include <objidl.h>
#include <shobjidl_core.h>

#include <optional>
#include <thread>
#include <cstdio>

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
  HWND self = GetHandle();
  if (self) {
    // 强制去掉 WS_CAPTION（创建时可能被 DWM 补回），材质才会铺满整窗。
    LONG_PTR style = ::GetWindowLongPtr(self, GWL_STYLE);
    ::SetWindowLongPtr(self, GWL_STYLE, style & ~WS_CAPTION);
    // 按普通窗口排序，别被上次运行或外部工具留成置顶。
    ::SetWindowPos(self, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
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
      // 把客户区扩展到整个窗口，毛玻璃才有地方显示。
      MARGINS margins{-1, -1, -1, -1};
      DwmExtendFrameIntoClientArea(hwnd, &margins);
      if (mode == "mica") {
        int type = 2;  // DWMSBT_MAINWINDOW
        if (SUCCEEDED(DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE,
                                            &type, sizeof(type)))) {
          applied = true;
        }
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

  if (method == "matchTitleBar") {
    // 顶栏那条的底色按「窗口上方屏幕颜色」取：那正是顶栏背后该有的材质。
    HWND hwnd = GetHandle();
    if (hwnd == nullptr) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    double alpha = 0.34;
    int64_t surface = 0;
    const auto* args = method_call.arguments();
    if (args && std::holds_alternative<flutter::EncodableMap>(*args)) {
      const auto& map = std::get<flutter::EncodableMap>(*args);
      auto a_it = map.find(flutter::EncodableValue("alpha"));
      if (a_it != map.end() && std::holds_alternative<double>(a_it->second)) {
        alpha = std::get<double>(a_it->second);
      }
      auto s_it = map.find(flutter::EncodableValue("surface"));
      if (s_it != map.end() && std::holds_alternative<int64_t>(s_it->second)) {
        surface = std::get<int64_t>(s_it->second);
      }
    }
    RECT wr{};
    ::GetWindowRect(hwnd, &wr);
    int w = wr.right - wr.left;
    // 采样正文紧贴顶栏的位置：那才是顶栏旁边真实的表现。
    UINT dpi0 = ::GetDpiForWindow(hwnd);
    if (dpi0 == 0) dpi0 = 96;
    int y = wr.top + ::MulDiv(42, dpi0, 96);
    int rs[5] = {0}, gs[5] = {0}, bs[5] = {0};
    HDC dc = ::GetDC(nullptr);
    for (int i = 0; i < 5; i++) {
      int x = wr.left + static_cast<int>(w * (0.08 + 0.21 * i));
      COLORREF c = ::GetPixel(dc, x, y);
      rs[i] = GetRValue(c);
      gs[i] = GetGValue(c);
      bs[i] = GetBValue(c);
    }
    ::ReleaseDC(nullptr, dc);
    for (int i = 0; i < 5; i++) {
      for (int j = i + 1; j < 5; j++) {
        if (rs[j] < rs[i]) std::swap(rs[i], rs[j]);
        if (gs[j] < gs[i]) std::swap(gs[i], gs[j]);
        if (bs[j] < bs[i]) std::swap(bs[i], bs[j]);
      }
    }
    // 正文 = 雾面(α) 盖在背景上；反解出让顶栏与之一致的 caption 色。
    int sr = (surface >> 16) & 0xFF;
    int sg = (surface >> 8) & 0xFF;
    int sb = surface & 0xFF;
    double keep = 1.0 - alpha;
    auto solve = [&](int rendered, int surf) -> int {
      if (keep < 0.05) return surf;
      int v = static_cast<int>((rendered - alpha * surf) / keep + 0.5);
      return v < 0 ? 0 : (v > 255 ? 255 : v);
    };
    COLORREF target = RGB(solve(rs[2], sr), solve(gs[2], sg), solve(bs[2], sb));
    ::DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &target, sizeof(target));
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "extendFrame") {
    // 插件只扩展了左边（{-1,0,0,0}），顶栏那条因此没有材质。
    // 四边全部扩展，DWM 材质才会铺满整窗，顶栏与正文看到同一块背景。
    frame_extend_on_ = true;
    HWND hwnd = GetHandle();
    if (hwnd != nullptr) {
      // 只设扩展，不动窗口位置/尺寸：SetWindowPos(FRAMECHANGED) 会让
      // DWM 重新计算窗框，把刚设的扩展收回。
      // 换后台线程调用：主线程直接调用不生效（外部进程调用却有效）。
      MARGINS all{-1, -1, -1, -1};
      std::thread([this, hwnd, all]() {
        DwmExtendFrameIntoClientArea(hwnd, &all);
        if (child_content() != nullptr) {
          DwmExtendFrameIntoClientArea(child_content(), &all);
        }
      }).detach();
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "clearFrameExtend") {
    frame_extend_on_ = false;
    HWND hwnd = GetHandle();
    if (hwnd) {
      MARGINS zero{0, 0, 0, 0};
      DwmExtendFrameIntoClientArea(hwnd, &zero);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "dragWindow") {
    // 自绘标题栏在 Flutter 视图之外收不到命中测试，拖动由 Flutter 侧发起：
    // 模拟一次标题栏按下，交给系统进入移动循环。
    HWND hwnd = GetHandle();
    if (hwnd) {
      ::ReleaseCapture();
      ::SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    }
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
    if (hwnd) ::ShowWindow(hwnd, ::IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "closeWindow") {
    // 走正常 WM_CLOSE：收托盘、通知 Dart 侧都由那条路径负责。
    HWND hwnd = GetHandle();
    if (hwnd) ::PostMessage(hwnd, WM_CLOSE, 0, 0);
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
  // 窗口移动/尺寸变化后 DWM 会收回窗框扩展，这里立刻补回来。
  if (message == WM_WINDOWPOSCHANGED && frame_extend_on_) {
    MARGINS all{-1, -1, -1, -1};
    std::thread([this, hwnd, all]() {
      DwmExtendFrameIntoClientArea(hwnd, &all);
      if (child_content() != nullptr) {
        DwmExtendFrameIntoClientArea(child_content(), &all);
      }
    }).detach();
  }

  // 自绘边框的消息要在转发给引擎之前处理，否则会被它先消费掉。
  switch (message) {
    // 客户区铺满整个窗口：系统标题栏和边框都不要，材质才能连成一片。
    case WM_NCCALCSIZE:
      if (wparam == TRUE) {
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
    // 拖动区和缩放边自己算：顶部 38dp 拖动，右侧 150dp 留给标题栏按钮。
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
