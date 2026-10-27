#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// High DPI-aware Win32 window base class.
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a DPI-scaled window at |origin| with |size|;
  // invisible until |Show|. Returns true on success.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  bool Show();

  void Destroy();

  void SetChildContent(HWND content);

  // 子窗口句柄（Flutter 视图），供窗体材质变更后重新贴合。
  HWND child_content() const { return child_content_; }

  // Backing window handle; nullptr after destroy.
  HWND GetHandle();

  void SetQuitOnClose(bool quit_on_close);

  RECT GetClientArea();

 protected:
  // Handles window messages.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called on creation; return false to abort.
  virtual bool OnCreate();

  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // OS callback; handles WM_NCCREATE and non-client DPI scaling,
  // everything else goes to MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  HWND window_handle_ = nullptr;

  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
