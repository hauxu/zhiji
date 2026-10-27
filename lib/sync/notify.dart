import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 系统通知：任务提醒/情侣消息/情侣动态三通道；
/// 通道 ID 带版本后缀，调整配置时换新 ID 并清理旧通道。
class Notify {
  Notify._();

  static final Notify instance = Notify._();

  final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// 测试提醒的通知 id 独立区间：0x9000 起递增，永不与留言/动态冲突
  /// （旧实现 _seq=100 会和第一条留言通知抢同一个 id）。
  static int _testSeq = 0x9000;

  // 通知 id 分区：
  //   0x1000–0x3FFF 留言；0x5000–0x7FFF 动态；0x9000–0x9FFF 测试提醒；
  //   990001 更新进度（见 showUpdateProgress）。
  // 同一个 dedupKey（msg:/cmt:/sys: 或内容兜底）生成稳定 id：同一条消息被
  // 两个引擎各弹一次时后一次覆盖前一次；不同消息各占一个 id，不再互相顶掉。
  static int _stableHash(String key) {
    var h = 0x811c9dc5;
    for (final code in key.codeUnits) {
      h ^= code;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  static int _messageNotificationId(String key) =>
      0x1000 + (_stableHash(key) % 0x3000);

  static int _eventNotificationId(String key) =>
      0x5000 + (_stableHash(key) % 0x3000);

  static const _chTask = 'task_reminders_v4';
  static const _chMessage = 'couple_messages_v5';
  static const _chEvent = 'couple_events_v5';
  static const _chMilestone = 'milestone_reminders_v4';
  static const _chHabit = 'habit_reminders_v4';

  /// 应用更新进度/就绪通知渠道（静音）。
  static const chAppUpdate = 'app_update_v1';

  /// 横幅引导用：渠道 id 与中文名（设置页直达列表）。
  static const bannerChannels = <(String, String)>[
    (_chTask, '任务提醒'),
    (_chMilestone, '倒数日提醒'),
    (_chHabit, '习惯打卡提醒'),
    (_chMessage, '情侣消息'),
    (_chEvent, '情侣动态'),
  ];
  static const _deprecatedChannelIds = [
    'task_reminders',
    'couple_messages',
    'couple_events',
    'task_reminders_v2',
    'couple_messages_v2',
    'couple_events_v2',
    'milestone_reminders_v1',
    'task_reminders_v3',
    'milestone_reminders_v2',
    'habit_reminders_v1',
    'couple_messages_v3',
    'couple_events_v3',
    'sync_service_v1',
  ];

  /// 由 App 外壳挂接：点击通知后切换页面。
  void Function(String route)? onNotificationTap;

  /// 通知开关：关闭后 show 为空操作。
  bool coupleMessagesEnabled = true;
  bool coupleEventsEnabled = true;

  Future<void> init() async {
    if (_ready) return;
    try {
      await plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          windows: WindowsInitializationSettings(
            appName: '之计',
            appUserModelId: 'com.huaxu.judging',
            // Windows AUMID 图标：便携版可降级。
            guid: '8e4f5c2a-9b71-4d3e-a0c6-5a1b2c3d4e5f',
          ),
        ),
        onDidReceiveNotificationResponse: (resp) {
          final route = resp.payload;
          if (route != null && route.isNotEmpty) {
            onNotificationTap?.call(route);
          }
        },
      );
      final android = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      for (final id in _deprecatedChannelIds) {
        try {
          await android?.deleteNotificationChannel(id);
        } catch (_) {}
      }
      await _precreateChannels(android);
      // 旧版留言/动态用固定 id 100/101、测试提醒从 100 递增；升级后取消
      // 这些旧通知，避免通知栏里残留一条永远盖不掉的旧消息。
      try {
        await plugin.cancel(100);
        await plugin.cancel(101);
      } catch (_) {}
      _ready = true;
    } catch (_) {}
  }

