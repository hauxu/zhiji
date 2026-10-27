import 'dart:ui';

/// 清单与习惯的 6 色板。
const listColors = <String>[
  '3E6B4F', // 苔绿
  'C9A227', // 金黄
  '4F6E78', // 青灰蓝
  '8A5A2E', // 赭石
  '7A5C40', // 棕褐
  'B0623C', // 陶土橙
];

/// 倒数本中国传统色 12 色（常见好看、冷暖均衡）。
const milestoneColors = <String>[
  '9D2933', // 胭脂
  'F47983', // 桃红
  'E4C6D0', // 藕荷
  '6C4A8C', // 紫棠
  '2B4A6F', // 黛蓝
  '1685A9', // 石青
  '4A8B8B', // 天水碧
  '789262', // 竹青
  '3E6B4F', // 苔绿
  'D9B611', // 秋香
  'FFA631', // 杏黄
  'B8814C', // 琥珀
];

/// 色板对应中文名。
const milestoneColorNames = <String>[
  '胭脂', '桃红', '藕荷', '紫棠', '黛蓝', '石青',
  '天水碧', '竹青', '苔绿', '秋香', '杏黄', '琥珀',
];

/// 习惯专用中国传统色 12 色。
const habitColors = <String>[
  '3E6B4F', // 苔绿（苔藓）
  '789262', // 竹青（竹）
  '549688', // 铜绿（铜器锈色）
  '1685A9', // 石青（蓝铜矿）
  '425066', // 黛蓝（远山）
  'A8D3DC', // 月白（月下浅蓝）
  'D9B611', // 秋香（秋日黄绿）
  'FFA631', // 杏黄（杏果）
  'F47983', // 桃红（桃花）
  'E4C6D0', // 藕荷（荷花藕）
  '9D2933', // 胭脂（胭脂红）
  '955539', // 赭石（赭石矿）
];

Color colorFromHex(String hex) {
  final h = hex.replaceAll('#', '').trim();
  if (h.length != 6 && h.length != 8) {
    return const Color(0xFFB9B4A4); // 数据异常时的中性回退色
  }
  final v = int.tryParse(h, radix: 16);
  if (v == null) return const Color(0xFFB9B4A4);
  return Color(h.length == 6 ? 0xFF000000 | v : v);
}
