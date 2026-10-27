import 'dart:convert';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/models.dart';
import '../data/store.dart';
import '../util/dates.dart';
import 'couple_models.dart';
import 'package:flutter/foundation.dart';
import 'focus_island.dart';
import 'notify.dart';
import '../util/native_share.dart';

typedef _Pending = ({
  tz.TZDateTime time,
  String title,
  String body,
  bool milestone,
  // 岛倒计时目标（任务开始/结束、倒数日当天）；空则用 time。
  tz.TZDateTime? target,
  // 任务进行中实况边界（有开始+结束时间的任务才有）。
  tz.TZDateTime? liveStart,
  tz.TZDateTime? liveEnd,
});

/// 每日 00:05 维护闹钟：滚动重排 8 天提醒窗口。
const int kMaintenanceAlarmId = 20260103;

/// 退后台兜底闹钟（2 分钟同步）之外的通知维护入口。
@pragma('vm:entry-point')
Future<void> maintenanceTickEntry(int id, Map<String, dynamic> params) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.load();
  final prefs = await SharedPreferences.getInstance();
  final partnerRaw = prefs.getString('gd2_partner');
  List<Milestone> partnerMilestones = const [];
  if (partnerRaw != null && partnerRaw.isNotEmpty) {
    try {
      final partner = PartnerData.fromJson(
          Map<String, dynamic>.from(jsonDecode(partnerRaw) as Map));
      partnerMilestones = partner.data.milestones;
    } catch (_) {}
  }
  await Reminders.rescheduleAll(
    store,
    force: true,
    taskEnabled: prefs.getBool('gd2_sw_task') ?? true,
    milestoneEnabled: prefs.getBool('gd2_sw_ms') ?? true,
    habitEnabled: prefs.getBool('gd2_sw_habit') ?? false,
    partnerMilestones: partnerMilestones,
  );
}

/// 任务提醒：按开始/结束时间排未来 7 天通知，周任务周日 20:00 提醒；
/// 倒数本：合并双方条目按下次发生日提醒；数据变更后整体重排。
/// 调度原则：不排推测性重试闹钟。Doze 对 allow-while-idle 闹钟有每应用配额，
/// 保险闹钟会挤掉真正到点的提醒。
class Reminders {
  Reminders._();

  static const _idBase = 2000000000;
  static const _maxPending = 80;
  static const _sigKey = 'gd2_schedule_sig';
  static bool _tzReady = false;
  static List<int> _scheduled = [];

