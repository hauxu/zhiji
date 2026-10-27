// 情侣概览「纪念日」卡：不同来源（自己添加 / TA 添加）的行，右侧天数右缘必须齐平。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/data/store.dart';
import 'package:goalday/pages/couple_page.dart';
import 'package:goalday/sync/couple_models.dart';
import 'package:goalday/sync/sync_service.dart';
import 'package:goalday/ui_prefs.dart';
import 'package:goalday/util/dates.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Milestone _m(String id, String title, int daysAhead) => Milestone(
      id: id,
      title: title,
      date: dateKey(today().add(Duration(days: daysAhead))),
    );

Widget _wrap(AppStore store, SyncService sync) =>
    ChangeNotifierProvider<UiPrefs>.value(
      value: UiPrefs(),
      child: MaterialApp(
        home: Scaffold(body: AnniversaryCard(store: store, sync: sync)),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('纪念日行右侧天数右缘齐平（含 TA 添加的条目）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    store.data.milestones.addAll([
      _m('a', '出发', 10),
      _m('b', '在一起啦', 20),
    ]);
    final sync = SyncService(store)
      ..partnerName = '皇帝'
      ..partner = PartnerData(
        accountId: 'p1',
        name: '皇帝',
        data: AppData(
          lists: <TaskList>[],
          tasks: <PlanTask>[],
          habits: <Habit>[],
          journal: <String, JournalEntry>{},
          milestones: [_m('c', '相识', 30)],
        ),
        updatedAt: 1,
      );

    await tester.pumpWidget(_wrap(store, sync));
    await tester.pumpAndSettle();

    final units = find.text('天后');
    expect(units, findsNWidgets(3));
    final rights = [
      for (var i = 0; i < 3; i++) tester.getRect(units.at(i)).right,
    ];
    // 三行右缘一致：此前 TA 行少了尾部间距，会整体右移 8dp。
    expect(rights[1], rights[0]);
    expect(rights[2], rights[1]);
  });

  testWidgets('纪念日行：图标、文字块、天数在同一垂直中线', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    store.data.milestones.addAll([_m('a', '出发', 10), _m('b', '在一起啦', 20)]);
    final sync = SyncService(store)
      ..partnerName = '皇帝'
      ..partner = PartnerData(
        accountId: 'p1',
        name: '皇帝',
        data: AppData(
          lists: <TaskList>[],
          tasks: <PlanTask>[],
          habits: <Habit>[],
          journal: <String, JournalEntry>{},
          milestones: [_m('c', '相识', 30)],
        ),
        updatedAt: 1,
      );
    await tester.pumpWidget(_wrap(store, sync));
    await tester.pumpAndSettle();
    for (final id in ['a', 'b', 'c']) {
      final icon = tester.getCenter(find.byKey(ValueKey('ms-icon-$id')));
      final text = tester.getCenter(find.byKey(ValueKey('ms-text-$id')));
      final days = tester.getCenter(find.byKey(ValueKey('ms-days-$id')));
      expect((icon.dy - days.dy).abs(), lessThan(0.6), reason: '图标 vs 天数 $id');
      expect((text.dy - days.dy).abs(), lessThan(0.6), reason: '文字 vs 天数 $id');
    }
  });
}