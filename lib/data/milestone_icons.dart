import 'package:flutter/material.dart';

/// 倒数本可选图标（简笔画风格，全 outlined）。
const milestoneIcons = <String, IconData>{
  'favorite': Icons.favorite_outline,
  'cake': Icons.cake_outlined,
  'flight': Icons.flight_takeoff_outlined,
  'school': Icons.school_outlined,
  'star': Icons.star_outline,
  'flag': Icons.flag_outlined,
  'diamond': Icons.diamond_outlined,
  'home': Icons.home_outlined,
  'wedding': Icons.church_outlined,
  'travel': Icons.luggage_outlined,
  'work': Icons.business_center_outlined,
  'fitness': Icons.directions_run_outlined,
  'medical': Icons.health_and_safety_outlined,
  'shopping': Icons.shopping_bag_outlined,
  'gift': Icons.card_giftcard_outlined,
  'party': Icons.celebration_outlined,
  'baby': Icons.child_care_outlined,
  'car': Icons.directions_car_outlined,
  'pet': Icons.pets_outlined,
  'coffee': Icons.local_cafe_outlined,
};

/// 图标对应中文名。
const milestoneIconNames = <String, String>{
  'favorite': '恋爱',
  'cake': '生日',
  'flight': '旅行',
  'school': '学业',
  'star': '闪耀',
  'flag': '目标',
  'diamond': '纪念',
  'home': '家',
  'wedding': '婚礼',
  'travel': '度假',
  'work': '工作',
  'fitness': '健身',
  'medical': '医疗',
  'shopping': '购物',
  'gift': '礼物',
  'party': '庆祝',
  'baby': '宝宝',
  'car': '出行',
  'pet': '宠物',
  'coffee': '咖啡',
};

IconData milestoneIcon(String key) =>
    milestoneIcons[key] ?? milestoneIcons['favorite']!;
