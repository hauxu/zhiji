import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// MCP 接入开关与权限，全部存在本机 prefs，不参与同步。
class McpSettings {
  McpSettings._();

  static const _kEnabled = 'gd2_mcp_enabled';
  static const _kPort = 'gd2_mcp_port';
  static const _kToken = 'gd2_mcp_token';
  static const _kWrite = 'gd2_mcp_allow_write';
  static const _kPrivate = 'gd2_mcp_allow_private';

  static const int defaultPort = 8787;

  static Future<bool> enabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kEnabled) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
  }

  static Future<int> port() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getInt(_kPort) ?? defaultPort;
    return (v >= 1024 && v <= 65535) ? v : defaultPort;
  }

  static Future<void> setPort(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kPort, v.clamp(1024, 65535));
  }

  static Future<bool> allowWrite() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kWrite) ?? false;
  }

  static Future<void> setAllowWrite(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kWrite, v);
  }

  static Future<bool> allowPrivate() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kPrivate) ?? false;
  }

  static Future<void> setAllowPrivate(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPrivate, v);
  }

  /// 取 token；没有就生成一个并落盘。
  static Future<String> token() async {
    final p = await SharedPreferences.getInstance();
    final existing = p.getString(_kToken) ?? '';
    if (existing.isNotEmpty) return existing;
    final fresh = _genToken();
    await p.setString(_kToken, fresh);
    return fresh;
  }

  /// 重置 token：旧 token 立刻失效。
  static Future<String> resetToken() async {
    final p = await SharedPreferences.getInstance();
    final fresh = _genToken();
    await p.setString(_kToken, fresh);
    return fresh;
  }

  static String _genToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(24, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
