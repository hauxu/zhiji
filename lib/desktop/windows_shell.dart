import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';

import '../util/window_bridge.dart';

/// 桌面（Windows）外壳：托盘图标、关闭最小化到托盘、开机自启。
///
/// 非 Windows 平台所有入口直接返回，不影响移动端。
class WindowsShell with TrayListener {
  WindowsShell._();

  static final WindowsShell instance = WindowsShell._();

  static const _prefMinimizeToTray = 'gd2_minimize_to_tray';
  static const _prefGlass = 'gd2_window_glass';
  static const _prefTrayHintShown = 'gd2_tray_hint_shown';
  static const _prefAutoStart = 'gd2_launch_at_startup';

  /// 由 main.dart 注入：托盘菜单「立即同步」/「打开」要用的回调。
  VoidCallback? onShowWindow;
  Future<void> Function()? onSyncNow;
  VoidCallback? onQuit;

  /// 毛玻璃开关状态；主题层监听它决定是否走透明底。
  final ValueNotifier<bool> glassEnabled = ValueNotifier<bool>(true);

  bool _ready = false;
  bool _quitting = false;

  bool get _enabled => Platform.isWindows;

  Future<void> setup({
    required VoidCallback showWindow,
    required Future<void> Function() syncNow,
    required VoidCallback quit,
  }) async {
    if (!_enabled || _ready) return;
    onShowWindow = showWindow;
    onSyncNow = syncNow;
    onQuit = quit;
    _ready = true;

    await applyGlassFromPrefs();
    trayManager.addListener(this);
    try {
      await trayManager.setIcon('assets/icon/tray.ico', isTemplate: false);
    } catch (_) {
      // 便携版可能取不到相对路径图标：用 exe 自带图标兜底。
    }
    await trayManager.setToolTip('之计');
    await _refreshMenu();
  }

  /// 读取设置并应用窗口材质：Win11 用 Mica，旧系统退亚克力。
  /// 关掉开关就回到不透明窗口。
  Future<void> applyGlassFromPrefs({bool? enabled}) async {
    if (!_enabled) return;
    final prefs = await SharedPreferences.getInstance();
    final on = enabled ?? (prefs.getBool(_prefGlass) ?? true);
    await prefs.setBool(_prefGlass, on);
    glassEnabled.value = on;
    try {
      await acrylic.Window.initialize();
    } catch (_) {}
    // 先试亚克力（模糊 + 半透明，Win10/11 都支持），失败再退纯透明。
    // color 要带一点不透明度，全透明会被插件判为非法，退回透明模式。
    final light = WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.light;
    try {
      await acrylic.Window.setEffect(
        effect:
            on ? acrylic.WindowEffect.acrylic : acrylic.WindowEffect.disabled,
        color: light ? const Color(0x40F4F1EA) : const Color(0x400E1014),
      );
      return;
    } catch (_) {}
    try {
      await acrylic.Window.setEffect(
        effect:
            on ? acrylic.WindowEffect.transparent : acrylic.WindowEffect.disabled,
      );
    } catch (_) {}
  }

  Future<bool> isGlassEnabled() async {
    if (!_enabled) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefGlass) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 设置页的「窗口毛玻璃」开关。
  Future<void> setGlassEnabled(bool value) async {
    if (!_enabled) return;
    await applyGlassFromPrefs(enabled: value);
  }

  /// 设置页的「关闭窗口时最小化到托盘」开关。
  Future<bool> isMinimizeToTray() async {
    if (!_enabled) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefMinimizeToTray) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setMinimizeToTray(bool value) async {
    if (!_enabled) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefMinimizeToTray, value);
    WindowBridge.setMinimizeToTray(value);
  }

  Future<void> _refreshMenu() async {
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '打开之计'),
        MenuItem(key: 'sync', label: '立即同步'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() {
    onShowWindow?.call();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        onShowWindow?.call();
      case 'sync':
        onSyncNow?.call();
      case 'quit':
        quitNow();
    }
  }

  /// 真正退出：先标记，避免窗口关闭事件再次拦截。
  void quitNow() {
    _quitting = true;
    trayManager.destroy().catchError((_) {});
    onQuit?.call();
  }

  /// 关闭按钮是否应该只最小化到托盘。
  Future<bool> shouldMinimizeInsteadOfQuit() async {
    if (!_enabled || _quitting) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefMinimizeToTray) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 第一次最小化时提示一次「还在后台同步」。
  Future<bool> takeTrayHintOnce() async {
    if (!_enabled) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefTrayHintShown) == true) return false;
      await prefs.setBool(_prefTrayHintShown, true);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- 开机自启 ----

  Future<bool> isAutoStartEnabled() async {
    if (!_enabled) return false;
    try {
      return await launchAtStartup.isEnabled();
    } catch (_) {
      return false;
    }
  }

  Future<bool> setAutoStart(bool value) async {
    if (!_enabled) return false;
    try {
      final info = await PackageInfo.fromPlatform();
      launchAtStartup.setup(
        appName: info.appName.isEmpty ? '之计' : info.appName,
        appPath: Platform.resolvedExecutable,
      );
      if (value) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAutoStart, value);
      return true;
    } catch (e) {
      debugPrint('auto start failed: $e');
      return false;
    }
  }

  /// 隐藏窗口到托盘（窗口在 C++ 侧控制，这里只负责托盘状态与提示）。
  Future<void> hideToTray() async {
    if (!_enabled) return;
    trayManager.setToolTip('之计 · 后台同步中').catchError((_) {});
  }

  Future<void> showFromTray() async {
    if (!_enabled) return;
    trayManager.setToolTip('之计').catchError((_) {});
  }
}