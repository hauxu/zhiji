import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// 原生分享通道：Android 直发 ACTION_SEND（不包 Chooser），
/// 由厂商分享框架（MagicOS 分享等）接管呈现。
class NativeShare {
  NativeShare._();

  static const _channel = MethodChannel('judging/share');

  /// 「任务进行中实况」方法在 Kotlin 侧注册在 judging/island 通道；
  /// 之前误发到 judging/share，会落到 notImplemented 并被吞掉。
  static const _islandChannel = MethodChannel('judging/island');

  /// 返回 true 表示已交给系统处理。
  static Future<bool> shareImage(String path) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'shareImage',
        {'path': path},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 定向分享到指定应用（包名）；未安装或失败返回 false。
  static Future<bool> shareImageTo(String path, String package) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'shareImage',
        {'path': path, 'package': package},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 已安装的精选分享目标包名（微信/QQ/微博）。
  static Future<List<String>> installedShareTargets() async {
    if (!Platform.isAndroid) return const [];
    try {
      final list = await _channel.invokeListMethod<String>('shareTargets');
      return list ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// 是否已在电池优化白名单（后台同步不被 ROM 冻结）。
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>(
              'isIgnoringBatteryOptimizations') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// 拉起系统「忽略电池优化」授权对话框。
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// 是否已授予全屏弹窗（悬浮通知/全屏意图）权限（Android 14+ 可拒）。
  static Future<bool> canUseFullScreenIntent() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('canUseFullScreenIntent') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// 跳系统「闹钟和提醒」（精确闹钟）授权页。
  static Future<void> openExactAlarmSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openExactAlarmSettings');
    } catch (_) {}
  }

  /// 跳本应用的通知设置页（悬浮通知/横幅权限所在）。
  static Future<void> openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openNotificationSettings');
    } catch (_) {}
  }

  /// 跳指定通知渠道的设置页（荣耀/小米等横幅开关所在，一步直达）。
  static Future<void> openChannelSettings(String channelId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod('openChannelSettings', {'channelId': channelId});
    } catch (_) {}
  }

  /// 设备厂商（小写），用于按 ROM 给出横幅开关的准确名称。
  static Future<String> manufacturer() async {
    if (!Platform.isAndroid) return '';
    try {
      return await _channel.invokeMethod<String>('manufacturer') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 尝试打开「pkg/class」组件（厂商自启动/后台设置页深链）。
  static Future<bool> openComponent(String flat) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'openComponent', {'component': flat}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 排一批「任务进行中实况」边界（items：[{id,title,startAt,endAt}]）。
  static Future<void> scheduleTaskLive(List<Map<String, dynamic>> items) async {
    if (!Platform.isAndroid) return;
    try {
      await _islandChannel.invokeMethod(
          'scheduleTaskLive', {'items': jsonEncode(items)});
    } catch (e) {
      debugPrint('scheduleTaskLive failed: $e');
    }
  }

  /// 取消全部任务实况排程。
  static Future<void> cancelTaskLive() async {
    if (!Platform.isAndroid) return;
    try {
      await _islandChannel.invokeMethod('cancelTaskLive');
    } catch (e) {
      debugPrint('cancelTaskLive failed: $e');
    }
  }
}
