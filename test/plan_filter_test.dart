// 计划筛选入口与数据体积报告：这两条是崩溃/回退高发点，补回归测试。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/data/store.dart';
import 'package:goalday/pages/plan_page.dart';
import 'package:goalday/sync/couple_models.dart';
import 'package:goalday/sync/sync_service.dart';
import 'package:goalday/ui_prefs.dart';
import 'package:goalday/util/dates.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(AppStore store, SyncService sync, Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider<UiPrefs>.value(value: UiPrefs()),
        ChangeNotifierProvider<AppStore>.value(value: store),
        ChangeNotifierProvider<SyncService>.value(value: sync),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

Future<(AppStore, SyncService)> _setup({required bool bound}) async {
  SharedPreferences.setMockInitialValues({});
  final store = AppStore();
  await store.load();
  final sync = SyncService(store);
  if (bound) {
    sync
      ..token = 't'
      ..accountId = 'a' * 32
      ..roomId = 'r'
      ..status = CoupleStatus.bound
      ..partnerName = '小乙'
      ..partner = PartnerData(
        accountId: 'b' * 32,
        name: '小乙',
        data: AppData(
          lists: <TaskList>[],
          tasks: <PlanTask>[],
          habits: <Habit>[],
          journal: <String, JournalEntry>{},
          milestones: <Milestone>[],
        ),
        updatedAt: 1,
      );
  }
  return (store, sync);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('未绑定时不显示计划筛选入口', (tester) async {
    final (store, sync) = await _setup(bound: false);
    await tester.pumpWidget(_wrap(
      store,
      sync,
      DayTaskSection(
        date: today(),
        filter: PlanFilter.all,
        onFilterChanged: (_) {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('全部'), findsNothing);
  });

  testWidgets('绑定后筛选入口常驻，切到「对方」能回调', (tester) async {
    final (store, sync) = await _setup(bound: true);
    var selected = PlanFilter.all;
    await tester.pumpWidget(_wrap(
      store,
      sync,
      StatefulBuilder(
        builder: (context, setState) => DayTaskSection(
          date: today(),
          filter: selected,
          onFilterChanged: (f) => setState(() => selected = f),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('全部'), findsOneWidget);

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('对方（小乙）'));
    await tester.pumpAndSettle();
    expect(selected, PlanFilter.ta);
    // 选「对方」后筛选入口仍在（曾经的死锁场景）。
    expect(find.text('小乙'), findsOneWidget);
  });

  test('数据体积报告包含分类且合计等于各项之和', () async {
    final (_, sync) = await _setup(bound: false);
    final report = await sync.snapshotSizeReport();
    expect(report.keys, containsAll([
      '任务与清单',
      '习惯',
      '日记',
      '其它（纪念日/回收站/墓碑等）',
      '合计',
    ]));
    final sum = report.entries
        .where((e) => e.key != '合计')
        .fold<int>(0, (acc, e) => acc + e.value);
    expect(report['合计'], sum);
    expect(report['合计'], greaterThanOrEqualTo(0));
  });
}