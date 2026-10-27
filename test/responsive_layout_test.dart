import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/util/dates.dart';
import 'package:goalday/data/store.dart';
import 'package:goalday/pages/archived_page.dart';
import 'package:goalday/pages/habits_page.dart';
import 'package:goalday/pages/history_page.dart';
import 'package:goalday/pages/journal_page.dart';
import 'package:goalday/pages/lists_page.dart';
import 'package:goalday/pages/plan_page.dart';
import 'package:goalday/sync/sync_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:goalday/pages/profile_page.dart';
import 'package:goalday/theme_store.dart';
import 'package:goalday/ui_prefs.dart';
import 'package:goalday/widgets/m3_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 宽屏布局冒烟：最小窗口 900×640 与常用 1440×900 两档都不允许出现溢出异常。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpAt(WidgetTester tester, Size size, Widget page) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    final uiPrefs = UiPrefs();
    await uiPrefs.load();
    final list = store.addList('读书', '3E6B4F')!;
    store.addListItem(list.id, '书一');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStore>.value(value: store),
          ChangeNotifierProvider<SyncService>.value(value: SyncService(store)),
          ChangeNotifierProvider<UiPrefs>.value(value: uiPrefs),
        ],
        child: MaterialApp(home: page),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
  }

  testWidgets('900×640 与 1440×900 关键页面无溢出', (tester) async {
    const sizes = [Size(900, 640), Size(1440, 900)];
    for (final size in sizes) {
      await pumpAt(tester, size, const PlanPage());
      await pumpAt(tester, size, const ListsPage());
      await pumpAt(tester, size, const JournalPage());
      await pumpAt(tester, size, const HabitsPage());
      await pumpAt(tester, size, const HistoryPage());
      await pumpAt(tester, size, const ArchivedPage());
    }
  });

  testWidgets('清单页 expanded 使用左列表右详情', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    final uiPrefs = UiPrefs();
    await uiPrefs.load();
    final list = store.addList('读书', '3E6B4F')!;
    store.addListItem(list.id, '书一');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStore>.value(value: store),
          ChangeNotifierProvider<SyncService>.value(value: SyncService(store)),
          ChangeNotifierProvider<UiPrefs>.value(value: uiPrefs),
        ],
        child: const MaterialApp(home: ListsPage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('从左侧选择一个清单'), findsOneWidget);
    expect(find.text('读书'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('900×640 清单页保持单列', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    final uiPrefs = UiPrefs();
    await uiPrefs.load();
    final list = store.addList('读书', '3E6B4F')!;
    store.addListItem(list.id, '书一');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStore>.value(value: store),
          ChangeNotifierProvider<SyncService>.value(value: SyncService(store)),
          ChangeNotifierProvider<UiPrefs>.value(value: uiPrefs),
        ],
        child: const MaterialApp(home: ListsPage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('从左侧选择一个清单'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏 AlertDialog 限制最大宽度', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showM3Dialog<void>(
                  context: context,
                  builder: (dialogContext) => const AlertDialog(
                    content: SizedBox(width: 900, height: 120),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byType(AlertDialog));
    expect(size.width, lessThanOrEqualTo(520));
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史/归档 expanded 双栏有数据时不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    final uiPrefs = UiPrefs();
    await uiPrefs.load();
    final yesterday = today().subtract(const Duration(days: 1));
    store.replaceData(
      AppData(
        lists: const [],
        tasks: [
          PlanTask(
            id: 'done-1',
            title: '昨天完成的事',
            date: dateKey(yesterday),
            done: true,
            updatedAt: 1,
          ),
          PlanTask(id: 'arch-1', title: '归档的任务', archived: true, updatedAt: 2),
        ],
        habits: const [],
        journal: const {},
      ),
    );

    Future<void> pumpPage(Widget page) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppStore>.value(value: store),
            ChangeNotifierProvider<SyncService>.value(
              value: SyncService(store),
            ),
            ChangeNotifierProvider<UiPrefs>.value(value: uiPrefs),
          ],
          child: MaterialApp(home: page),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
    }

    await pumpPage(const HistoryPage());
    expect(find.text('昨天完成的事'), findsWidgets);
    expect(find.textContaining('完成 1 项'), findsWidgets);

    await pumpPage(const ArchivedPage());
    expect(find.text('归档的任务'), findsWidgets);
    expect(find.text('彻底删除'), findsOneWidget);
  });

  testWidgets('1440 宽屏列表弹层变成居中 Dialog', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    final uiPrefs = UiPrefs();
    await uiPrefs.load();
    final list = store.addList('读书', '3E6B4F')!;
    store.addListItem(list.id, '书一');
    final itemId = store.listById(list.id)!.items.single.id;
    store.deleteListItem(list.id, itemId);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStore>.value(value: store),
          ChangeNotifierProvider<SyncService>.value(value: SyncService(store)),
          ChangeNotifierProvider<UiPrefs>.value(value: uiPrefs),
        ],
        child: const MaterialApp(home: ListsPage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byIcon(Icons.restore_from_trash_rounded));
    await tester.pumpAndSettle();
    expect(find.text('回收站'), findsOneWidget);
    expect(find.byType(Dialog), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 设置页 900×640 显示桌面项、隐藏 Android 项', (tester) async {
    if (!Platform.isWindows) return;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    PackageInfo.setMockInitialValues(
      appName: '之计',
      packageName: 'com.huaxu.judging',
      version: '5.16.15',
      buildNumber: '123',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    final uiPrefs = UiPrefs();
    await uiPrefs.load();
    final themeStore = ThemeStore();
    await themeStore.load();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStore>.value(value: store),
          ChangeNotifierProvider<SyncService>.value(value: SyncService(store)),
          ChangeNotifierProvider<UiPrefs>.value(value: uiPrefs),
          ChangeNotifierProvider<ThemeStore>.value(value: themeStore),
        ],
        child: const MaterialApp(home: ProfilePage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('开机自动启动'), findsOneWidget);
    expect(find.text('关闭窗口时最小化到托盘'), findsOneWidget);
    expect(find.text('后台保持连接'), findsNothing);
    expect(find.text('开启通知'), findsNothing);
    expect(find.text('跟随系统取色'), findsNothing);
    expect(find.text('主题颜色'), findsNothing);
  });
}
