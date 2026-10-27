import 'dart:convert';

import 'package:lunar/lunar.dart';

import '../util/dates.dart';

/// 未分类清单的固定 id 与显示名。
/// `AppStore.unfiledListId/unfiledListName` 引用这两个常量，保证数据层
/// （回收站旧字段迁移）与业务层使用同一个值。
const String kUnfiledListId = 'unfiled';
const String kUnfiledListName = '未分类';

/// 数据模型：清单独立；任务无日期＝本周内完成，无时间＝当天内完成，重复支持每日/每周。
enum Mood {
  good,
  calm,
  tired,
  low,
  anxious,
  excited,
  grateful,
  plain,
  energetic,
  focused,
  moved,
  gloomy,
}

Mood? moodFromString(String? s) => switch (s) {
  'good' => Mood.good,
  'calm' => Mood.calm,
  'tired' => Mood.tired,
  'low' => Mood.low,
  'anxious' => Mood.anxious,
  'excited' => Mood.excited,
  'grateful' => Mood.grateful,
  'plain' => Mood.plain,
  'energetic' => Mood.energetic,
  'focused' => Mood.focused,
  'moved' => Mood.moved,
  'gloomy' => Mood.gloomy,
  _ => null,
};

String? moodToString(Mood? m) => m?.name;

enum HabitStatus { done, miss }

HabitStatus? habitStatusFromString(String? s) => switch (s) {
  'done' => HabitStatus.done,
  'miss' => HabitStatus.miss,
  _ => null,
};

String? habitStatusToString(HabitStatus? s) => s?.name;

/// JSON 字段防御性读取：本地快照与伴侣同步都可能带错误类型的字段，
/// 逐字段兜底，避免单条脏数据炸掉整个 AppData。
String jStr(Map<String, dynamic> j, String key, [String fallback = '']) =>
    j[key] is String ? j[key] as String : fallback;

