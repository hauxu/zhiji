import 'package:intl/intl.dart';

final DateFormat _keyFmt = DateFormat('yyyy-MM-dd');

/// 本地日期键：YYYY-MM-DD，与存储一致。
String dateKey(DateTime d) => _keyFmt.format(d);

DateTime today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// 一周从周一开始。
DateTime weekStartOf(DateTime d) {
  final local = DateTime(d.year, d.month, d.day);
  return local.subtract(Duration(days: local.weekday - 1));
}

const weekdayLabels = <String>['一', '二', '三', '四', '五', '六', '日'];

const weekdayNamesCn = <String>[
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
  '星期日',
];

String weekdayCn(DateTime d) => weekdayNamesCn[d.weekday - 1];

String monthDay(DateTime d) => '${d.month}月${d.day}日';

String fullCnDate(DateTime d) =>
    '${d.year}年${d.month}月${d.day}日 ${DateFormat.E('zh_CN').format(d)}';

String timeSortKey(String time) => time.isEmpty ? '99:99' : time;

String timeAgoCn(int ms) {
  if (ms <= 0) return '尚未同步';
  final diff = DateTime.now().millisecondsSinceEpoch - ms;
  if (diff < 30 * 1000) return '刚刚';
  if (diff < 60 * 1000) return '${diff ~/ 1000} 秒前';
  if (diff < 3600 * 1000) return '${diff ~/ 60000} 分钟前';
  if (diff < 24 * 3600 * 1000) return '${diff ~/ 3600000} 小时前';
  return '${diff ~/ 86400000} 天前';
}

DateTime? parseDateKey(String? key) {
  if (key == null) return null;
  final p = key.split('-');
  if (p.length != 3) return null;
  final y = int.tryParse(p[0]);
  final m = int.tryParse(p[1]);
  final d = int.tryParse(p[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}
