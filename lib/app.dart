import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import 'data/store.dart';
import 'desktop/windows_title_bar.dart';
import 'main.dart';
import 'pages/archived_page.dart';
import 'pages/couple_page.dart';
import 'pages/habits_page.dart';
import 'pages/journal_page.dart';
import 'pages/lists_page.dart';
import 'pages/plan_page.dart';
import 'pages/profile_page.dart';
import 'sync/keep_alive.dart';
import 'sync/notify.dart';
import 'sync/sync_service.dart';
import 'theme.dart';
import 'ui/breakpoints.dart';
import 'widgets/responsive.dart';
import 'widgets/update_flow.dart';
import 'widgets/yesterday_dialog.dart';

/// 底部导航壳；情侣页仅绑定后显示。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _pageIndex = 0;

  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // 必须在 initState 构造：late final 惰性字段若无人读取，监听器
    // 整个生命周期都不会注册（onHide 失联 → 退后台闹钟永不挂上）。
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!mounted) return;
        final sync = context.read<SyncService>();
        sync.setForeground(true);
        sync.syncNow(push: sync.autoBackup);
      },
      onHide: () {
        // 切到后台：降低轮询频率。
        if (mounted) context.read<SyncService>().setForeground(false);
      },
    );
    globalRouteHandler = _handleRoute;
    // 冷启动通知点击路由：外壳就绪后补发。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Notify.instance.routePendingLaunch();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      maybeShowYesterdaySuggestion(context, context.read<AppStore>());
      if (Platform.isAndroid || Platform.isWindows) {
        Future.delayed(const Duration(seconds: 4), () {
          if (!mounted) return;
          autoCheckUpdateOnce(context);
        });
      }
    });
    // 首次进入时给一次「隐藏常驻提示」的引导：Android 强制前台服务
    // 必须挂通知，App 自己撤不掉，只能请用户关一次渠道，之后永久干净。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 6), () async {
        if (!mounted) return;
        if (!await KeepAliveBridge.needNoticeHint()) return;
        if (!mounted) return;
        await _showKeepAliveHint();
      });
    });
  }

  /// 一次性引导：把「正在保持连接」那条提示关掉。
  Future<void> _showKeepAliveHint() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('让通知栏保持干净'),
        content: const Text(
          '为了退后台也能即时收到 TA 的消息，App 需要保持一条后台连接，'
          '系统会要求显示一条静默提示。\n\n'
          '点「去隐藏」在系统设置里把它关掉即可，之后通知栏不会再有它，'
          '消息照常即时送达。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('以后再说'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去隐藏'),
          ),
        ],
      ),
    );
    await KeepAliveBridge.markNoticeHintDone();
    if (go == true) {
      await KeepAliveBridge.openChannelSettings();
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    globalRouteHandler = null;
    super.dispose();
  }

  bool _coupleRouteOpen = false;

  void _handleRoute(String route) {
    if (!mounted) return;
    if (route == 'plan') {
      setState(() => _pageIndex = 0);
      return;
    }
    if (route == 'milestone') {
      // 倒数本通知点击切到日子页。
      setState(() => _pageIndex = 2);
      return;
    }
    if (route == 'habits') {
      // 习惯打卡提醒点击切到习惯页。
      setState(() => _pageIndex = 3);
      return;
    }
    if (route == 'archive') {
      // 归档（收藏）通知/横幅点击：打开归档页。
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ArchivedPage()));
      return;
    }
    if (route == 'update-install') {
      // 「更新已就绪」通知点击：直接拉起安装。
      installReadyPackage(context);
      return;
    }
    if (route == 'maintenance') {
      // 每日维护闹钟（Windows 静音通知）：无界面动作。
      return;
    }
    if (route == 'couple_board') {
      // 应用内横幅点击：直达情侣页留言板。
      if (_coupleRouteOpen) return;
      _coupleRouteOpen = true;
      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => const CouplePage(initialTab: 1),
              settings: const RouteSettings(name: 'couple'),
            ),
          )
          .whenComplete(() => _coupleRouteOpen = false);
      return;
    }
    // 已有情侣页在栈上时不重复压栈。
    if (_coupleRouteOpen) {
      return;
    }
    _coupleRouteOpen = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const CouplePage(),
            settings: const RouteSettings(name: 'couple'),
          ),
        )
        .whenComplete(() => _coupleRouteOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final badge = sync.unseenCount + sync.unreadMessages;

    const pages = <Widget>[
      PlanPage(),
      ListsPage(),
      JournalPage(),
      HabitsPage(),
      CouplePage(background: true),
      ProfilePage(),
    ];

    final navItems =
        <({Widget icon, Widget selectedIcon, String label, int pageIndex})>[
          (
            icon: const Icon(Icons.today_outlined),
            selectedIcon: const Icon(Icons.today_rounded),
            label: '计划',
            pageIndex: 0,
          ),
          (
            icon: const Icon(Icons.checklist_outlined),
            selectedIcon: const Icon(Icons.checklist_rounded),
            label: '清单',
            pageIndex: 1,
          ),
          (
            icon: const Icon(Icons.menu_book_outlined),
            selectedIcon: const Icon(Icons.menu_book_rounded),
            label: '日子',
            pageIndex: 2,
          ),
          (
            icon: const Icon(Icons.repeat_outlined),
            selectedIcon: const Icon(Icons.repeat_rounded),
            label: '习惯',
            pageIndex: 3,
          ),
          (
            icon: badge > 0
                ? Badge(
                    label: Text('$badge'),
                    child: const Icon(Icons.person_outline_rounded),
                  )
                : const Icon(Icons.person_outline_rounded) as Widget,
            selectedIcon: const Icon(Icons.person_rounded),
            label: '我的',
            pageIndex: 5,
          ),
        ];

    var selectedIndex = navItems.indexWhere((n) => n.pageIndex == _pageIndex);
    if (selectedIndex < 0) selectedIndex = 0;

    Widget content = IndexedStack(
      index: _pageIndex,
      children: [
        // 页面常驻挂载，保留各页状态。
        for (var i = 0; i < pages.length; i++)
          _AnimatedPage(active: _pageIndex == i, child: pages[i]),
      ],
    );

    void selectPage(int pageIndex) {
      setState(() => _pageIndex = pageIndex);
    }

    Widget shell = SlidableAutoCloseBehavior(
      child: ScrollConfiguration(
        behavior: const GoalDayScrollBehavior(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= Breakpoints.mediumMin;
            if (wide) {
              final extended = constraints.maxWidth >= Breakpoints.expandedMin;
              return Scaffold(
                body: Row(
                  children: [
                    SizedBox(
                      height: constraints.maxHeight,
                      child: NavigationRail(
                        extended: extended,
                        selectedIndex: selectedIndex,
                        onDestinationSelected: (navIdx) =>
                            selectPage(navItems[navIdx].pageIndex),
                        labelType: extended
                            ? NavigationRailLabelType.none
                            : NavigationRailLabelType.all,
                        leading: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Column(
                            children: [
                              const Icon(
                                Icons.favorite_rounded,
                                color: Colors.transparent,
                              ),
                            ],
                          ),
                        ),
                        minExtendedWidth: 168,
                        destinations: [
                          for (final item in navItems)
                            NavigationRailDestination(
                              // 折叠时悬停显示名称。
                              icon: Tooltip(
                                message: item.label,
                                child: item.icon,
                              ),
                              selectedIcon: Tooltip(
                                message: item.label,
                                child: item.selectedIcon,
                              ),
                              label: Text(item.label),
                            ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: Breakpoints.wideContentMaxWidth,
                          ),
                          child: content,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            return Scaffold(
              body: content,
              bottomNavigationBar: NavigationBar(
                selectedIndex: selectedIndex,
                onDestinationSelected: (navIdx) =>
                    selectPage(navItems[navIdx].pageIndex),
                destinations: [
                  for (final item in navItems)
                    NavigationDestination(
                      icon: item.icon,
                      selectedIcon: item.selectedIcon,
                      label: item.label,
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );

    if (!Platform.isWindows) return shell;
    // 顶部 38 是自绘标题栏，原生侧把系统标题栏整个去掉了。
    return Column(
      children: [
        const WindowsTitleBar(),
        Expanded(child: shell),
      ],
    );
  }
}

class _AnimatedPage extends StatefulWidget {
  const _AnimatedPage({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_AnimatedPage> createState() => _AnimatedPageState();
}

class _AnimatedPageState extends State<_AnimatedPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: m3Medium,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _ctrl,
    curve: m3CurveIn,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _ctrl.value = 1; // 首屏不播动画
  }

  @override
  void didUpdateWidget(covariant _AnimatedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _ctrl.forward(from: 0);
    } else if (!widget.active) {
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(_curve),
        child: widget.child,
      ),
    );
  }
}
