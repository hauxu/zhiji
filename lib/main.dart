// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'data/store.dart';
import 'sync/couple_models.dart';
import 'sync/keep_alive.dart';
import 'sync/notify.dart';
import 'sync/reminders.dart';
import 'sync/sync_service.dart';
import 'theme.dart';
import 'ui_prefs.dart';
import 'theme_store.dart';
import 'desktop/windows_shell.dart';
import 'util/window_bridge.dart';
import 'widgets/celebration.dart';
import 'widgets/top_toast.dart';
import 'widgets/app_keys.dart';
import 'widgets/responsive.dart';
import 'widgets/in_app_banner.dart';

final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 通知点击路由（由 HomeShell 挂接）。
void Function(String route)? globalRouteHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 只有 Android 注册了该插件；Windows/Linux 上调 initialize 没有 handler。
  if (Platform.isAndroid) {
    try {
      await AndroidAlarmManager.initialize();
    } catch (e) {
      debugPrint('alarm manager init failed: $e');
    }
  }
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await initializeDateFormatting('zh_CN');
  await Notify.instance.init();
  await Celebration.preload();
  await Notify.instance.ensurePermission();
  // 后台保活开关（默认开）：只影响 Android 的常驻连接。
  await KeepAliveBridge.load();
  final store = AppStore();
  await store.load();
  final sync = SyncService(store);
  await sync.init();
  final themeStore = ThemeStore();
  await themeStore.load();
  final uiPrefs = UiPrefs();
  await uiPrefs.load();
  await Reminders.initTimezones();
  // 系统撤销精确闹钟权限时会清掉全部 exact 闹钟（原生 receiver 留标记），
  // 检测到标记则强制重排一次。
  final exactRescheduleNeeded =
      (await SharedPreferences.getInstance()).getBool(
        'gd2_exact_reschedule_needed',
      ) ==
      true;
  await Reminders.rescheduleAll(
    store,
    force: exactRescheduleNeeded,
    taskEnabled: sync.swTaskReminders,
    milestoneEnabled: sync.swMilestoneReminders,
    habitEnabled: sync.swHabitReminders,
    partnerMilestones: sync.partner?.data.milestones ?? const [],
  );
  if (exactRescheduleNeeded) {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('gd2_exact_reschedule_needed');
  }

  // 前台只弹应用内提示，后台只走系统通知，避免重复打扰。
  sync.onEvent = (CoupleEvent event) {
    // 设备确认码：模态展示（60 秒一次性，双方核对即确认设备可信）。
    if (event.title == '设备确认码') {
      showTopToast('设备确认码 ${event.body}（1 分钟内有效）');
      return;
    }
    if (sync.isForeground) {
      if (event.isMessage && !sync.boardVisible) {
        // 留言走顶部横幅，点击可直达留言板；人已在留言板时气泡即时出现，不再弹。
        showInAppBanner(
          title: event.title,
          body: event.body,
          avatarPath: sync.partnerAvatarPath,
          onTap: () => globalRouteHandler?.call('couple_board'),
        );
      }
    } else {
      // 后台通知：保活引擎可能也收到同一条，统一入口会去重。
      sync.notifyCoupleEventOnce(event);
    }
  };
  Notify.instance.onNotificationTap = (route) =>
      globalRouteHandler?.call(route);

  // 数据变化后重排任务提醒。
  Timer? rescheduleDebounce;
  void scheduleReschedule() {
    rescheduleDebounce?.cancel();
    rescheduleDebounce = Timer(const Duration(seconds: 3), () {
      Reminders.rescheduleAll(
        store,
        taskEnabled: sync.swTaskReminders,
        milestoneEnabled: sync.swMilestoneReminders,
        habitEnabled: sync.swHabitReminders,
        partnerMilestones: sync.partner?.data.milestones ?? const [],
      );
    });
  }

  store.addListener(scheduleReschedule);
  // 伴侣快照实际更新时重排（TA 新增倒数日会在我这边排提醒）。
  var lastPartnerStamp = 0;
  sync.addListener(() {
    final stamp = sync.partner?.updatedAt ?? 0;
    if (stamp == lastPartnerStamp) return;
    lastPartnerStamp = stamp;
    scheduleReschedule();
  });

  // Windows：托盘 + 关闭最小化到托盘。
  if (Platform.isWindows) {
    try {
      await WindowBridge.setMinimizeToTray(true);
      await WindowsShell.instance.setup(
        showWindow: () {
          sync.desktopWindowHidden = false;
          WindowBridge.showFromTray();
          WindowsShell.instance.showFromTray();
        },
        syncNow: () async {
          await sync.syncNow(push: true, manual: true);
        },
        quit: () => WindowBridge.quitApp(),
      );
      WindowBridge.onCloseRequested(() async {
        sync.desktopWindowHidden = true;
        await WindowsShell.instance.hideToTray();
        if (await WindowsShell.instance.takeTrayHintOnce()) {
          // 只在第一次说明一下，之后安静地待在托盘里。
          globalRouteHandler?.call('/settings');
        }
      });
    } catch (e) {
      debugPrint('windows shell init failed: $e');
    }
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: themeStore),
        ChangeNotifierProvider.value(value: uiPrefs),
      ],
      child: const DynamicColorWrapper(),
    ),
  );
}

int _argb(Color c) {
  int ch(double v) => (v * 255).round() & 0xFF;
  return (ch(c.a) << 24) | (ch(c.r) << 16) | (ch(c.g) << 8) | ch(c.b);
}