  static Future<void> initTimezones() async {
    if (_tzReady) return;
    try {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation(_systemZoneName()));
      _tzReady = true;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      _scheduled = (prefs.getStringList('gd2_reminder_ids') ?? [])
          .map(int.parse)
          .toList();
    } catch (_) {
      _scheduled = [];
    }
  }

  /// 匹配系统时区，匹配不到回退东八区。
  static String _systemZoneName() {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final janMs = tz.TZDateTime.utc(now.year, 1, 15).millisecondsSinceEpoch;
    final julMs = tz.TZDateTime.utc(now.year, 7, 15).millisecondsSinceEpoch;
    final targetSeconds = now.timeZoneOffset.inSeconds;
    String? exact;
    String? shaped;
    tz.timeZoneDatabase.locations.forEach((name, location) {
      final zone = location.timeZone(nowMs);
      // 首选：当前时刻的偏移与系统一致。
      if (zone.offset == targetSeconds) {
        exact ??= name;
        // 再要求全年偏移形态一致（冬/夏至都同差），排除恰好同偏移的异形时区。
        if (location.timeZone(janMs).offset == targetSeconds &&
            location.timeZone(julMs).offset == targetSeconds) {
          shaped ??= name;
        }
      }
    });
    return shaped ?? exact ?? 'Asia/Shanghai';
  }

  static Future<void> _saveIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          'gd2_reminder_ids', _scheduled.map((i) => '$i').toList());
    } catch (_) {}
  }

  static Future<void> cancelPending() async {
    await initTimezones();
    for (final id in _scheduled) {
      try {
        await Notify.instance.plugin.cancel(id);
      } catch (_) {}
    }
    _scheduled = [];
    await _saveIds();
    if (Platform.isAndroid) await FocusIsland.cancelIslands();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sigKey, '');
    } catch (_) {}
  }

  static Future<void> rescheduleAll(AppStore store,
      {bool force = false,
      bool taskEnabled = true,
      bool milestoneEnabled = true,
      bool habitEnabled = false,
      Iterable<Milestone> partnerMilestones = const []}) async {
    await initTimezones();
    debugPrint('[reminders] rescheduleAll force=$force tzReady=$_tzReady task=$taskEnabled ms=$milestoneEnabled habit=$habitEnabled');
    if (!_tzReady) return;
    if (!taskEnabled && !milestoneEnabled && !habitEnabled) {
      await cancelPending();
      return;
    }
    final base = today();
    final pending = <_Pending>[];
    final habitDefs = <({String key, String name, String time})>[];

    if (taskEnabled) _taskPending(store, base, pending);
    if (milestoneEnabled) {
      _milestonePending(
          [...store.data.milestones, ...partnerMilestones], base, pending);
    }
    if (habitEnabled) {
      for (final h in store.data.habits) {
        if (h.reminder) {
          habitDefs.add((key: h.id, name: h.name, time: h.reminderTime));
        }
      }
    }

    // Android 12+ 精确闹钟：默认尝试精确，被拒则回退非精确。
    var scheduleMode = AndroidScheduleMode.exactAllowWhileIdle;
    try {
      final canExact = await Notify.instance.plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.canScheduleExactNotifications();
      if (canExact == false) {
        scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;
      }
    } catch (_) {}

    // 超级岛模式（实验）：任务/倒数日改走原生焦点通知，与普通通知互斥。
    // 判定只读 prefs 缓存——后台维护闹钟的 isolate 没有插件通道，
    // 且岛闹钟由原生清单独立存活，重排时无需（也无法）触碰。
    final prefs = await SharedPreferences.getInstance();
    final islandOn = Platform.isAndroid &&
        (prefs.getBool('gd2_island_enabled') ?? false) &&
        (prefs.getBool('gd2_island_usable') ?? false);

    // 排程签名：内容与配置没变就不重排，避免每次启动/数据防抖都全量打翻系统闹钟。
    final sig = _signature(
        pending, habitDefs, scheduleMode, islandOn);
    final stored = prefs.getString(_sigKey);
    // 签名一致即跳过重排（_scheduled 为空的正经场景：确实没有可排提醒）。
    final sigUnchanged = !force && stored != null && stored == sig;
    debugPrint('[reminders] sig=${sig.substring(0, 8)} stored=${stored?.substring(0, 8) ?? "null"} unchanged=$sigUnchanged');
    if (sigUnchanged) {
      await _scheduleMaintenance();
      return;
    }
    try {
      await prefs.setString(_sigKey, sig);
      debugPrint('[reminders] sig saved: ${(prefs.getString(_sigKey) ?? "null").substring(0, 8)}');
    } catch (e) {
      debugPrint('[reminders] sig save failed: $e');
    }

    final notify = Notify.instance;
    for (final id in _scheduled) {
      try {
        await notify.plugin.cancel(id);
      } catch (_) {}
    }
    _scheduled = [];
    if (Platform.isAndroid) await FocusIsland.cancelIslands();

    // 习惯打卡提醒先排。Windows 不支持每日重复需逐日占位，
    // 给习惯一段独立预算（约三成），避免挤掉任务与倒数日提醒。
    final habitDailyRepeat = !Platform.isWindows;
    final habitBudget =
        _idBase + (habitDailyRepeat ? _maxPending : _maxPending * 3 ~/ 8);
    var nextId = _idBase;
    if (habitEnabled) {
      for (final h in habitDefs) {
        if (nextId >= habitBudget) continue;
        final parts = h.time.split(':');
        final hh = int.tryParse(parts[0]);
        final mm = parts.length == 2 ? int.tryParse(parts[1]) : null;
        if (hh == null || mm == null) continue;
        var when =
            tz.TZDateTime(tz.local, base.year, base.month, base.day, hh, mm);
        if (!when.isAfter(tz.TZDateTime.now(tz.local))) {
          when = when.add(const Duration(days: 1));
        }
        var day = when;
        var placed = 0;
        do {
          try {
            await notify.plugin.zonedSchedule(
              nextId,
              '习惯打卡 · ${h.name}',
              '到了 ${h.time}，去打个卡吧',
              day,
              notify.habitReminderDetails(),
              payload: 'habits', // 点击路由
              androidScheduleMode: scheduleMode,
              // Android 每日同一时刻重复，一次排定。
              matchDateTimeComponents: habitDailyRepeat
                  ? DateTimeComponents.time
                  : null,
            );
            _scheduled.add(nextId);
            nextId++;
          } catch (_) {}
          if (!habitDailyRepeat) {
            day = day.add(const Duration(days: 1));
            placed++;
          }
        } while (!habitDailyRepeat &&
            placed < 7 &&
            nextId < habitBudget);
      }
    }

    if (islandOn) {
      // 超级岛模式：任务/倒数日一次性提醒改走原生焦点闹钟，
      // 触发时以灵动岛胶囊弹出（普通通知不排，避免双响）。
      final items = <Map<String, dynamic>>[];
      for (final item in pending) {
        if (nextId >= _idBase + _maxPending) break;
        final target = (item.target ?? item.time).millisecondsSinceEpoch;
        items.add({
          'id': nextId,
          'time': item.time.millisecondsSinceEpoch,
          'timeout': item.time.millisecondsSinceEpoch + 10 * 60 * 1000,
          'title': item.title,
          'body': item.body,
          'target': target,
        });
        nextId++;
      }
      debugPrint('[reminders] island items=${items.length}');
      await FocusIsland.scheduleIslands(items);
    } else {
      for (final item in pending) {
        // Windows 习惯提醒可能已占满预算，任务/倒数日受同一总额约束。
        if (nextId >= _idBase + _maxPending) break;
        try {
          await notify.plugin.zonedSchedule(
            nextId,
            item.title,
            item.body,
            item.time,
            item.milestone
                ? notify.milestoneReminderDetails()
                : notify.taskReminderDetails(),
            payload: item.milestone ? 'milestone' : 'plan', // 点击路由
            androidScheduleMode: scheduleMode,
          );
          _scheduled.add(nextId);
          nextId++;
        } catch (e) { debugPrint('[reminders] zonedSchedule fail id=$nextId: $e'); }
      }
    }
    debugPrint('[reminders] done, scheduled=${_scheduled.length}');
    await _saveIds();
    // 任务进行中实况：把有 start+end 边界的任务注入原生
    // （小米岛开启时实况服务自己让位给焦点通知，由原生侧互斥）。
    if (Platform.isAndroid) {
      // 任务进行中实况恒开（设置页已去掉开关，忽略历史 false）。
      final liveItems = <Map<String, dynamic>>[
        for (final p in pending)
          if (p.liveStart != null && p.liveEnd != null)
            {
              'id': 'live-${p.time.millisecondsSinceEpoch}',
              'title': p.body,
              'startAt': p.liveStart!.millisecondsSinceEpoch,
              'endAt': p.liveEnd!.millisecondsSinceEpoch,
            },
      ];
      await NativeShare.scheduleTaskLive(liveItems);
    }
    await _scheduleMaintenance();
  }

  /// 排程签名：任一提醒的内容/时间/开关/模式变化都会改变签名。
  static String _signature(
      List<_Pending> pending,
      List<({String key, String name, String time})> habitDefs,
      AndroidScheduleMode scheduleMode,
      bool islandOn) {
    final parts = <String>[
      tz.local.name,
      scheduleMode.toString(),
      islandOn.toString(),
      for (final p in pending)
        '${p.time.millisecondsSinceEpoch}|${p.title}|${p.body}'
            '|${p.milestone}|${(p.target ?? p.time).millisecondsSinceEpoch}'
            '|${p.liveStart?.millisecondsSinceEpoch ?? 0}'
            '|${p.liveEnd?.millisecondsSinceEpoch ?? 0}',
      for (final h in habitDefs) 'habit:${h.key}:${h.time}',
    ];
    return sha256.convert(utf8.encode(parts.join('\n'))).toString();
  }

  /// 每日 00:05 维护闹钟：滚动重排提醒窗口（Android 原生闹钟）。
  /// Windows 无 alarm manager，依赖启动与数据变更触发重排。
  static Future<void> _scheduleMaintenance() async {
    if (!Platform.isAndroid) return;
    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(tz.local, now.year, now.month, now.day, 0, 5);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    // 精确闹钟被拒（Android 14+ 新装默认拒绝）时降级为非精确——
    // 维护闹钟晚几分钟无所谓，但不能静默丢失。
    var exact = true;
    try {
      final canExact = await Notify.instance.plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.canScheduleExactNotifications();
      if (canExact == false) exact = false;
    } catch (_) {}
    try {
      await AndroidAlarmManager.oneShot(
        next.difference(now),
        kMaintenanceAlarmId,
        maintenanceTickEntry,
        allowWhileIdle: true,
        exact: exact,
        wakeup: true,
        rescheduleOnReboot: true,
      );
    } catch (_) {
      try {
        await AndroidAlarmManager.oneShot(
          next.difference(now),
          kMaintenanceAlarmId,
          maintenanceTickEntry,
          allowWhileIdle: true,
          wakeup: true,
          rescheduleOnReboot: true,
        );
      } catch (_) {}
    }
  }

  static void _taskPending(
      AppStore store, DateTime base, List<_Pending> pending) {
    for (var offset = 0; offset <= 7; offset++) {
      final day = base.add(Duration(days: offset));
      for (final task in store.data.tasks) {
        if (task.archived) continue;
        if (!task.hasDate && !task.isRecurring) continue;
        if (!task.occursOn(day) || task.isDoneOn(day)) continue;
        if (!task.hasAnyTime) continue;
        // 开始/结束时间独立设置：优先提醒开始，只有结束则按结束提醒。
        final timeStr = task.start.isNotEmpty ? task.start : task.end;
        final parts = timeStr.split(':');
        if (parts.length != 2) continue;
        final hour = int.tryParse(parts[0]);
        final minute = int.tryParse(parts[1]);
        if (hour == null || minute == null) continue;
        final local = tz.TZDateTime(
          tz.local,
          day.year,
          day.month,
          day.day,
          hour,
          minute,
        );
        if (local.isBefore(tz.TZDateTime.now(tz.local))) continue;
        if (pending.length >= _maxPending) break;
        // 进行中实况边界：开始与结束时间都有才常驻实况。
        tz.TZDateTime? liveStart;
        tz.TZDateTime? liveEnd;
        if (task.start.isNotEmpty && task.end.isNotEmpty) {
          final sp = task.start.split(':');
          final ep = task.end.split(':');
          if (sp.length == 2 && ep.length == 2) {
            final sh = int.tryParse(sp[0]);
            final sm = int.tryParse(sp[1]);
            final eh = int.tryParse(ep[0]);
            final em = int.tryParse(ep[1]);
            if (sh != null && sm != null && eh != null && em != null) {
              liveStart = tz.TZDateTime(tz.local, day.year, day.month, day.day, sh, sm);
              liveEnd = tz.TZDateTime(tz.local, day.year, day.month, day.day, eh, em);
              if (!liveEnd.isAfter(liveStart)) {
                liveStart = null;
                liveEnd = null;
              }
            }
          }
        }
        pending.add((
          time: local,
          title: '任务提醒 · ${_dayLabel(day)}',
          body: '${task.timeLabel.isEmpty ? '' : '${task.timeLabel}  '}'
              '${task.title}',
          milestone: false,
          // 岛倒计时目标 = 任务开始时刻。
          target: local,
          liveStart: liveStart,
          liveEnd: liveEnd,
        ));

        // 结束前提醒：按任务的提前量在 end 之前单独排一条。
        if (task.remindBefore > 0 && task.end.isNotEmpty) {
          final ep = task.end.split(':');
          final eh = int.tryParse(ep[0]);
          final em = int.tryParse(ep[1]);
          if (ep.length == 2 && eh != null && em != null) {
            final endAt = tz.TZDateTime(
                tz.local, day.year, day.month, day.day, eh, em);
            final due =
                endAt.subtract(Duration(minutes: task.remindBefore));
            if (!due.isBefore(tz.TZDateTime.now(tz.local)) &&
                pending.length < _maxPending) {
              pending.add((
                time: due,
                title: '任务即将结束 · ${_dayLabel(day)}',
                body: '${task.timeLabel.isEmpty ? '' : '${task.timeLabel}  '}'
                    '${task.title}',
                milestone: false,
                // 岛倒计时目标 = 任务结束时刻。
                target: endAt,
                liveStart: null,
                liveEnd: null,
              ));
            }
          }
        }
      }
    }

    // 本周内完成的无日期任务：周日 20:00 提醒未完成数量。
    final weekStart = weekStartOf(base);
    final unfinished =
        store.weekTasks().where((t) => !t.done).length;
    final sunday = weekStart.add(const Duration(days: 6));
    final sundayTime = tz.TZDateTime(tz.local, sunday.year, sunday.month,
        sunday.day, 20, 0);
    if (unfinished > 0 && sundayTime.isAfter(tz.TZDateTime.now(tz.local))) {
      pending.add((
        time: sundayTime,
        title: '周计划提醒',
        body: '本周还有 $unfinished 项周计划未完成，别忘了',
        milestone: false,
        target: null,
        liveStart: null,
        liveEnd: null,
      ));
    }
  }

  /// 每年重复的条目只排下一次周年；应用重启或数据变化会整体重排。
  /// 多档提醒各排一条；提前量已错过时退回当天的提醒。
  static void _milestonePending(
      List<Milestone> all, DateTime base, List<_Pending> pending) {
    for (final m in all) {
      if (m.date.length != 10) continue;
      final offsets = m.reminds.toSet().toList()..sort();
      if (offsets.isEmpty) continue;
      final next = m.nextOccurrence(base);
      final seen = <int>{};
      for (final daysBefore in offsets.reversed) {
        if (pending.length >= _maxPending) return;
        var off = daysBefore;
        var when = next.subtract(Duration(days: off));
        var at = tz.TZDateTime(tz.local, when.year, when.month, when.day, 9, 30);
        if (!at.isAfter(tz.TZDateTime.now(tz.local)) && off > 0) {
          off = 0;
          at = tz.TZDateTime(tz.local, next.year, next.month, next.day, 9, 30);
        }
        if (!at.isAfter(tz.TZDateTime.now(tz.local))) continue;
        if (!seen.add(off)) continue;
        pending.add((
          time: at,
          title: off > 0 ? '「${m.title}」还有 $off 天' : '「${m.title}」就是今天',
          body: off > 0 ? '倒数日快到了，提前准备一下吧' : '记得和 TA 说一声',
          milestone: true,
          // 岛倒计时目标 = 倒数日当天 09:30。
          target: tz.TZDateTime(
              tz.local, next.year, next.month, next.day, 9, 30),
          liveStart: null,
          liveEnd: null,
        ));
      }
    }
  }

  static String _dayLabel(DateTime d) {
    final t = today();
    if (dateKey(d) == dateKey(t)) return '今天';
    if (dateKey(d) == dateKey(t.add(const Duration(days: 1)))) return '明天';
    return '${d.month}月${d.day}日';
  }
}