int jInt(Map<String, dynamic> j, String key, [int fallback = 0]) {
  final v = j[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

bool jBool(Map<String, dynamic> j, String key, [bool fallback = false]) {
  final v = j[key];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return fallback;
}

/// YYYY-MM-DD 格式校验（月日范围粗检），拒绝空串/畸形键。
bool _isDateKey(String s) {
  if (s.length != 10 || s[4] != '-' || s[7] != '-') return false;
  final y = int.tryParse(s.substring(0, 4));
  final m = int.tryParse(s.substring(5, 7));
  final d = int.tryParse(s.substring(8, 10));
  return y != null && m != null && d != null && m >= 1 && m <= 12 && d >= 1 && d <= 31;
}

/// 长久清单条目。
class ListItem {
  ListItem({
    required this.id,
      this.updatedAt = 0,
    required this.title,
    this.done = false,
    this.sort = 0,
    this.note = '',
    List<String>? attached,
    this.date = '',
  }) : attached = attached ?? <String>[];

  String id;

  /// 最后修改时间（ms），多端合并用；0=旧数据未知。
  int updatedAt;
  String title;
  bool done;

  /// 手动排序值，0=未排序。
  int sort;

  String note;

  List<String> attached;

  /// 目标日期 YYYY-MM-DD，空=未设置；有日期的条目在同分类内按日期自动排前。
  String date;

  factory ListItem.fromJson(Map<String, dynamic> j) => ListItem(
    updatedAt: jInt(j, 'u'),
        id: jStr(j, 'id'),
    title: jStr(j, 'title'),
    done: jBool(j, 'done'),
    sort: jInt(j, 'sort'),
    note: jStr(j, 'note'),
    attached: ((j['attached'] as List?) ?? const [])
        .whereType<String>()
        .toList(),
    date: jStr(j, 'date'),
  );

  Map<String, dynamic> toJson() => {
    'u': updatedAt,
    'id': id,
    'title': title,
    'done': done,
    'sort': sort,
    'note': note,
    'attached': attached,
    'date': date,
  };
}

/// 清单对伴侣的同步状态：隐藏 / 只读共享 / 共同编辑。
enum ListShareMode { off, readOnly, coEdit }

class TaskList {
  TaskList({
    required this.id,
    required this.name,
    required this.color,
    List<ListItem>? items,
    this.shared = false,
    this.coEdit = false,
    this.updatedAt = 0,
  }) : items = items ?? [];

  final String id;

  /// 清单头最后修改时间（ms），多端合并用。
  int updatedAt;
  String name;
  String color;
  List<ListItem> items;

  /// 是否共享给伴侣；伴侣侧按此过滤展示。
  bool shared;

  /// 共同编辑：TA 可勾选、添加条目，修改经快照回流。
  bool coEdit;

  ListShareMode get shareMode =>
      shared ? (coEdit ? ListShareMode.coEdit : ListShareMode.readOnly)
          : ListShareMode.off;

  int get doneCount => items.where((e) => e.done).length;
  int get undoneCount => items.length - doneCount;

  factory TaskList.fromJson(Map<String, dynamic> j) => TaskList(
    id: jStr(j, 'id'),
    name: jStr(j, 'name'),
    color: jStr(j, 'color', '3E6B4F'),
    items: ((j['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ListItem.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    shared: jBool(j, 'shared'),
    coEdit: jBool(j, 'coEdit'),
    updatedAt: jInt(j, 'u'),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'u': updatedAt,
    'name': name,
    'color': color,
    'items': items.map((e) => e.toJson()).toList(),
    'shared': shared,
    'coEdit': coEdit,
  };
}

/// 清单回收站条目：保留原清单 id 与删除时间，恢复时可回到原清单。
class TrashEntry {
  TrashEntry({
    required this.listId,
    required this.item,
    this.deletedAt = 0,
  });

  /// 删除时所在清单的 id；清单已不存在时恢复回未分类。
  String listId;
  ListItem item;

  /// 删除时间（ms）；0=旧快照只有 unfiledTrash，没有删除时间。
  int deletedAt;

  factory TrashEntry.fromJson(Map<String, dynamic> j) {
    final rawListId = jStr(j, 'listId');
    final rawItem = j['item'];
    return TrashEntry(
      listId: rawListId.isEmpty ? kUnfiledListId : rawListId,
      item: ListItem.fromJson(
        rawItem is Map ? Map<String, dynamic>.from(rawItem) : const {},
      ),
      deletedAt: jInt(j, 'at'),
    );
  }

  Map<String, dynamic> toJson() =>
      {'listId': listId, 'item': item.toJson(), 'at': deletedAt};
}

/// 计划任务：无日期＝本周内完成；重复每日/每周；起止时间可独立设置。
enum TaskRepeatMode { none, daily, weekly }

TaskRepeatMode repeatModeFromString(String? s) => switch (s) {
  'daily' => TaskRepeatMode.daily,
  'weekly' => TaskRepeatMode.weekly,
  _ => TaskRepeatMode.none,
};

String repeatModeToString(TaskRepeatMode m) => m.name;

String remindBeforeHuman(int minutes) {
  if (minutes <= 0) return '不提醒';
  if (minutes % 1440 == 0) return '提前 ${minutes ~/ 1440}天';
  if (minutes % 60 == 0) return '提前 ${minutes ~/ 60}小时';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '提前 $m分钟';
  return '提前 $h小时$m分钟';
}

class PlanTask {
  PlanTask({
    required this.id,
    required this.title,
    this.updatedAt = 0,
    this.date = '',
    this.repeatMode = TaskRepeatMode.none,
    List<int>? repeatWeekdays,
    this.start = '',
    this.end = '',
    this.done = false,
    List<String>? doneDates,
    this.note = '',
    this.starred = false,
    this.archived = false,
    this.remindBefore = 0,
    this.sort = 0,
  }) : repeatWeekdays = repeatWeekdays ?? const [],
       doneDates = doneDates ?? <String>[];

  final String id;

  /// 最后修改时间（ms），多端合并用；0=旧数据未知。
  int updatedAt;
  String title;

  /// YYYY-MM-DD；空串＝本周内完成即可。重复任务作为起始锚点。
  String date;

  TaskRepeatMode repeatMode;

  /// 每周重复时的星期，1=周一、7=周日
  List<int> repeatWeekdays;

  /// 开始时间 HH:mm，空＝未设置。
  String start;

  /// 结束时间 HH:mm，空＝未设置。
  String end;

  /// 非重复任务的完成状态。
  bool done;

  String note;

  bool starred;

  bool archived;

  /// 重复任务按日期记录完成。
  List<String> doneDates;

  /// 结束前提醒提前量，0=不提醒。
  int remindBefore;

  /// 手动排序值，0=未排序。
  int sort;

  String get remindLabel => remindBeforeHuman(remindBefore);

  bool get hasDate => date.isNotEmpty;

  bool get isRecurring => repeatMode != TaskRepeatMode.none;

  bool get hasAnyTime => start.isNotEmpty || end.isNotEmpty;

  String get timeLabel {
    if (start.isNotEmpty && end.isNotEmpty) return '$start-$end';
    if (start.isNotEmpty) return start;
    if (end.isNotEmpty) return '$end 前';
    return '';
  }

  bool occursOn(DateTime d) {
    if (isRecurring) {
      final key = dateKey(d);
      if (hasDate && key.compareTo(date) < 0) return false;
      switch (repeatMode) {
        case TaskRepeatMode.daily:
          return true;
        case TaskRepeatMode.weekly:
          return repeatWeekdays.contains(d.weekday);
        case TaskRepeatMode.none:
          return false;
      }
    }
    return hasDate && date == dateKey(d);
  }

  bool isDoneOn(DateTime d) =>
      isRecurring ? doneDates.contains(dateKey(d)) : done;

  void setDoneOn(DateTime d, bool value) {
    if (!isRecurring) {
      done = value;
      return;
    }
    final key = dateKey(d);
    doneDates.remove(key);
    if (value) doneDates.add(key);
  }

  factory PlanTask.fromJson(Map<String, dynamic> j) {
    final wasWeek = j['kind'] == 'week';
    final weekdays = ((j['repeatWeekdays'] as List?) ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList();
    var mode = wasWeek
        ? TaskRepeatMode.none
        : weekdays.isNotEmpty
        ? TaskRepeatMode.weekly
        : repeatModeFromString(
            j['repeatMode'] is String ? j['repeatMode'] as String : null,
          );
    // 无星期的周重复按不重复处理。
    if (mode == TaskRepeatMode.weekly && weekdays.isEmpty) {
      mode = TaskRepeatMode.none;
    }
    return PlanTask(
      id: jStr(j, 'id'),
      title: jStr(j, 'title'),
      updatedAt: jInt(j, 'u'),
      date: wasWeek ? '' : jStr(j, 'date'),
      repeatMode: mode,
      repeatWeekdays: weekdays,
      start: jStr(j, 'start'),
      end: jStr(j, 'end'),
      done: jBool(j, 'done'),
      doneDates: ((j['doneDates'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      note: jStr(j, 'note'),
      starred: jBool(j, 'starred'),
      archived: jBool(j, 'archived'),
      remindBefore: jInt(j, 'remindBefore'),
      sort: jInt(j, 'sort'),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'u': updatedAt,
    'date': date,
    'repeatMode': repeatModeToString(repeatMode),
    'repeatWeekdays': repeatWeekdays,
    'start': start,
    'end': end,
    'done': done,
    'doneDates': doneDates,
    'note': note,
    'starred': starred,
    'archived': archived,
    'remindBefore': remindBefore,
    'sort': sort,
  };
}

class Habit {
  Habit({
    required this.id,
      this.updatedAt = 0,
    required this.name,
    required this.color,
    required this.records,
    this.sort = 0,
    this.time = '',
    this.reminder = false,
  });

  /// 最后修改时间（ms），多端合并用；0=旧数据未知。
  int updatedAt;

  final String id;
  String name;
  String color;

  /// 日期键到打卡状态
  final Map<String, HabitStatus> records;

  /// 手动排序值，0=未排序。
  int sort;

  /// 固定时间 HH:mm，空=未设置；有时间的习惯按时间自动排前。
  String time;

  /// 每日打卡提醒：按 time 提醒（未设时间默认 20:00）。
  bool reminder;

  /// 提醒时间：time 优先，未设置回退 20:00。
  String get reminderTime => time.isNotEmpty ? time : '20:00';

  factory Habit.fromJson(Map<String, dynamic> j) {
    final raw = (j['records'] ?? const {}) as Map;
    return Habit(
      updatedAt: jInt(j, 'u'),
        id: jStr(j, 'id'),
      name: jStr(j, 'name'),
      color: jStr(j, 'color', '3E6B4F'),
      records: {
        // 日期键过滤畸形值（如空串），防止详情页解析崩溃。
        for (final e in raw.entries)
          if (e.key is String &&
              _isDateKey(e.key as String) &&
              e.value is String &&
              habitStatusFromString(e.value as String?) != null)
            e.key as String: habitStatusFromString(e.value as String?)!,
      },
      sort: jInt(j, 'sort'),
      time: jStr(j, 'time'),
      reminder: jBool(j, 'remind'),
    );
  }

  Map<String, dynamic> toJson() => {
    'u': updatedAt,
    'id': id,
    'name': name,
    'color': color,
    'sort': sort,
    'time': time,
    'remind': reminder,
    'records': {
      for (final e in records.entries) e.key: habitStatusToString(e.value),
    },
  };
}

class JournalEntry {
  JournalEntry({
      this.updatedAt = 0,
    required this.date,
    this.id = '',
    this.title = '',
    this.text = '',
    this.mood,
    this.weather = '',
    this.shared = false,
    List<String>? images,
  }) : images = images ?? <String>[];

  final String date;

  /// 条目唯一 id：单日多篇用；空串=旧数据（以存储键 date 兜底）。
  String id;

  /// 最后修改时间（ms），多端合并用；0=旧数据未知。
  int updatedAt;
  String title;
  String text;
  Mood? mood;
  String weather;

  /// 是否共享给对方，共享条目以明文单独下发。
  bool shared;

  /// 日记图片本机路径，不参与同步。
  List<String> images;

  bool get isEmpty =>
      title.trim().isEmpty &&
      text.trim().isEmpty &&
      mood == null &&
      images.isEmpty;

  factory JournalEntry.fromJson(Map<String, dynamic> j) => JournalEntry(
    updatedAt: jInt(j, 'u'),
        date: jStr(j, 'date'),
    id: jStr(j, 'id'),
    title: jStr(j, 'title'),
    text: jStr(j, 'text'),
    mood: moodFromString(j['mood'] is String ? j['mood'] as String : null),
    weather: jStr(j, 'weather'),
    shared: jBool(j, 'shared'),
    images: ((j['images'] as List?) ?? const []).whereType<String>().toList(),
  );

  Map<String, dynamic> toJson() => {
    'u': updatedAt,
    'date': date,
    if (id.isNotEmpty) 'id': id,
    'title': title,
    'text': text,
    'mood': moodToString(mood),
    'weather': weather,
    'shared': shared,
    'images': images,
  };
}

/// 日记存储键校验：主条目键=日期，追加篇章键=日期#短 id。
bool _isJournalKey(String s) {
  final i = s.indexOf('#');
  return _isDateKey(i < 0 ? s : s.substring(0, i));
}

/// 由条目反推其存储键（追加篇章带 # 后缀）。
String journalKeyOf(JournalEntry e) =>
    e.id.isEmpty ? e.date : '${e.date}#${e.id}';

/// 回收站里的一篇已删日记：保留原存储键与完整内容，支持找回。
class JournalTrashItem {
  JournalTrashItem({
    required this.storageKey,
    required this.entry,
    required this.deletedAt,
  });

  /// 原存储键（日期或 日期#篇章id），恢复时回到原位。
  String storageKey;
  JournalEntry entry;
  int deletedAt;

  factory JournalTrashItem.fromJson(Map<String, dynamic> j) =>
      JournalTrashItem(
        storageKey: jStr(j, 'key'),
        entry: JournalEntry.fromJson(
          Map<String, dynamic>.from(j['entry'] as Map),
        ),
        deletedAt: jInt(j, 'at'),
      );

  Map<String, dynamic> toJson() =>
      {'key': storageKey, 'entry': entry.toJson(), 'at': deletedAt};
}

/// 倒数本条目：纪念日、生日或任意倒数日。
class Milestone {
  Milestone({
    required this.id,
      this.updatedAt = 0,
    required this.title,
    required this.date,
    bool yearly = false,
    String? repeat,
    this.pinned = false,
    this.color = 'B0623C',
    this.icon = 'favorite',
    List<int>? reminds,
    this.lunar = false,
    this.lunarMonth = 0,
    this.lunarDay = 0,
    this.lunarLeap = false,
    this.featured = true,
    this.plusOne = false,
    this.highlight = false,
  }) : reminds = List<int>.of(reminds ?? const [0]),
       repeat = repeat ?? (yearly ? 'year' : 'none');

  final String id;

  /// 最后修改时间（ms），多端合并用；0=旧数据未知。
  int updatedAt;
  String title;

  /// YYYY-MM-DD；每年重复时作为周年锚点，农历条目存换算后的公历日。
  String date;

  /// 兼容字段：等同 repeat == 'year'，getter/setter 双向同步。
  bool get yearly => repeat == 'year';
  set yearly(bool v) => repeat = v ? 'year' : 'none';

  bool pinned;
  String color;

  /// 循环：none/week/month/year（year 与 yearly 保持一致）。
  String repeat = 'none';

  /// milestoneIcons 的键。
  String icon;

  /// 提醒偏移集合（0=当天，n=提前 n 天），空=不提醒。
  List<int> reminds;

  /// 按农历记日，配合每年重复。
  bool lunar;

  /// 农历月 1..12，闰标记单独存。
  int lunarMonth;

  /// 农历日 1..30。
  int lunarDay;

  /// 是否闰月（当年无此闰月时按平月算）。
  bool lunarLeap;

  /// 是否在日子页外显（收起列表/日期旁胶囊/月历色点）；关闭的只在「查看全部」出现。
  bool featured;

  /// 正数包含起始日（+1 天）：过去的条目「已过 N 天」多算一天。
  bool plusOne;

  /// 高亮突出：行背景用条目色着色并加重边框。
  bool highlight;

  /// 统一用 UTC 午夜做日期运算，避开时区夏令时的 ±1 小时。
  DateTime get targetDate {
    final p = date.split('-');
    if (p.length != 3) return DateTime.utc(1970);
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return DateTime.utc(1970);
    return DateTime.utc(y, m, d);
  }

  /// 距 [from]（含当天）最近的下次发生日；不重复且已过时即原日期。
  DateTime nextOccurrence(DateTime from) {
    final f = DateTime.utc(from.year, from.month, from.day);
    final d = targetDate;
    if (repeat == 'none') return d;
    if (repeat == 'week') {
      // 下一个同星期几（当天即发生日）。
      final delta = (d.weekday - f.weekday + 7) % 7;
      return f.add(Duration(days: delta));
    }
    if (repeat == 'month') {
      for (var i = 0; i <= 36; i++) {
        final y = f.year + (f.month - 1 + i) ~/ 12;
        final m = (f.month - 1 + i) % 12 + 1;
        final last = DateTime.utc(y, m + 1, 0).day;
        final day = d.day > last ? last : d.day;
        final cand = DateTime.utc(y, m, day);
        if (!cand.isBefore(f)) return cand;
      }
      return d;
    }
    if (lunar && lunarMonth >= 1 && lunarDay >= 1) {
      for (var y = f.year - 1; y <= f.year + 2; y++) {
        final g = lunarToSolar(y, lunarMonth, lunarDay, lunarLeap);
        if (!g.isBefore(f)) return g;
      }
      return d;
    }
    var next = DateTime.utc(f.year, d.month, d.day);
    if (next.isBefore(f)) next = DateTime.utc(f.year + 1, d.month, d.day);
    return next;
  }

  /// [from] 距下次发生的天数：0=就是今天，负数=已过。
  int daysUntil(DateTime from) =>
      nextOccurrence(from)
          .difference(DateTime.utc(from.year, from.month, from.day))
          .inDays;

  bool isPast(DateTime from) => !yearly && daysUntil(from) < 0;

  /// [day] 是否为发生日，月历标记用。
  bool occursOnDate(DateTime day) {
    final d = targetDate;
    final k = DateTime.utc(day.year, day.month, day.day);
    if (k.isBefore(d)) return false;
    if (repeat == 'week') {
      return k.weekday == d.weekday;
    }
    if (repeat == 'month') {
      if (k.isBefore(d)) return false;
      final last = DateTime.utc(k.year, k.month + 1, 0).day;
      final anchorDay = d.day > last ? last : d.day;
      return k.day == anchorDay;
    }
    if (repeat != 'year') {
      return k.year == d.year && k.month == d.month && k.day == d.day;
    }
    if (lunar && lunarMonth >= 1 && lunarDay >= 1) {
      final lu = Lunar.fromDate(day);
      final raw = lu.getMonth();
      final isLeap = raw < 0;
      if ((isLeap ? -raw : raw) != lunarMonth || lu.getDay() != lunarDay) {
        return false;
      }
      if (isLeap) return lunarLeap;
      if (!lunarLeap) return true;
      // 锚定闰月但当年无闰月：回退的平月也算。
      return LunarYear.fromYear(lu.getYear()).getLeapMonth() != lunarMonth;
    }
    return k.month == d.month && k.day == d.day;
  }

  String daysLabel(DateTime from) {
    final n = daysUntil(from);
    if (n == 0) {
      if (!yearly) return '今天';
      final years = nextOccurrence(from).year - targetDate.year;
      return years > 0 ? '$years 周年' : '今天';
    }
    if (n > 0) {
      final years = yearly ? nextOccurrence(from).year - targetDate.year : 0;
      return years > 0 ? '$years 周年 · 还有 $n 天' : '还有 $n 天';
    }
    return '已过 ${-n + (plusOne ? 1 : 0)} 天';
  }

  /// 天数拆解（概览卡大数字排版用）：主数字 + 单位小字。
  /// 无数字的「今天」整体落在 numeral，unit 为空串。
  (String, String) daysParts(DateTime from) {
    final n = daysUntil(from);
    if (n == 0) {
      if (!yearly) return ('今天', '');
      final years = nextOccurrence(from).year - targetDate.year;
      return years > 0 ? ('$years', '周年') : ('今天', '');
    }
    if (n > 0) return ('$n', '天后');
    return ('${-n + (plusOne ? 1 : 0)}', '天前');
  }

  /// 循环方式显示名（每周/每月/每年）；不重复返回空串。
  String get repeatLabel => switch (repeat) {
    'week' => '每周',
    'month' => '每月',
    'year' => '每年',
    _ => '',
  };

  /// 循环感知的发生日描述：
  /// week=每周四；month=每月31号；year=农历八月十五 / 每年6月1日；none=完整日期。
  String get occurrenceLabel {
    final d = targetDate;
    switch (repeat) {
      case 'week':
        return '每周${weekdayCn(d)}';
      case 'month':
        return '每月${d.day}号';
      case 'year':
        if (lunar && lunarLabel().isNotEmpty) return '农历${lunarLabel()}';
        return '每年${d.month}月${d.day}日';
      default:
        return '${d.year}年${d.month}月${d.day}日';
    }
  }

  /// 农历显示名（如 闰六月十二）；非农历条目返回空串。
  String lunarLabel() =>
      lunar ? lunarLabelOf(lunarMonth, lunarDay, lunarLeap) : '';

  String get remindLabel {
    if (reminds.isEmpty) return '不提醒';
    final sorted = [...reminds]..sort();
    return sorted.map((v) => v == 0 ? '当天' : '提前 $v 天').join('、');
  }

  /// 置顶优先；其后 upcoming 按日期升序，已过去的按最近在前。
  static int compare(Milestone a, Milestone b, DateTime from) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final ap = a.isPast(from);
    final bp = b.isPast(from);
    if (ap != bp) return ap ? 1 : -1;
    final an = a.nextOccurrence(from);
    final bn = b.nextOccurrence(from);
    return ap ? bn.compareTo(an) : an.compareTo(bn);
  }

  factory Milestone.fromJson(Map<String, dynamic> j) => Milestone(
    updatedAt: jInt(j, 'u'),
        id: jStr(j, 'id'),
    title: jStr(j, 'title'),
    date: jStr(j, 'date'),
    yearly: jBool(j, 'yearly'),
    pinned: jBool(j, 'pinned'),
    color: jStr(j, 'color', 'B0623C'),
    icon: jStr(j, 'icon', 'favorite'),
    reminds: _remindsFromJson(j),
    lunar: jBool(j, 'lunar'),
    lunarMonth: jInt(j, 'lunarMonth'),
    lunarDay: jInt(j, 'lunarDay'),
    lunarLeap: jBool(j, 'lunarLeap'),
    featured: jBool(j, 'featured', true),
    plusOne: jBool(j, 'plusOne'),
    highlight: jBool(j, 'highlight'),
    repeat: j['repeat'] is String
        ? j['repeat'] as String
        : (jBool(j, 'yearly') ? 'year' : 'none'),
  );

  /// 单值 remindDays 的历史格式迁移为集合；-1=不提醒、0=当天、n=提前 n 天。
  static List<int> _remindsFromJson(Map<String, dynamic> j) {
    final raw = j['reminds'];
    if (raw is List) {
      return raw.whereType<num>().map((e) => e.toInt()).toSet().toList()
        ..sort();
    }
    final legacy = j['remindDays'];
    if (legacy is int) {
      if (legacy > 0) return [legacy];
      return legacy == 0 ? const [0] : const [];
    }
    return const [0];
  }

  /// 兼容输出：单值 remindDays 取最远的一个或当天。
  int get _legacyRemindDays {
    if (reminds.isEmpty) return -1;
    if (reminds.contains(0)) return 0;
    return reminds.fold(reminds.first, (a, b) => b > a ? b : a);
  }

  Map<String, dynamic> toJson() => {
    'u': updatedAt,
    'id': id,
    'title': title,
    'date': date,
    'yearly': repeat == 'year',
    'repeat': repeat,
    'pinned': pinned,
    'color': color,
    'icon': icon,
    'reminds': reminds,
    'remindDays': _legacyRemindDays,
    'lunar': lunar,
    'lunarMonth': lunarMonth,
    'lunarDay': lunarDay,
    'lunarLeap': lunarLeap,
    'featured': featured,
    'plusOne': plusOne,
    'highlight': highlight,
  };
}

/// 农历月日中文名（如 闰六月十二）；参数非法返回空串。
String lunarLabelOf(int month, int day, bool leap) {
  if (month < 1 || month > 12 || day < 1 || day > 30) return '';
  const months = [
    '正月',
    '二月',
    '三月',
    '四月',
    '五月',
    '六月',
    '七月',
    '八月',
    '九月',
    '十月',
    '冬月',
    '腊月',
  ];
  const days = [
    '初一',
    '初二',
    '初三',
    '初四',
    '初五',
    '初六',
    '初七',
    '初八',
    '初九',
    '初十',
    '十一',
    '十二',
    '十三',
    '十四',
    '十五',
    '十六',
    '十七',
    '十八',
    '十九',
    '二十',
    '廿一',
    '廿二',
    '廿三',
    '廿四',
    '廿五',
    '廿六',
    '廿七',
    '廿八',
    '廿九',
    '三十',
  ];
  return '${leap ? '闰' : ''}${months[month - 1]}${days[day - 1]}';
}

/// 农历转公历（UTC 午夜）。闰月当年不存在时回退平月；日超出月长时截到月末。
DateTime lunarToSolar(int lunarYear, int month, int day, bool leap) {
  var useLeap = leap && LunarYear.fromYear(lunarYear).getLeapMonth() == month;
  var code = useLeap ? -month : month;
  var lm = LunarMonth.fromYm(lunarYear, code);
  if (lm == null) {
    useLeap = false;
    code = month;
    lm = LunarMonth.fromYm(lunarYear, code);
  }
  if (lm == null || day < 1) {
    return DateTime.utc(lunarYear, month, day);
  }
  final solar = Lunar.fromYmd(
    lunarYear,
    code,
    day.clamp(1, lm.getDayCount()),
  ).getSolar();
  return DateTime.utc(solar.getYear(), solar.getMonth(), solar.getDay());
}

class AppData {
  AppData({
    required this.lists,
    required this.tasks,
    required this.habits,
    required this.journal,
    List<Milestone>? milestones,
    List<TrashEntry>? trash,
    List<JournalTrashItem>? journalTrash,
    Map<String, Map<String, ListItem>>? coedits,
  }) : milestones = milestones ?? <Milestone>[],
       trash = trash ?? <TrashEntry>[],
       journalTrash = journalTrash ?? <JournalTrashItem>[],
       coedits = coedits ?? <String, Map<String, ListItem>>{};

  List<TaskList> lists;
  List<PlanTask> tasks;
  List<Habit> habits;
  Map<String, JournalEntry> journal;
  List<Milestone> milestones;

  /// 清单回收站（任意清单删除的条目，FIFO 上限 30、保留 30 天），
  /// 记录原清单 id 与删除时间，支持按清单找回。
  List<TrashEntry> trash;

  /// 已删除日记的回收站（FIFO 上限 15），支持找回；随快照按并集合并。
  List<JournalTrashItem> journalTrash;

  /// 共同编辑改动 overlay：listId -> itemId -> 条目。
  /// 由伴侣端写入、随快照上传，清单所有者合并后修剪。
  Map<String, Map<String, ListItem>> coedits;

  bool get isEmpty =>
      lists.isEmpty && tasks.isEmpty && habits.isEmpty && journal.isEmpty;

  factory AppData.fromJson(Map<String, dynamic> j) {
    final journalRaw = j['journal'];
    final journal = <String, JournalEntry>{};
    if (journalRaw is Map) {
      for (final entry in journalRaw.entries) {
        // 键=日期或日期#篇章 id；过滤畸形键防止下游解析崩溃。
        if (entry.key is! String ||
            !_isJournalKey(entry.key as String)) {
          continue;
        }
        journal[entry.key as String] = JournalEntry.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
    }
    final coedits = <String, Map<String, ListItem>>{};
    final coeditRaw = j['coedits'];
    if (coeditRaw is Map) {
      for (final e in coeditRaw.entries) {
        if (e.key is! String || e.value is! Map) continue;
        final inner = <String, ListItem>{};
        (e.value as Map).forEach((itemId, v) {
          if (itemId is String && v is Map) {
            inner[itemId] =
                ListItem.fromJson(Map<String, dynamic>.from(v));
          }
        });
        if (inner.isNotEmpty) coedits[e.key as String] = inner;
      }
    }
    return AppData(
      lists: _maps(j['lists']).map(TaskList.fromJson).toList(),
      tasks: _maps(j['tasks']).map(PlanTask.fromJson).toList(),
      habits: _maps(j['habits']).map(Habit.fromJson).toList(),
      journal: journal,
      milestones: _maps(j['milestones']).map(Milestone.fromJson).toList(),
      trash: _trashFromJson(j),
      journalTrash:
          _maps(j['journalTrash']).map(JournalTrashItem.fromJson).toList(),
      coedits: coedits,
    );
  }

  /// 回收站反序列化：新字段 `trash`；旧客户端/旧快照只有 `unfiledTrash`
  /// （未分类删除的裸条目），迁移为 listId=未分类、deletedAt=0 的条目。
  static List<TrashEntry> _trashFromJson(Map<String, dynamic> j) {
    final byId = <String, TrashEntry>{};
    for (final m in _maps(j['trash'])) {
      final e = TrashEntry.fromJson(m);
      final cur = byId[e.item.id];
      if (cur == null || e.deletedAt > cur.deletedAt) byId[e.item.id] = e;
    }
    for (final m in _maps(j['unfiledTrash'])) {
      final item = ListItem.fromJson(m);
      byId.putIfAbsent(
        item.id,
        () => TrashEntry(listId: kUnfiledListId, item: item),
      );
    }
    return byId.values.toList();
  }

  Map<String, dynamic> toJson() => {
    'lists': lists.map((e) => e.toJson()).toList(),
    'tasks': tasks.map((e) => e.toJson()).toList(),
    'habits': habits.map((e) => e.toJson()).toList(),
    'journal': {for (final e in journal.entries) e.key: e.value.toJson()},
    'milestones': milestones.map((e) => e.toJson()).toList(),
    // 只写新字段；旧客户端忽略未知键即可（旧 unfiledTrash 不再输出）。
    'trash': trash.map((e) => e.toJson()).toList(),
    if (journalTrash.isNotEmpty)
      'journalTrash': journalTrash.map((e) => e.toJson()).toList(),
    if (coedits.isNotEmpty)
      'coedits': {
        for (final e in coedits.entries)
          e.key: {
            for (final item in e.value.entries) item.key: item.value.toJson(),
          },
      },
  };

  String encode() => jsonEncode(toJson());

  static AppData decode(String raw) =>
      AppData.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  static List<Map<String, dynamic>> _maps(dynamic v) =>
      ((v as List?) ?? const [])
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
}
