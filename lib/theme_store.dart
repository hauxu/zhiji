import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 中国传统色（种子色），M3 tonal 取色用。
class TraditionalColor {
  const TraditionalColor(this.name, this.value);

  final String name;
  final Color value;
}

const traditionalColors = <TraditionalColor>[
  TraditionalColor('苔绿', Color(0xFF3E6B4F)), // 默认
  TraditionalColor('竹青', Color(0xFF789262)),
  TraditionalColor('青碧', Color(0xFF3A8C7E)),
  TraditionalColor('黛蓝', Color(0xFF2B4A6F)),
  TraditionalColor('绛紫', Color(0xFF8C3A5B)),
  TraditionalColor('藕荷', Color(0xFFC99BA4)),
  TraditionalColor('朱砂', Color(0xFFC0392B)),
  TraditionalColor('藤黄', Color(0xFFC8A528)),
  TraditionalColor('绾', Color(0xFFA98175)),
  TraditionalColor('黛灰', Color(0xFF5B6770)),
  TraditionalColor('玄青', Color(0xFF3D3B4F)),
  TraditionalColor('胭脂', Color(0xFF9D2933)),
  TraditionalColor('月白', Color(0xFF6A8AB5)),
  TraditionalColor('天水碧', Color(0xFF4A8B8B)),
  TraditionalColor('琥珀', Color(0xFFB8814C)),
  TraditionalColor('黛绿', Color(0xFF2E5D4E)),
  TraditionalColor('樱草', Color(0xFFD48A9A)),
  TraditionalColor('紫棠', Color(0xFF6C4A8C)),
];

/// 主题状态：动态取色、传统色种子、深色模式。
class ThemeStore extends ChangeNotifier {
  static const _kSeed = 'gd2_seed_color';
  static const _kDynamic = 'gd2_use_dynamic';
  static const _kDark = 'gd2_dark_mode';

  Color seedColor = const Color(0xFF3E6B4F);
  bool useDynamic = false;
  bool darkMode = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final seed = prefs.getInt(_kSeed);
    if (seed != null) seedColor = Color(seed);
    useDynamic = prefs.getBool(_kDynamic) ?? false;
    darkMode = prefs.getBool(_kDark) ?? false;
  }

  Future<void> setSeed(Color c) async {
    seedColor = c;
    useDynamic = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeed, c.toARGB32());
    await prefs.setBool(_kDynamic, false);
    notifyListeners();
  }

  Future<void> setUseDynamic(bool v) async {
    useDynamic = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDynamic, v);
    notifyListeners();
  }

  Future<void> setDarkMode(bool v) async {
    darkMode = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDark, v);
    notifyListeners();
  }
}
