import 'dart:io';
import 'dart:ui' show PluginUtilities;

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'keepalive_entry.dart';

/// 后台保活桥：常驻前台服务 + 一条独立的 Dart 引擎，主界面被划掉后
/// 仍能靠长轮询收消息并弹通知（不使用任何厂商推送）。
///
/// 只负责「让引擎活着、让连接不断」；通知统一走 [Notify]。
/// 非 Android 平台全部为空操作。
class KeepAliveBridge {
  KeepAliveBridge._();

  static const _channel = MethodChannel('judging/keepalive');

  /// 本机开关（默认开）。仅 Android 有意义。
  static bool enabled = true;

  /// 上次从系统读到的权限状态，供设置页展示。
  static bool notificationsEnabled = false;
  static bool ignoringBatteryOptimizations = false;

  static Future<void> load() async {
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool('gd2_keep_alive') ?? true;
    } catch (_) {}
  }

  /// 启动保活：把后台入口的回调句柄交给原生，由服务另起引擎执行。
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      final handle = PluginUtilities.getCallbackHandle(keepAliveEntry);
      await _channel.invokeMethod('startKeepAlive', {
        'handle': handle?.toRawHandle() ?? 0,
      });
    } catch (_) {}
  }

  /// 停止保活并移除常驻通知。
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopKeepAlive');
    } catch (_) {}
  }

  /// 刷新常驻通知里的「最近同步」时间（每次成功同步后调用）。
  static Future<void> touchLastSync() async {
    if (!Platform.isAndroid || !enabled) return;
    try {
      await _channel.invokeMethod('refreshKeepAlive');
    } catch (_) {}
  }

  /// 是否已登录（读本机 token，不依赖 SyncService 初始化）。
  static Future<bool> hasSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('gd2_token') ?? '';
      return token.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 刷新系统状态：通知权限、电池优化豁免。设置页打开时调用。
  static Future<void> refreshSystemState() async {
    if (!Platform.isAndroid) return;
    try {
      notificationsEnabled =
          await _channel.invokeMethod<bool>('notificationsEnabled') ?? false;
      ignoringBatteryOptimizations =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
              false;
    } catch (_) {}
  }

  /// 打开系统「忽略电池优化」页。
  static Future<bool> openBatterySettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openBatterySettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 保存开关（纯持久化；是否真正启停由 SyncService 按会话状态决定）。
  static Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('gd2_keep_alive', value);
    } catch (_) {}
  }

  /// 用户是否已经把「后台连接」提示藏掉了（划掉或关闭渠道）。
  /// 藏掉之后连接照跑，只是通知栏不再显示任何东西。
  static bool noticeHidden = false;

  /// 是否显示那条常驻提示（默认 false：出厂就不打扰）。
  static bool showNotice = false;

  /// 刷新提示状态：是否选择显示、是否已被划掉/关渠道。
  static Future<void> refreshNoticeState() async {
    if (!Platform.isAndroid) return;
    try {
      showNotice =
          await _channel.invokeMethod<bool>('showKeepAliveNotice') ?? false;
      // noticeHidden 只表示「系统层面确实看不到」，与用户是否勾选显示无关。
      noticeHidden =
          await _channel.invokeMethod<bool>('keepAliveNoticeHidden') ?? false;
    } catch (_) {}
  }

  /// 设置是否显示常驻提示。关闭后连接与消息送达不受任何影响。
  static Future<void> setShowNotice(bool show) async {
    if (!Platform.isAndroid) return;
    showNotice = show;
    noticeHidden = !show;
    try {
      await _channel.invokeMethod('setShowKeepAliveNotice', {'show': show});
    } catch (_) {}
  }

  /// 是否需要给用户看一次「隐藏这条提示」的引导。
  ///
  /// Android 强制前台服务必须挂通知，App 无法自己撤销，只能请用户
  /// 关一次渠道；关掉之后就再也不会有任何常驻提示。
  static Future<bool> needNoticeHint() async {
    if (!Platform.isAndroid || !enabled) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('gd2_notice_hint_done') == true) return false;
      if (!await hasSession()) return false;
      await refreshNoticeState();
      // 已经在系统里隐藏掉、或用户主动要求显示，都不必再提示。
      if (noticeHidden || showNotice) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 记下引导已展示，避免反复打扰。
  static Future<void> markNoticeHintDone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('gd2_notice_hint_done', true);
    } catch (_) {}
  }

  /// 打开系统里的「后台连接」渠道设置（高级用户偶尔用得到）。
  static Future<bool> openChannelSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'openKeepAliveChannelSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }
}