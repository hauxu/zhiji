import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 轻量界面偏好；不参与云同步。
class UiPrefs extends ChangeNotifier {
  // 倒数本设置（gd2_book_*）
  static const _kBookLunar = 'gd2_book_lunar';
  static const _kBookPastDays = 'gd2_book_past_days';
  static const _kBookHidePartner = 'gd2_book_hide_partner';
  static const _kBookCollapsed = 'gd2_book_collapsed_count';

  /// 倒数本行显示农历标注。
  bool bookLunar = true;

  /// 已过去的条目显示「已过 N 天」。
  bool bookPastDays = true;

  /// 隐藏 TA 添加的条目。
  bool bookHidePartner = false;

  /// 日子页倒数本卡收起时显示的外显条数（置顶优先）。
  int bookCollapsedCount = 10;

  // 情侣「纪念日」独立设置（gd2_cbook_*）：与日子页倒数本各控制各的。
  static const _kCBookLunar = 'gd2_cbook_lunar';
  static const _kCBookPastDays = 'gd2_cbook_past_days';
  static const _kCBookHidePartner = 'gd2_cbook_hide_partner';
  static const _kCBookCollapsed = 'gd2_cbook_collapsed_count';

  /// 情侣纪念日行显示农历标注。
  bool cbookLunar = true;

  /// 情侣纪念日已过去的条目显示「已过 N 天」。
  bool cbookPastDays = true;

  /// 情侣纪念日隐藏 TA 添加的条目。
  bool cbookHidePartner = false;

  /// 情侣页纪念日卡外显条数（置顶优先）。
  int cbookCollapsedCount = 10;

  // 全局自定义背景（gd2_bg_*）：不参与云同步。
  static const _kBgPath = 'gd2_bg_path';
  static const _kBgOpacity = 'gd2_bg_opacity';
  static const _kBgEnabled = 'gd2_bg_enabled';

  /// 背景图路径（应用私有目录内的拷贝）；空=未设置。
  String bgPath = '';

  /// 背景图不透明度（0.1–1.0），越小越透。
  double bgOpacity = 0.35;

  /// 是否启用自定义背景。
  bool bgEnabled = false;

  // Windows 毛玻璃浓度（gd2_glass_strength）：0 清晰 / 1 标准 / 2 通透。
  static const _kGlassStrength = 'gd2_glass_strength';

  /// 雾面浓度档位，越大越不透明、字越好读。
  int glassStrength = 1;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      bookLunar = prefs.getBool(_kBookLunar) ?? true;
      bookPastDays = prefs.getBool(_kBookPastDays) ?? true;
      bookHidePartner = prefs.getBool(_kBookHidePartner) ?? false;
      bookCollapsedCount = prefs.getInt(_kBookCollapsed) ?? 10;
      cbookLunar = prefs.getBool(_kCBookLunar) ?? true;
      cbookPastDays = prefs.getBool(_kCBookPastDays) ?? true;
      cbookHidePartner = prefs.getBool(_kCBookHidePartner) ?? false;
      cbookCollapsedCount = prefs.getInt(_kCBookCollapsed) ?? 10;
      bgPath = prefs.getString(_kBgPath) ?? '';
      bgOpacity = prefs.getDouble(_kBgOpacity) ?? 0.35;
      glassStrength = (prefs.getInt(_kGlassStrength) ?? 1).clamp(0, 2);
      bgEnabled = prefs.getBool(_kBgEnabled) ?? false;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setBookLunar(bool v) =>
      _setBool(_kBookLunar, v, () => bookLunar = v);

  Future<void> setBookPastDays(bool v) =>
      _setBool(_kBookPastDays, v, () => bookPastDays = v);

  Future<void> setBookHidePartner(bool v) =>
      _setBool(_kBookHidePartner, v, () => bookHidePartner = v);

  Future<void> setBookCollapsedCount(int v) async {
    if (bookCollapsedCount == v) return;
    bookCollapsedCount = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBookCollapsed, v);
    } catch (_) {}
  }

  Future<void> setCBookLunar(bool v) =>
      _setBool(_kCBookLunar, v, () => cbookLunar = v);

  Future<void> setCBookPastDays(bool v) =>
      _setBool(_kCBookPastDays, v, () => cbookPastDays = v);

  Future<void> setCBookHidePartner(bool v) =>
      _setBool(_kCBookHidePartner, v, () => cbookHidePartner = v);

  Future<void> setCBookCollapsedCount(int v) async {
    if (cbookCollapsedCount == v) return;
    cbookCollapsedCount = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCBookCollapsed, v);
    } catch (_) {}
  }

  Future<void> setBgPath(String v) async {
    if (bgPath == v) return;
    bgPath = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kBgPath, v);
    } catch (_) {}
  }

  /// 切换毛玻璃浓度（0 清晰 / 1 标准 / 2 通透）。
  Future<void> setGlassStrength(int v) async {
    final level = v.clamp(0, 2);
    if (level == glassStrength) return;
    glassStrength = level;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kGlassStrength, level);
    } catch (_) {}
  }

  Future<void> setBgOpacity(double v) async {
    if (bgOpacity == v) return;
    bgOpacity = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBgOpacity, v);
    } catch (_) {}
  }

  Future<void> setBgEnabled(bool v) =>
      _setBool(_kBgEnabled, v, () => bgEnabled = v);

  Future<void> _setBool(
      String key, bool v, void Function() assign) async {
    assign();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, v);
    } catch (_) {}
  }
}
