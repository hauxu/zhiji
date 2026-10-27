// 热力图与记录联动：点格子显示日期状态、点记录行高亮对应格子。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/pages/habit_detail_page.dart';
import 'package:goalday/util/dates.dart';

Habit _habit() {
  final now = today();
  String dk(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final records = <String, HabitStatus>{
    dk(now): HabitStatus.done,
    dk(now.subtract(const Duration(days: 1))): HabitStatus.done,
    dk(now.subtract(const Duration(days: 3))): HabitStatus.miss,
    dk(now.subtract(const Duration(days: 10))): HabitStatus.done,
  };
  return Habit(id: 'h1', name: '晨间阅读', color: '3E6B4F', records: records);
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点热力图格子显示「日期 · 已打卡」，再点收起', (tester) async {
    final habit = _habit();
    await tester.pumpWidget(_wrap(HabitDetailPage(habit: habit)));
    await tester.pumpAndSettle();

    // 未选中时头部是「近一年 · 点格子看日期」。
    expect(find.text('近一年 · 点格子看日期'), findsOneWidget);
    expect(find.text('今天 · 已打卡'), findsNothing);

    // 滚到「全部记录」卡（主 ListView 是最后一个 Scrollable），
    // 点今天的记录行 → 头部显示日期与状态。
    await tester.scrollUntilVisible(
      find.text('全部记录（4）'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    // 记录行的「今天」在树后（热力图 footer 的「今天」在前）。
    final rows = find.text('今天');
    await tester.tap(rows.last);
    await tester.pumpAndSettle();
    expect(find.text('今天 · 已打卡'), findsOneWidget);

    // 点关闭按钮收起。
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('近一年 · 点格子看日期'), findsOneWidget);
  });

  testWidgets('记录行选中态传给热力图（selected 同步）', (tester) async {
    final habit = _habit();
    await tester.pumpWidget(_wrap(HabitDetailPage(habit: habit)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('全部记录（4）'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    // 点昨天的行（倒序第二行）。
    await tester.tap(find.text('昨天'));
    await tester.pumpAndSettle();
    expect(find.text('昨天 · 已打卡'), findsOneWidget);
  });

  testWidgets('错过行显示对应状态', (tester) async {
    final habit = _habit();
    await tester.pumpWidget(_wrap(HabitDetailPage(habit: habit)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('全部记录（4）'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    // 3 天前是 miss。
    await tester.tap(find.text('错过'));
    await tester.pumpAndSettle();
    expect(find.textContaining('错过'), findsWidgets);
  });
}
