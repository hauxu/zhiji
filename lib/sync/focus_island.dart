import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/services.dart';

/// 小米 HyperOS「超级岛/焦点通知」实验功能桥（原生 judging/island 通道）。
/// 全部为端上实现：无服务器、无推送 SDK。
class FocusIsland {
  FocusIsland._();

  static const _channel = MethodChannel('judging/island');

  /// 设备支持状态：isXiaomi/systemSupported/canShowFocus（null=探测不可用）。
  static Future<Map<String, dynamic>?> status() async {
    try {
      final r = await _channel.invokeMethod<dynamic>('islandStatus');
      if (r is Map) return Map<String, dynamic>.from(r);
    } catch (_) {}
    return null;
  }

  static Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('islandEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 开关状态与可用性同时写入 Dart prefs：后台 isolate（无插件通道）
  /// 的重排也要能判定岛模式，避免普通通知与岛闹钟双响。
  static Future<void> setEnabled(bool on,
      {bool? usable}) async {
    try {
      await _channel.invokeMethod('setIslandEnabled', {'enabled': on});
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('gd2_island_enabled', on);
      if (usable != null) {
        await prefs.setBool('gd2_island_usable', usable);
      }
    } catch (_) {}
  }

  /// 后台 isolate 可用的岛模式判定（只读 prefs 缓存）。
  static Future<bool> cachedUsable() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getBool('gd2_island_enabled') ?? false) &&
          (prefs.getBool('gd2_island_usable') ?? false);
    } catch (_) {
      return false;
    }
  }

  /// items: [{id, time(epochMs), timeout(epochMs), title, body, target(epochMs)}]
  static Future<void> scheduleIslands(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return;
    try {
      await _channel.invokeMethod(
          'scheduleIslands', {'items': jsonEncode(items)});
    } catch (_) {}
  }

  static Future<void> cancelIslands() async {
    try {
      await _channel.invokeMethod('cancelIslands');
    } catch (_) {}
  }

  static Future<bool> postIslandTest(
      {String title = '超级岛测试', String body = '这是一条灵动岛胶囊测试'}) async {
    try {
      return await _channel.invokeMethod<bool>('postIslandTest',
          {'title': title, 'body': body}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
