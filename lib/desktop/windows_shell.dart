import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';

/// 桌面（Windows）外壳：托盘图标、关闭最小化到托盘、开机自启。
///
/// 非 Windows 平台所有入口直接返回，不影响移动端。
class WindowsShell with TrayListener {
  WindowsShell._();

  static final WindowsShell instance = WindowsShell._();

  static const _prefMinimizeToTray = 'gd2_minimize_to_tray';
  static const _prefTrayHintShown = 'gd2_tray_hint_shown';
  static const _prefAutoStart = 'gd2_launch_at_startup';

  /// 由 main.dart 注入：托盘菜单「立即同步」/「打开」要用的回调。
  VoidCallback? onShowWindow;
  Future<void> Function()? onSyncNow;
  VoidCallback? onQuit;

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

    trayManager.addListener(this);
    try {
      await trayManager.setIcon(
        'windows/runner/resources/app_icon.ico',
        isTemplate: false,
      );
    } catch (_) {
      // 便携版可能取不到相对路径图标：用 exe 自带图标兜底。
    }
    await trayManager.setToolTip('之计');
    await _refreshMenu();
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