  /// 启动即把全部渠道建齐：渠道原先在首次 show 时才创建，
  /// 没触发过的用户在系统通知设置里看不到对应渠道、也无从配置横幅。
  Future<void> _precreateChannels(
    AndroidFlutterLocalNotificationsPlugin? android,
  ) async {
    if (android == null) return;
    final vibration = Int64List.fromList([0, 250, 150, 250]);
    const ledColor = Color.fromARGB(255, 211, 47, 47);
    final channels = <AndroidNotificationChannel>[
      for (final (id, name) in bannerChannels)
        AndroidNotificationChannel(
          id,
          name,
          description: switch (id) {
            _chTask => '到点的计划任务提醒',
            _chMilestone => '纪念日与倒数日的到点提醒',
            _chHabit => '每日习惯的打卡时间提醒',
            _chMessage => 'TA 发来的留言',
            _ => 'TA 的完成与评价动态',
          },
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
          vibrationPattern: vibration,
          enableLights: true,
          ledColor: ledColor,
        ),
      const AndroidNotificationChannel(
        chAppUpdate,
        '应用更新',
        description: '新版本下载进度与就绪提示',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    ];
    for (final ch in channels) {
      try {
        await android.createNotificationChannel(ch);
      } catch (_) {}
    }
  }

  /// 应用更新后台下载进度（静音、固定通知条随进度刷新）。
  Future<void> showUpdateProgress({
    required int percent,
    required String version,
    bool ready = false,
    String? path,
  }) async {
    if (!Platform.isAndroid) return;
    await init();
    if (!_ready) return;
    try {
      final title = ready ? 'v$version 更新已就绪' : '正在下载 v$version 更新';
      final body = ready
          ? '点击立即安装'
          : percent >= 100 ? '即将完成…' : '已下载 $percent%（中断后可续传）';
      await plugin.show(
        990001,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            chAppUpdate,
            '应用更新',
            channelDescription: '新版本下载进度与就绪提示',
            importance: Importance.low,
            priority: Priority.low,
            playSound: false,
            enableVibration: false,
            onlyAlertOnce: true,
            ongoing: !ready,
            showProgress: !ready,
            maxProgress: 100,
            progress: percent.clamp(0, 100),
            autoCancel: ready,
          ),
        ),
        payload: ready ? 'update-install' : null,
      );
    } catch (_) {}
  }

  /// 清除更新进度通知（取消/失败时）。
  Future<void> clearUpdateProgress() async {
    if (!Platform.isAndroid) return;
    try {
      await plugin.cancel(990001);
    } catch (_) {}
  }

  /// 冷启动通知点击路由，重复调用无副作用。
  Future<void> routePendingLaunch() async {
    if (_launchRouted) return;
    _launchRouted = true;
    try {
      final details = await plugin.getNotificationAppLaunchDetails();
      final didLaunch = details?.didNotificationLaunchApp ?? false;
      final payload = details?.notificationResponse?.payload;
      if (didLaunch && payload != null && payload.isNotEmpty) {
        onNotificationTap?.call(payload);
      }
    } catch (_) {}
  }

  static bool _launchRouted = false;

  /// 启动时调用：未授予通知权限则发起系统授权弹窗。
  Future<void> ensurePermission() async {
    await init();
    if (!_ready) return;
    try {
      final android = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final enabled = await android?.areNotificationsEnabled();
      if (enabled == false) {
        await android?.requestNotificationsPermission();
      }
    } catch (_) {}
  }

  Future<bool> requestPermission() async {
    await init();
    try {
      final granted = await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 发起全屏弹窗（悬浮通知）系统授权；返回用户是否授予。
  /// （权限状态检测走 NativeShare.canUseFullScreenIntent。）
  Future<bool> requestFullScreenIntent() async {
    try {
      return await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestFullScreenIntentPermission() ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 精确闹钟权限：false = 提醒可能漂移到时间窗内任意时刻。
  Future<bool> canScheduleExact() async {
    try {
      return await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.canScheduleExactNotifications() ??
          false;
    } catch (_) {
      return false;
    }
  }

  AndroidNotificationDetails _details(
    String channelId,
    String channelName,
    String description, {
    AndroidNotificationCategory category = AndroidNotificationCategory.reminder,
    String body = '',
    bool fullScreen = false,
  }) {
    return AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: description,
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 250, 150, 250]),
      enableLights: true,
      ledColor: const Color.fromARGB(255, 211, 47, 47),
      ledOnMs: 800,
      ledOffMs: 1200,
      // 锁屏上不显示正文：留言和评价是私密内容，公共场合亮屏不该被旁人看到。
      visibility: NotificationVisibility.private,
      category: category,
      // 提醒类到点直接全屏弹出（锁屏亮屏、使用中横幅），对齐系统闹钟规格。
      fullScreenIntent: fullScreen,
      styleInformation: body.isEmpty
          ? null
          : BigTextStyleInformation(body),
      autoCancel: true,
    );
  }

  NotificationDetails taskReminderDetails() {
    return NotificationDetails(
      android: _details(_chTask, '任务提醒', '到点的计划任务提醒',
          category: AndroidNotificationCategory.alarm, fullScreen: true),
    );
  }

  NotificationDetails milestoneReminderDetails() {
    return NotificationDetails(
      android: _details(_chMilestone, '倒数日提醒', '纪念日与倒数日的到点提醒',
          category: AndroidNotificationCategory.alarm, fullScreen: true),
    );
  }

  NotificationDetails habitReminderDetails() {
    return NotificationDetails(
      android: _details(_chHabit, '习惯打卡提醒', '每日习惯的打卡时间提醒',
          category: AndroidNotificationCategory.alarm, fullScreen: true),
    );
  }

  /// 立即弹一条测试提醒（与真实提醒同渠道同规格），用于当场验证
  /// 横幅/锁屏全屏效果是否被 ROM 放行。
  Future<void> showTestReminder() async {
    await init();
    if (!_ready) return;
    try {
      final id = _testSeq;
      _testSeq = _testSeq >= 0x9fff ? 0x9000 : _testSeq + 1;
      await plugin.show(
        id,
        '提醒测试 · 通道正常',
        '如果能横幅弹出或锁屏亮屏，说明提醒规格已生效',
        taskReminderDetails(),
        payload: 'plan',
      );
    } catch (_) {}
  }

  /// [dedupKey] 是消息/评价的稳定 id（msg:/cmt:/sys:）。同一个 key 的通知
  /// 互相覆盖（去重语义），不同 key 各占一个通知位（不再只剩最后一条）。
  Future<void> showCoupleMessage(String title, String body,
      {String? dedupKey}) {
    if (!coupleMessagesEnabled) return Future.value();
    final key = dedupKey ?? 'msg:$title:$body';
    return _show(
      _chMessage,
      '情侣消息',
      'TA 发来的留言',
      title,
      body,
      'couple',
      category: AndroidNotificationCategory.message,
      id: _messageNotificationId(key),
    );
  }

  Future<void> showCoupleEvent(String title, String body,
      {String? dedupKey}) {
    if (!coupleEventsEnabled) return Future.value();
    final key = dedupKey ?? 'evt:$title:$body';
    return _show(_chEvent, '情侣动态', 'TA 的完成与评价动态', title, body,
        'couple', id: _eventNotificationId(key));
  }

  Future<void> _show(
    String channel,
    String channelName,
    String description,
    String title,
    String body,
    String route, {
    AndroidNotificationCategory category = AndroidNotificationCategory.reminder,
    required int id,
  }) async {
    await init();
    if (!_ready) return;
    try {
      await plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: _details(
            channel,
            channelName,
            description,
            category: category,
            body: body,
          ),
          // Windows 没有渠道概念，走系统通知中心。
          windows: Platform.isWindows
              ? const WindowsNotificationDetails()
              : null,
        ),
        payload: route,
      );
    } catch (_) {}
  }
}