/// 动态取色包装；Windows 同步标题栏主题。
class DynamicColorWrapper extends StatefulWidget {
  const DynamicColorWrapper({super.key});

  @override
  State<DynamicColorWrapper> createState() => _DynamicColorWrapperState();
}

class _DynamicColorWrapperState extends State<DynamicColorWrapper>
    with WidgetsBindingObserver {
  String? _lastPushed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      WindowsShell.instance.glassEnabled.addListener(_onGlassChanged);
    }
  }

  void _onGlassChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) {
      WindowsShell.instance.glassEnabled.removeListener(_onGlassChanged);
    }
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Windows 已上毛玻璃：直接跳过 DynamicColorBuilder，不走莫奈取色，
    // 固定品牌种子色；Android 仍保持 Material You 动态取色。
    if (Platform.isWindows) {
      return _buildApp(context);
    }
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => _buildApp(
        context,
        lightDynamic: lightDynamic,
        darkDynamic: darkDynamic,
      ),
    );
  }

  Widget _buildApp(
    BuildContext context, {
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    final themeStore = context.watch<ThemeStore>();
    final useDyn = !Platform.isWindows && themeStore.useDynamic;
    final seedColor = Platform.isWindows ? kDefaultSeed : themeStore.seedColor;
    final light = buildGoalDayTheme(
      dynamicScheme: useDyn ? lightDynamic : null,
      seedColor: seedColor,
      dark: false,
    );
    final dark = buildGoalDayTheme(
      dynamicScheme: useDyn ? darkDynamic : null,
      seedColor: seedColor,
      dark: true,
    );
    final systemDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    final effectiveDark = themeStore.darkMode || systemDark;
    final effectiveTheme = effectiveDark ? dark : light;
    // 启用全局背景时页面骨架转透明，让背景图从卡片缝隙透出；
    // 区块（卡片）以 0.8 底色半透——背景从区块中也透出，
    // 同时保留边框与底色保证区分度和文字可读性。
    final ui = context.watch<UiPrefs>();
    final bgOn =
        ui.bgEnabled && ui.bgPath.isNotEmpty && File(ui.bgPath).existsSync();
    // Windows：窗口是毛玻璃，页面要半透明才能透出材质。
    final glassOn = !bgOn &&
        Platform.isWindows &&
        WindowsShell.instance.glassEnabled.value;
    final displayTheme = (bgOn || glassOn)
        ? effectiveTheme.copyWith(
            scaffoldBackgroundColor: Colors.transparent,
            appBarTheme: effectiveTheme.appBarTheme.copyWith(
              backgroundColor: Colors.transparent,
            ),
            navigationBarTheme: effectiveTheme.navigationBarTheme.copyWith(
              backgroundColor: Colors.transparent,
            ),
            cardTheme: effectiveTheme.cardTheme.copyWith(
              color: effectiveTheme.colorScheme.surfaceContainerLow.withValues(
                alpha: 0.92,
              ),
            ),
          )
        : effectiveTheme;
    // 主题变化后推送标题栏。
    final signature =
        '$effectiveDark|${_argb(effectiveTheme.colorScheme.surface)}'
        '|${_argb(effectiveTheme.colorScheme.onSurface)}';
    if (signature != _lastPushed) {
      _lastPushed = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WindowBridge.setTheme(
          dark: effectiveDark,
          // 开毛玻璃时不写标题栏底色，交给 DWM 与背景混合。
          caption: glassOn ? -1 : _argb(effectiveTheme.colorScheme.surface),
          captionText: _argb(effectiveTheme.colorScheme.onSurface),
        );
      });
    }
    return MaterialApp(
      title: '之计',
      debugShowCheckedModeBanner: false,
      theme: (bgOn || glassOn) ? displayTheme : light,
      darkTheme: (bgOn || glassOn) ? displayTheme : dark,
      themeMode: themeStore.darkMode ? ThemeMode.dark : ThemeMode.system,
      themeAnimationDuration: const Duration(milliseconds: 450),
      themeAnimationCurve: Curves.easeOutCubic,
      builder: (context, child) {
        Widget wrapped = GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: child,
        );
        // 全局自定义背景：底层是页面基础色（图片透明时露出正常
        // 底色而非黑），中间是图片按存储的不透明度直接显示
        // （唯一实现方式，不使用任何蒙版），顶层是页面内容。
        if (glassOn) {
          final base = effectiveTheme.colorScheme.surface;
          wrapped = Stack(
            fit: StackFit.expand,
            children: [
              // 页面底色压一层很薄的雾面：能看见后面的轮廓，又不影响读字。
              ColoredBox(color: base.withValues(alpha: 0.35)),
              wrapped,
            ],
          );
        }
        if (bgOn) {
          final op = ui.bgOpacity.clamp(0.0, 1.0); // 图片不透明度
          wrapped = Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: effectiveTheme.scaffoldBackgroundColor),
              Opacity(
                opacity: op,
                child: Image(
                  image: FileImage(File(ui.bgPath)),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                ),
              ),
              wrapped,
            ],
          );
        }
        return wrapped;
      },
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      scrollBehavior: const GoalDayScrollBehavior(),
      scaffoldMessengerKey: rootMessengerKey,
      navigatorKey: rootNavigatorKey,
      home: const HomeShell(),
    );
  }
}
