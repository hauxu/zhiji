import 'dart:io';

import 'package:flutter/services.dart';

/// Windows 原生窗口桥：标题栏主题/颜色 + 任务栏下载进度。
/// 非 Windows 平台全部为空操作。
class WindowBridge {
  WindowBridge._();

  static const MethodChannel _channel = MethodChannel('judging/window');

  /// 标题栏深浅与颜色跟随应用主题。
  /// [dark] 标题栏是否深色；[caption] 表面色 ARGB；[captionText] 文字色 ARGB。
  static Future<void> setTheme({
    required bool dark,
    required int caption,
    required int captionText,
  }) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('setTheme', {
        'dark': dark,
        'caption': caption,
        'captionText': captionText,
      });
    } catch (_) {}
  }

  /// 窗口毛玻璃：Mica（Win11）/ 亚克力（旧系统）/ 纯色。
  /// [tint] 是 0xAARRGGBB 的底色，浅色主题用浅色、深色主题用深色。
  static Future<bool> setBackdrop({
    String mode = 'mica',
    int tint = 0xCC101018,
  }) async {
    if (!Platform.isWindows) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setBackdrop', {
        'mode': mode,
        'tint': tint,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 关闭窗口时是否最小化到托盘（false = 直接退出）。
  static Future<void> setMinimizeToTray(bool value) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('setMinimizeToTray', value);
    } catch (_) {}
  }

  /// 托盘「退出」：绕过最小化拦截，真正关掉窗口。
  static Future<void> quitApp() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('quitApp', true);
    } catch (_) {}
  }

  /// flutter_acrylic 设完材质后调用：把窗框扩展清零，别让系统标题栏回来。
  static Future<void> resetFrame() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('resetFrame', true);
    } catch (_) {}
  }

  /// 标题栏关闭按钮：走原生 WM_CLOSE（最小化到托盘由那边决定）。
  static Future<void> closeWindow() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('closeWindow', true);
    } catch (_) {}
  }

  static Future<void> minimize() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('minimize', true);
    } catch (_) {}
  }

  static Future<void> toggleMaximize() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('toggleMaximize', true);
    } catch (_) {}
  }

  static Future<void> hideToTray() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('hideToTray', true);
    } catch (_) {}
  }

  static Future<void> showFromTray() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('showFromTray', true);
    } catch (_) {}
  }

  /// 主窗口收到关闭/最小化请求（已隐藏到托盘）时回调。
  static void onCloseRequested(Future<void> Function() handler) {
    if (!Platform.isWindows) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCloseRequested' ||
          call.method == 'onMinimizeRequested') {
        await handler();
      }
    });
  }

  /// 任务栏图标显示下载进度（0..1）。
  static Future<void> setProgress(double value) async {
    if (!Platform.isWindows) return;
    try {
      await _channel
          .invokeMethod<void>('setProgress', value.clamp(0.0, 1.0));
    } catch (_) {}
  }

  static Future<void> clearProgress() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('clearProgress');
    } catch (_) {}
  }
}
