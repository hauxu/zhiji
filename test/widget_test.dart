import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/crypto/journal_crypto.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/data/seed.dart';
import 'package:goalday/data/store.dart';
import 'package:goalday/pages/lists_page.dart';
import 'package:goalday/sync/api.dart';
import 'package:goalday/sync/sync_service.dart';
import 'package:lunar/lunar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('compareManualSort', () {
    test('两者都有手动序时按值升序', () {
      expect(AppStore.compareManualSort(10, 20), -1);
      expect(AppStore.compareManualSort(20, 10), 1);
      expect(AppStore.compareManualSort(15, 15), 0);
    });

    test('负值手动序有效且排在最前', () {
      expect(AppStore.compareManualSort(-5, 10), -1);
      expect(AppStore.compareManualSort(0, -5), 1);
    });

    test('一方未排序时排过序的在前', () {
      expect(AppStore.compareManualSort(10, 0), -1);
      expect(AppStore.compareManualSort(0, 10), 1);
    });

    test('双方都未排序返回 null', () {
      expect(AppStore.compareManualSort(0, 0), isNull);
    });
  });

  group('addTask 顶部插入', () {
    test('无手动序时新任务 sort 为 0', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final t = store.addTask(title: '任务一');
      expect(t.sort, 0);
    });

    test('组内最小手动序为 1 时不产生 0 值碰撞', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final first = store.addTask(title: '已有任务');
      first.sort = 1; // 最小值为 1 的存量数据
      store.notifyDataChangedExternally();

      final fresh = store.addTask(title: '新任务');
      expect(fresh.sort, 10);
      expect(first.sort, 20);
      expect(store.weekTasks().map((t) => t.title).first, '新任务');
    });

    test('正常手动序下新任务取组内最小值减一', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final a = store.addTask(title: '甲');
      a.sort = 30;
      final b = store.addTask(title: '乙');
      b.sort = 10;
      store.notifyDataChangedExternally();

      final fresh = store.addTask(title: '新任务');
      expect(fresh.sort, 9);
      expect(store.weekTasks().first.title, '新任务');
    });
  });

  group('数据往返', () {
    test('AppData encode/decode 保持任务字段', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final t = store.addTask(
        title: '往返任务',
        date: '2026-09-29',
        start: '09:00',
        end: '10:00',
        remindBefore: 15,
      );
      t.sort = 7;
      final decoded = AppData.decode(store.data.encode());
      final back = decoded.tasks.firstWhere((x) => x.id == t.id);
      expect(back.title, '往返任务');
      expect(back.date, '2026-09-29');
      expect(back.start, '09:00');
      expect(back.end, '10:00');
      expect(back.remindBefore, 15);
      expect(back.sort, 7);
    });

    test('每周重复未选星期降级为不重复', () {
      final t = PlanTask(
        id: 't1',
        title: '降级',
        repeatMode: TaskRepeatMode.weekly,
        repeatWeekdays: const [],
      );
      final decoded = AppData.decode(AppData(
        lists: const [],
        tasks: [t],
        habits: const [],
        journal: const {},
      ).encode());
      expect(decoded.tasks.first.repeatMode, TaskRepeatMode.none);
    });
  });

  group('Milestone 日期推算', () {
    test('不重复未来日期倒数', () {
      final m = Milestone(id: 'm1', title: '婚礼', date: '2026-10-05');
      final from = DateTime(2026, 9, 30);
      expect(m.daysUntil(from), 5);
      expect(m.daysLabel(from), '还有 5 天');
      expect(m.isPast(from), isFalse);
    });

    test('当天为零、已过为负', () {
      final m = Milestone(id: 'm1', title: '出发', date: '2026-10-02');
      expect(m.daysLabel(DateTime(2026, 10, 2)), '今天');
      expect(m.daysLabel(DateTime(2026, 10, 10)), '已过 8 天');
      expect(m.isPast(DateTime(2026, 10, 10)), isTrue);
    });

    test('每年重复跨年推到下一次周年', () {
      final m =
          Milestone(id: 'm2', title: '恋爱纪念日', date: '2023-06-01', yearly: true);
      // 2026-06-01 的三周年已过，下一次是 2027 年的四周年。
      expect(m.daysLabel(DateTime(2026, 9, 30)), '4 周年 · 还有 244 天');
      expect(m.daysLabel(DateTime(2026, 6, 1)), '3 周年');
      expect(m.daysLabel(DateTime(2026, 5, 30)), '3 周年 · 还有 2 天');
      // 当年首次发生前只显示剩余天数。
      expect(
          m.daysLabel(DateTime(2023, 5, 30)), '还有 2 天');
      expect(m.isPast(DateTime(2026, 9, 30)), isFalse);
    });

    test('occursOnDate 匹配当年与周年', () {
      final m = Milestone(id: 'm3', title: '生日', date: '2020-03-15', yearly: true);
      expect(m.occursOnDate(DateTime(2026, 3, 15)), isTrue);
      expect(m.occursOnDate(DateTime(2026, 3, 16)), isFalse);
      final once = Milestone(id: 'm4', title: '一次性', date: '2026-03-15');
      expect(once.occursOnDate(DateTime(2027, 3, 15)), isFalse);
    });

    test('排序：置顶优先，upcoming 按远近，已过按最近在前', () {
      final from = DateTime(2026, 9, 30);
      final past = Milestone(id: 'a', title: '已过', date: '2026-08-01');
      const recentPast = '2026-09-20';
      final past2 = Milestone(id: 'b', title: '刚过', date: recentPast);
      final soon = Milestone(id: 'c', title: '将到', date: '2026-10-03');
      final far = Milestone(id: 'd', title: '尚远', date: '2026-12-01');
      final pinned = Milestone(id: 'e', title: '置顶', date: '2026-12-10',
          pinned: true);
      final all = [far, past, pinned, past2, soon]..sort(
          (x, y) => Milestone.compare(x, y, from));
      expect(all.map((m) => m.id).toList(), ['e', 'c', 'd', 'b', 'a']);
    });

    test('AppData 序列化往返保留倒数本', () {
      final m = Milestone(
        id: 'm9',
        title: '领证',
        date: '2024-05-20',
        yearly: true,
        pinned: true,
        color: 'C9A227',
        icon: 'diamond',
        reminds: [0, 3],
        lunar: true,
        lunarMonth: 8,
        lunarDay: 15,
        lunarLeap: false,
      );
      final decoded = AppData.decode(AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: const {},
        milestones: [m],
      ).encode());
      final back = decoded.milestones.single;
      expect(back.title, '领证');
      expect(back.date, '2024-05-20');
      expect(back.yearly, isTrue);
      expect(back.pinned, isTrue);
      expect(back.color, 'C9A227');
      expect(back.icon, 'diamond');
      expect(back.reminds, [0, 3]);
      expect(back.lunar, isTrue);
      expect(back.lunarMonth, 8);
      expect(back.lunarDay, 15);
      expect(back.lunarLeap, isFalse);
      expect(back.featured, isTrue);
      expect(back.lunarLabel(), '八月十五');
      // 兼容旧客户端的单值：含当天时取 0。
      expect(jsonDecode(jsonEncode(back.toJson()))['remindDays'], 0);
    });

    test('旧 remindDays 单值迁移为集合', () {
      final late = Milestone.fromJson(
          {'id': 'a', 'title': 'x', 'date': '2026-01-01', 'remindDays': 3});
      expect(late.reminds, [3]);
      final onDay = Milestone.fromJson(
          {'id': 'b', 'title': 'x', 'date': '2026-01-01', 'remindDays': 0});
      expect(onDay.reminds, [0]);
      final off = Milestone.fromJson(
          {'id': 'c', 'title': 'x', 'date': '2026-01-01', 'remindDays': -1});
      expect(off.reminds, isEmpty);
      expect(off.remindLabel, '不提醒');
    });

    test('featured 默认开启，可关闭并往返保留', () {
      final m = Milestone.fromJson(
          {'id': 'f1', 'title': 'x', 'date': '2026-01-01'});
      expect(m.featured, isTrue);
      final off = Milestone.fromJson(
          {'id': 'f2', 'title': 'x', 'date': '2026-01-01', 'featured': false});
      final decoded = AppData.decode(AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: const {},
        milestones: [off],
      ).encode());
      expect(decoded.milestones.single.featured, isFalse);
    });

    test('农历换算：春节、中秋与闰月', () {
      expect(lunarToSolar(2026, 1, 1, false), DateTime.utc(2026, 2, 17));
      expect(lunarToSolar(2025, 1, 1, false), DateTime.utc(2025, 1, 29));
      expect(lunarToSolar(2026, 8, 15, false), DateTime.utc(2026, 9, 25));
      expect(lunarToSolar(2027, 8, 15, false), DateTime.utc(2027, 9, 15));
      // 2025 有闰六月：闰六月初三 = 7 月 27 日。
      expect(lunarToSolar(2025, 6, 3, true), DateTime.utc(2025, 7, 27));
      // 2026 无闰六月：回退平六月初三。
      final fallback = lunarToSolar(2026, 6, 3, true);
      final lu = Lunar.fromDate(DateTime(fallback.year, fallback.month,
          fallback.day));
      expect(lu.getMonth(), 6);
      // 日超出月长截到月末仍在同月。
      final clamped = lunarToSolar(2025, 6, 3, false);
      expect(clamped.month, 6);
    });

    test('农历倒数日推算下一次周年', () {
      final m = Milestone(
        id: 'mL',
        title: '奶奶生日',
        date: '2026-09-25',
        yearly: true,
        lunar: true,
        lunarMonth: 8,
        lunarDay: 15,
      );
      final next = m.nextOccurrence(DateTime(2026, 9, 30));
      expect(next, DateTime.utc(2027, 9, 15));
      expect(m.occursOnDate(DateTime(2026, 9, 25)), isTrue);
      expect(m.occursOnDate(DateTime(2026, 9, 26)), isFalse);
      expect(m.occursOnDate(DateTime(2027, 9, 15)), isTrue);
    });

    test('旧快照无 milestones 键时解析为空表', () {
      final decoded = AppData.decode(
          '{"lists":[],"tasks":[],"habits":[],"journal":{}}');
      expect(decoded.milestones, isEmpty);
    });
  });

  group('时间日期排序', () {
    test('清单条目：手动序优先，其余有日期按日期升序排前', () {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      store.replaceData(AppData(
        lists: [TaskList(id: 'l1', name: '测试', color: '3E6B4F', items: [
          ListItem(id: 'a', title: '无日期旧', sort: 0),          // 插入序 0
          ListItem(id: 'b', title: '日期晚', sort: 0, date: '2026-05-01'),
          ListItem(id: 'c', title: '手动', sort: 10),
          ListItem(id: 'd', title: '日期早', sort: 0, date: '2026-01-01'),
        ])],
        tasks: const [],
        habits: const [],
        journal: const {},
      ));
      final items = store.undoneOf(store.listById('l1'));
      expect(items.map((e) => e.id).toList(), ['c', 'd', 'b', 'a']);
    });

    test('习惯显示序：手动序优先，其余有时间按时间排前', () {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      store.replaceData(AppData(
        lists: const [],
        tasks: const [],
        habits: [
          Habit(id: 'h1', name: '无时间', color: '3E6B4F', records: {}),
          Habit(id: 'h2', name: '晚上', color: '3E6B4F', records: {}, time: '21:30'),
          Habit(id: 'h3', name: '手动', color: '3E6B4F', records: {}, sort: 10),
          Habit(id: 'h4', name: '早晨', color: '3E6B4F', records: {}, time: '06:30'),
        ],
        journal: const {},
      ));
      expect(store.habitsDisplay().map((e) => e.id).toList(),
          ['h3', 'h4', 'h2', 'h1']);
    });

    test('习惯拖动在显示序上换位（时间排序场景）', () {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      store.replaceData(AppData(
        lists: const [],
        tasks: const [],
        habits: [
          Habit(id: 'a', name: '早晨', color: '3E6B4F', records: {}, time: '06:30'),
          Habit(id: 'b', name: '晚上', color: '3E6B4F', records: {}, time: '21:30'),
          Habit(id: 'c', name: '无时间', color: '3E6B4F', records: {}),
        ],
        journal: const {},
      ));
      // 显示序 = a(早) b(晚) c(无)。把显示序第 2 项（b）拖到第 0 位。
      store.reorderHabit(1, 0);
      expect(store.habitsDisplay().map((h) => h.id).toList(),
          ['b', 'a', 'c']);
      // 新习惯加入仍置顶（有手动序）。
      store.addHabit('新习惯', '3E6B4F');
      expect(store.habitsDisplay().first.name, '新习惯');
    });

    test('Habit.time 与 ListItem.date 序列化往返', () {
      final decoded = AppData.decode(AppData(
        lists: [TaskList(id: 'l', name: 'x', color: '3E6B4F', items: [
          ListItem(id: 'i', title: 't', date: '2026-03-01'),
        ])],
        tasks: const [],
        habits: [Habit(id: 'h', name: 'n', color: '3E6B4F', records: {}, time: '07:00')],
        journal: const {},
      ).encode());
      expect(decoded.lists.single.items.single.date, '2026-03-01');
      expect(decoded.habits.single.time, '07:00');
      // 旧快照缺字段时为空串。
      final legacy = AppData.decode(
          '{"lists":[{"id":"l","name":"x","color":"3E6B4F","items":[{"id":"i","title":"t"}]}],'
          '"tasks":[],"habits":[{"id":"h","name":"n","color":"3E6B4F","records":{}}],"journal":{}}');
      expect(legacy.lists.single.items.single.date, '');
      expect(legacy.habits.single.time, '');
    });
  });

  group('心情与清单共享', () {
    test('新增四种心情解析与往返', () {
      for (final name in ['energetic', 'focused', 'moved', 'gloomy']) {
        final m = moodFromString(name);
        expect(m, isNotNull);
        expect(moodToString(m), name);
      }
      expect(moodFromString('未知值'), isNull);
      expect(Mood.values.length, 12);
    });

    test('TaskList.shared 往返，缺键按隐私默认不共享', () {
      final decoded = AppData.decode(AppData(
        lists: [TaskList(id: 'l', name: 'x', color: '3E6B4F', shared: true)],
        tasks: const [],
        habits: const [],
        journal: const {},
      ).encode());
      expect(decoded.lists.single.shared, isTrue);
      final legacy = AppData.decode(
          '{"lists":[{"id":"l","name":"x","color":"3E6B4F","items":[]}],'
          '"tasks":[],"habits":[],"journal":{}}');
      expect(legacy.lists.single.shared, isFalse);
    });
  });

  group('倒数日进阶设置', () {
    test('正数包含起始日（+1 天）', () {
      final m = Milestone(id: 'p1', title: 'x', date: '2026-10-02');
      expect(m.daysLabel(DateTime(2026, 10, 10)), '已过 8 天');
      final p1 = Milestone(
          id: 'p2', title: 'x', date: '2026-10-02', plusOne: true);
      expect(p1.daysLabel(DateTime(2026, 10, 10)), '已过 9 天');
    });

    test('周/月循环推算与旧数据迁移', () {
      final wk = Milestone(id: 'w', title: '发周报', date: '2026-10-01',
          repeat: 'week'); // 2026-10-01 是周四
      final from = DateTime(2026, 10, 4); // 周日
      expect(wk.nextOccurrence(from), DateTime.utc(2026, 10, 8)); // 下个周四
      expect(wk.occursOnDate(DateTime(2026, 10, 8)), isTrue);
      expect(wk.occursOnDate(DateTime(2026, 10, 9)), isFalse);
      expect(wk.daysLabel(from).contains('还有'), isTrue);
      expect(wk.repeatLabel, '每周');

      final mo = Milestone(id: 'm', title: '发工资', date: '2026-01-31',
          repeat: 'month');
      // 1/31 → 2 月按月末 2/28 算。
      expect(mo.nextOccurrence(DateTime(2026, 2, 1)),
          DateTime.utc(2026, 2, 28));
      expect(mo.occursOnDate(DateTime(2026, 4, 30)), isTrue); // 4 月末
    });

    test('旧 yearly=true 迁移为 repeat=year，双写兼容', () {
      final m = Milestone.fromJson(
          {'id': 'a', 'title': 'x', 'date': '2026-01-01', 'yearly': true});
      expect(m.repeat, 'year');
      expect(m.yearly, isTrue);
      final out = AppData.decode(AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: const {},
        milestones: [m],
      ).encode());
      final back = out.milestones.single;
      expect(back.repeat, 'year');
      expect(back.toJson()['yearly'], true);
      final legacy = Milestone.fromJson(
          {'id': 'b', 'title': 'x', 'date': '2026-01-01'});
      expect(legacy.repeat, 'none');
    });

    test('plusOne/highlight 序列化往返，旧快照缺键默认关', () {
      final decoded = AppData.decode(AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: const {},
        milestones: [
          Milestone(id: 'h1', title: 'x', date: '2026-01-01',
              plusOne: true, highlight: true),
        ],
      ).encode());
      final back = decoded.milestones.single;
      expect(back.plusOne, isTrue);
      expect(back.highlight, isTrue);
      final legacy = Milestone.fromJson(
          {'id': 'l', 'title': 'x', 'date': '2026-01-01'});
      expect(legacy.plusOne, isFalse);
      expect(legacy.highlight, isFalse);
    });
  });

  group('清单回收站', () {
    test('未分类删除入回收站、恢复置顶、上限 30（旧入口保持可用）', () {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      store.replaceData(AppData(
        lists: [
          TaskList(
              id: AppStore.unfiledListId,
              name: '未分类',
              color: '3E6B4F',
              items: [
                ListItem(id: 'u1', title: '条目一'),
                ListItem(id: 'u2', title: '条目二'),
              ]),
        ],
        tasks: const [],
        habits: const [],
        journal: const {},
      ));
      store.deleteListItem(AppStore.unfiledListId, 'u1');
      expect(store.data.trash.single.item.id, 'u1');
      expect(store.data.trash.single.listId, AppStore.unfiledListId);
      expect(store.data.trash.single.deletedAt, greaterThan(0));
      // 兼容包装：旧调用仍可恢复未分类条目。
      expect(store.restoreUnfiledItem('u1'), isTrue);
      expect(store.data.trash, isEmpty);
      expect(store.unfiled!.items.first.id, 'u1');
      // 上限：灌 31 条验证 FIFO 只留最近 30 条。
      for (var i = 0; i < 31; i++) {
        store.addListItem(AppStore.unfiledListId, '临时$i');
        final it = store.unfiled!.items.first;
        store.deleteListItem(AppStore.unfiledListId, it.id);
      }
      expect(store.data.trash.length, 30);
      expect(store.restoreUnfiledItem('不存在'), isFalse);
    });

    test('从普通清单删除后能恢复到原清单（内容保留、重置完成态）', () {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      store.replaceData(AppData(
        lists: [
          TaskList(
            id: 'l1',
            name: '读书',
            color: '3E6B4F',
            items: [
              ListItem(
                id: 'i1',
                title: '书一',
                note: '备注',
                attached: const ['a.png'],
                date: '2026-11-01',
              ),
              ListItem(id: 'i2', title: '书二', done: true),
            ],
          ),
        ],
        tasks: const [],
        habits: const [],
        journal: const {},
      ));
      store.deleteListItem('l1', 'i1');
      expect(store.listById('l1')!.items.map((i) => i.id), ['i2']);
      expect(store.data.trash.single.listId, 'l1');
      expect(store.restoreTrashEntry('i1'), isTrue);
      final restored = store.listById('l1')!.items.first;
      expect(restored.id, 'i1');
      expect(restored.title, '书一');
      expect(restored.note, '备注');
      expect(restored.attached, ['a.png']);
      expect(restored.date, '2026-11-01');
      expect(restored.done, isFalse);
      expect(store.data.trash, isEmpty);
      // 原清单已被删除：恢复回退到未分类。
      store.deleteListItem('l1', 'i2');
      store.deleteList('l1');
      expect(store.restoreTrashEntry('i2'), isTrue);
      expect(store.unfiled!.items.single.id, 'i2');
      // 回退恢复不应留下删除墓碑（否则下一轮合并会把条目再删掉）。
      expect(store.tombstones.containsKey('i2'), isFalse);
    });

    test('超过 30 天的条目清理掉，deletedAt=0 的旧数据不过期', () {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      store.replaceData(AppData(
        lists: <TaskList>[],
        tasks: const [],
        habits: const [],
        journal: const {},
        trash: [
          TrashEntry(
            listId: AppStore.unfiledListId,
            item: ListItem(id: 'old', title: '过期'),
            deletedAt: now - 31 * 86400000,
          ),
          TrashEntry(
            listId: AppStore.unfiledListId,
            item: ListItem(id: 'fresh', title: '新删'),
            deletedAt: now - 2 * 86400000,
          ),
          TrashEntry(
            listId: AppStore.unfiledListId,
            item: ListItem(id: 'legacy', title: '旧快照'),
          ),
        ],
      ));
      // replaceData 与每次变更后都会自动清理；显式 purge 保持幂等。
      store.purgeTrash();
      expect(
        store.data.trash.map((t) => t.item.id).toSet(),
        {'fresh', 'legacy'},
      );
      expect(store.restoreTrashEntry('legacy'), isTrue);
      expect(store.unfiled!.items.single.id, 'legacy');
    });

    test('trash 序列化往返，旧快照 unfiledTrash 迁移入回收站', () {
      final encoded = AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: const {},
        trash: [
          TrashEntry(
            listId: 'l1',
            item: ListItem(id: 't', title: '回收'),
            deletedAt: 12345,
          ),
        ],
      ).encode();
      final decoded = AppData.decode(encoded);
      expect(decoded.trash.single.item.title, '回收');
      expect(decoded.trash.single.listId, 'l1');
      expect(decoded.trash.single.deletedAt, 12345);
      // 只写新字段，旧客户端读到未知键忽略即可。
      final raw = jsonDecode(encoded) as Map<String, dynamic>;
      expect(raw.containsKey('unfiledTrash'), isFalse);
      expect(raw['trash'], isNotEmpty);

      final legacy = AppData.decode(
        '{"lists":[],"tasks":[],"habits":[],"journal":{},'
        '"unfiledTrash":[{"id":"old","title":"旧回收"}]}',
      );
      expect(legacy.trash.single.item.id, 'old');
      expect(legacy.trash.single.item.title, '旧回收');
      expect(legacy.trash.single.listId, AppStore.unfiledListId);
      expect(legacy.trash.single.deletedAt, 0);
      expect(
        AppData.decode('{"lists":[],"tasks":[],"habits":[],"journal":{}}')
            .trash,
        isEmpty,
      );
    });

    test('回收站按 item.id 并集合并，删除时间新者胜', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final mine = AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: const {},
        trash: [
          TrashEntry(
            listId: 'l1',
            item: ListItem(id: 'x', title: '旧删'),
            deletedAt: now - 2000,
          ),
        ],
      );
      final theirs = AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: const {},
        trash: [
          TrashEntry(
            listId: 'l2',
            item: ListItem(id: 'x', title: '新删', note: '对方'),
            deletedAt: now - 1000,
          ),
          TrashEntry(
            listId: 'l1',
            item: ListItem(id: 'y', title: '对方删的'),
            deletedAt: now - 1500,
          ),
        ],
      );
      final (m, _) = AppStore.mergeAppData(
        mine: mine,
        theirs: theirs,
        myTombs: {},
        theirTombs: {},
      );
      expect(m.trash.length, 2);
      final x = m.trash.firstWhere((t) => t.item.id == 'x');
      expect(x.deletedAt, now - 1000);
      expect(x.listId, 'l2');
      expect(x.item.title, '新删');
      expect(m.trash.map((t) => t.item.id).toSet(), {'x', 'y'});
    });

    test('合并时回收站条目从列表移除，恢复后重新回到列表', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      ListItem stale() => ListItem(id: 'i1', title: '书一', updatedAt: now - 5000);
      TaskList list([List<ListItem> items = const []]) =>
          TaskList(id: 'l1', name: '读书', color: '3E6B4F', items: items.toList());

      // 本机已删（在回收站），对方列表里还在：删除方胜出。
      final mineDeleted = AppData(
        lists: [list()],
        tasks: const [],
        habits: const [],
        journal: const {},
        trash: [
          TrashEntry(listId: 'l1', item: stale(), deletedAt: now),
        ],
      );
      final theirsAlive = AppData(
        lists: [list([stale()])],
        tasks: const [],
        habits: const [],
        journal: const {},
      );
      final (m, _) = AppStore.mergeAppData(
        mine: mineDeleted,
        theirs: theirsAlive,
        myTombs: {},
        theirTombs: {},
      );
      expect(m.lists.single.items, isEmpty);
      expect(m.trash.single.item.id, 'i1');

      // 本机已恢复（updatedAt 更新），对方回收站还留着旧条目：恢复方胜出。
      final restoredItem = ListItem(
        id: 'i1',
        title: '书一',
        updatedAt: now + 1000,
      );
      final mineRestored = AppData(
        lists: [list([restoredItem])],
        tasks: const [],
        habits: const [],
        journal: const {},
      );
      final theirsStale = AppData(
        lists: [list()],
        tasks: const [],
        habits: const [],
        journal: const {},
        trash: [
          TrashEntry(listId: 'l1', item: stale(), deletedAt: now),
        ],
      );
      final (m2, _) = AppStore.mergeAppData(
        mine: mineRestored,
        theirs: theirsStale,
        myTombs: {},
        theirTombs: {},
      );
      expect(m2.lists.single.items.single.id, 'i1');
      expect(m2.trash, isEmpty);
    });

    testWidgets('清单页回收站按钮带角标，弹层可恢复条目', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final list = store.addList('读书', '3E6B4F')!;
      store.addListItem(list.id, '书一');
      final itemId = store.listById(list.id)!.items.single.id;
      store.deleteListItem(list.id, itemId);

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStore>.value(value: store),
          ChangeNotifierProvider<SyncService>.value(value: SyncService(store)),
        ],
        child: const MaterialApp(home: ListsPage()),
      ));
      await tester.pumpAndSettle();

      // 非空回收站：AppBar 按钮换成回收站图标并带数量角标。
      expect(find.byIcon(Icons.restore_from_trash_rounded), findsOneWidget);
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.restore_from_trash_rounded));
      await tester.pumpAndSettle();
      expect(find.text('回收站'), findsOneWidget);
      expect(find.text('书一'), findsOneWidget);
      expect(find.textContaining('来源：读书'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.restore_rounded));
      await tester.pumpAndSettle();
      expect(store.data.trash, isEmpty);
      expect(store.listById(list.id)!.items.single.id, itemId);
      expect(find.text('回收站是空的'), findsOneWidget);
    });
  });

  group('日记回收站', () {
    test('删除入站（含主条目）、恢复回原位、同键不覆盖', () {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      store.replaceData(AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: {
          '2026-01-01': JournalEntry(
              date: '2026-01-01', text: '主条目', mood: Mood.good),
          '2026-01-01#x1': JournalEntry(
              date: '2026-01-01', id: 'x1', text: '追加篇'),
        },
      ));
      final key = store.deleteJournalEntry('x1');
      expect(key, '2026-01-01#x1');
      expect(store.data.journal.containsKey('2026-01-01#x1'), isFalse);
      expect(store.data.journalTrash.single.storageKey, '2026-01-01#x1');
      // 主条目（无 id）同样可删。
      final mainKey = store.deleteJournalEntry('2026-01-01');
      expect(mainKey, '2026-01-01');
      expect(store.data.journalTrash.length, 2);
      // 恢复回原位。
      expect(store.restoreJournalTrash('2026-01-01#x1'), isTrue);
      expect(store.data.journal['2026-01-01#x1']!.text, '追加篇');
      expect(store.data.journal['2026-01-01#x1']!.updatedAt, greaterThan(0));
      // 同键已有新内容时不覆盖，条目留在回收站。
      store.saveJournal('2026-01-01', '', '重写的新篇', null);
      expect(store.restoreJournalTrash('2026-01-01'), isFalse);
      expect(store.data.journal['2026-01-01']!.text, '重写的新篇');
      expect(
        store.data.journalTrash.any((t) => t.storageKey == '2026-01-01'),
        isTrue,
      );
      expect(store.restoreJournalTrash('不存在'), isFalse);
    });

    test('journalTrash 序列化往返，旧快照缺键为空表', () {
      final decoded = AppData.decode(AppData(
        lists: const [],
        tasks: const [],
        habits: const [],
        journal: const {},
        journalTrash: [
          JournalTrashItem(
            storageKey: '2026-02-02',
            entry: JournalEntry(date: '2026-02-02', text: '被删的'),
            deletedAt: 12345,
          ),
        ],
      ).encode());
      expect(decoded.journalTrash.single.storageKey, '2026-02-02');
      expect(decoded.journalTrash.single.entry.text, '被删的');
      expect(decoded.journalTrash.single.deletedAt, 12345);
      final legacy = AppData.decode(
          '{"lists":[],"tasks":[],"habits":[],"journal":{}}');
      expect(legacy.journalTrash, isEmpty);
    });

    test('回收站按存储键并集合并，删除时间新者胜', () {
      final mine = AppData(
          lists: [], tasks: [], habits: [], journal: {},
          journalTrash: [
            JournalTrashItem(
                storageKey: 'k1',
                entry: JournalEntry(date: '2026-01-01', text: '旧删'),
                deletedAt: 100),
          ]);
      final theirs = AppData(
          lists: [], tasks: [], habits: [], journal: {},
          journalTrash: [
            JournalTrashItem(
                storageKey: 'k1',
                entry: JournalEntry(date: '2026-01-01', text: '新删'),
                deletedAt: 200),
            JournalTrashItem(
                storageKey: 'k2',
                entry: JournalEntry(date: '2026-01-02', text: '对方删的'),
                deletedAt: 150),
          ]);
      final (m, _) = AppStore.mergeAppData(
          mine: mine, theirs: theirs, myTombs: {}, theirTombs: {});
      expect(m.journalTrash.length, 2);
      expect(
          m.journalTrash.firstWhere((t) => t.storageKey == 'k1').entry.text,
          '新删');
    });
  });

  group('首装数据', () {
    test('种子是干净的白板：不含任何演示内容', () {
      final s = seedData();
      expect(s.lists, isEmpty);
      expect(s.tasks, isEmpty);
      expect(s.habits, isEmpty);
      expect(s.journal, isEmpty);
      expect(s.milestones, isEmpty);
      // 空数据往返不抛异常。
      expect(AppData.decode(s.encode()).tasks, isEmpty);
    });
  });

  group('多端合并 mergeAppData', () {
    PlanTask task(String id, String title, int u) =>
        PlanTask(id: id, title: title, updatedAt: u);

    test('各自独有条目都保留', () {
      final mine = AppData(
          lists: [], tasks: [task('a', '我的', 10)], habits: [], journal: {});
      final theirs = AppData(
          lists: [], tasks: [task('b', 'TA 的', 20)], habits: [], journal: {});
      final (m, _) = AppStore.mergeAppData(
          mine: mine, theirs: theirs, myTombs: {}, theirTombs: {});
      expect(m.tasks.length, 2);
      expect(m.tasks.map((t) => t.id).toSet(), {'a', 'b'});
    });

    test('同 id updatedAt 新者胜', () {
      final mine = AppData(
          lists: [], tasks: [task('a', '旧版', 10)], habits: [], journal: {});
      final theirs = AppData(
          lists: [], tasks: [task('a', '新版', 99)], habits: [], journal: {});
      final (m, _) = AppStore.mergeAppData(
          mine: mine, theirs: theirs, myTombs: {}, theirTombs: {});
      expect(m.tasks.single.title, '新版');
    });

    test('墓碑晚于实体修改时阻止复活', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final mine = AppData(
          lists: [], tasks: [], habits: [], journal: {});
      final theirs = AppData(
          lists: [],
          tasks: [task('a', '删除前的旧副本', now)],
          habits: [], journal: {});
      final (m, tombs) = AppStore.mergeAppData(
          mine: mine,
          theirs: theirs,
          myTombs: {'a': now + 100},
          theirTombs: {});
      expect(m.tasks, isEmpty);
      expect(tombs['a'], now + 100);
    });

    test('删除后同键重新写入（恢复）可穿透墓碑', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final theirs = AppData(
          lists: [], tasks: [], habits: [], journal: {});
      // 对端还带着删除时的墓碑；本端已恢复该实体并把 updatedAt 提到其后。
      final restored =
          AppData(lists: [], tasks: [task('a', '找回的数据', now + 500)],
              habits: [], journal: {});
      final (m, _) = AppStore.mergeAppData(
          mine: restored,
          theirs: theirs,
          myTombs: {},
          theirTombs: {'a': now});
      expect(m.tasks.single.title, '找回的数据');
    });

    test('清单条目级合并', () {
      final myItem = ListItem(id: 'i1', title: '旧', updatedAt: 5);
      final theirItem = ListItem(id: 'i1', title: '新', updatedAt: 50);
      final mine = AppData(
          lists: [
            TaskList(id: 'l', name: '清单', color: '3E6B4F', items: [myItem]),
          ],
          tasks: [], habits: [], journal: {});
      final theirs = AppData(
          lists: [
            TaskList(id: 'l', name: '清单', color: '3E6B4F',
                items: [theirItem]),
          ],
          tasks: [], habits: [], journal: {});
      final (m, _) = AppStore.mergeAppData(
          mine: mine, theirs: theirs, myTombs: {}, theirTombs: {});
      expect(m.lists.single.items.single.title, '新');
    });

    test('日记按日期键合并，新者胜', () {
      final mine = AppData(
          lists: [],
          tasks: [],
          habits: [],
          journal: {
            '2026-01-01': JournalEntry(date: '2026-01-01', text: '旧',
                updatedAt: 1),
          });
      final theirs = AppData(
          lists: [],
          tasks: [],
          habits: [],
          journal: {
            '2026-01-01': JournalEntry(date: '2026-01-01', text: '新',
                updatedAt: 99),
            '2026-01-02': JournalEntry(date: '2026-01-02', text: 'TA 的',
                updatedAt: 5),
          });
      final (m, _) = AppStore.mergeAppData(
          mine: mine, theirs: theirs, myTombs: {}, theirTombs: {});
      expect(m.journal['2026-01-01']!.text, '新');
      expect(m.journal['2026-01-02']!.text, 'TA 的');
    });
  });

  group('情侣密钥派生', () {
    test('deriveKeyFromSecret 与恢复码派生兼容（不抛即可用）', () async {
      final key = await JournalCrypto.deriveKeyFromSecret(
          'XJXXYC', 'zhiji-couple-v1:aaa:bbb', 1000);
      final b64 = await JournalCrypto.keyToBase64(key);
      expect(b64.length, 44); // 32 字节 base64
      // 同参数可复现
      final key2 = await JournalCrypto.deriveKeyFromSecret(
          'XJXXYC', 'zhiji-couple-v1:aaa:bbb', 1000);
      expect(await JournalCrypto.keyToBase64(key2), b64);
      // 加解密闭环
      final cipher = await JournalCrypto.encryptWithBase64(b64, 'hello');
      expect(await JournalCrypto.decryptWithBase64(b64, cipher), 'hello');
    });

    test('X25519 协商：双方得到同一把共享密钥', () async {
      final (privA, pubA) = await JournalCrypto.generateCoupleKeyPair();
      final (privB, pubB) = await JournalCrypto.generateCoupleKeyPair();
      final ids = ['a' * 32, 'b' * 32];
      final kA =
          await JournalCrypto.deriveCoupleKeyX25519(privA, pubB, ids);
      final kB =
          await JournalCrypto.deriveCoupleKeyX25519(privB, pubA, ids);
      expect(kA, kB);
      expect(kA.length, 44); // 32 字节 base64
      // 换了账号组合就应得到不同密钥（绑定到具体这对情侣）。
      final kC = await JournalCrypto.deriveCoupleKeyX25519(
          privA, pubB, ['a' * 32, 'c' * 32]);
      expect(kC, isNot(kA));
    });
  });

  group('同步自愈', () {
    test('退避间隔表：前台长轮询 1s 兜底节拍翻倍，封顶 15s、后台封顶 45s', () {
      expect(SyncService.pollInterval(foreground: true, failStreak: 0),
          const Duration(seconds: 1));
      expect(SyncService.pollInterval(foreground: true, failStreak: 1),
          const Duration(seconds: 2));
      expect(SyncService.pollInterval(foreground: true, failStreak: 3),
          const Duration(seconds: 8));
      expect(SyncService.pollInterval(foreground: false, failStreak: 0),
          const Duration(seconds: 15));
      expect(SyncService.pollInterval(foreground: false, failStreak: 2),
          const Duration(seconds: 45));
      // 前台封顶 15 秒：连续失败时自动回连最多迟到 15 秒。
      expect(SyncService.pollInterval(foreground: true, failStreak: 9),
          const Duration(seconds: 15));
      expect(SyncService.pollInterval(foreground: false, failStreak: 9),
          const Duration(seconds: 45));
      // 留言板可见时 2 秒快轮（退避仍然生效）。
      expect(SyncService.pollInterval(foreground: true, failStreak: 0,
              boardVisible: true),
          const Duration(seconds: 2));
      // 保活服务在跑时后台压到 3 秒：配合服务端 20 秒长轮询，等效秒级抵达。
      expect(SyncService.pollInterval(foreground: false, failStreak: 0,
              keepAlive: true),
          const Duration(seconds: 3));
      // 保活下退避同样生效，但封顶仍是后台的 45 秒。
      expect(SyncService.pollInterval(foreground: false, failStreak: 2,
              keepAlive: true),
          const Duration(seconds: 12));
      expect(SyncService.pollInterval(foreground: false, failStreak: 9,
              keepAlive: true),
          const Duration(seconds: 45));
    });

    test('已读回执只在留言板可见且前台时上报', () {
      int? v({int unread = 0, bool board = true, bool fg = true, int at = 1000}) =>
          SyncService.readUpToValue(
            unreadMessages: unread,
            boardVisible: board,
            foreground: fg,
            lastMessageAt: at,
          );
      expect(v(), 1000);
      // 没打开留言板 / 在后台都不算已读（冷启动静默采纳、后台闹钟曾误报）。
      expect(v(board: false), isNull);
      expect(v(fg: false), isNull);
      // 还有未读留言时不上报。
      expect(v(unread: 1), isNull);
      // 没有消息时不报。
      expect(v(at: 0), isNull);
    });

    test('网络类失败分类', () {
      expect(SyncApi.isTransientMessage('网络不可用'), isTrue);
      expect(SyncApi.isTransientMessage('连接超时'), isTrue);
      expect(SyncApi.isTransientMessage('安全连接失败'), isTrue);
      expect(SyncApi.isTransientMessage('服务暂时不可用（500）'), isTrue);
      expect(SyncApi.isTransientMessage('服务返回异常'), isTrue);
      expect(SyncApi.isTransientMessage('邮箱或密码不对'), isFalse);
      expect(SyncApi.isTransientMessage('内容过大，同步失败'), isFalse);
      expect(SyncApi.isTransientMessage('绑定码不存在或已失效'), isFalse);
    });
  });

  group('清单共同编辑', () {
    ListItem item(String id, String title, int u, {bool done = false}) =>
        ListItem(id: id, title: title, updatedAt: u, done: done);

    test('TaskList coEdit 序列化往返与 shareMode 推导', () {
      final l = TaskList.fromJson({
        'id': 'l', 'name': '书单', 'color': '3E6B4F',
        'items': [], 'shared': true, 'coEdit': true, 'u': 5,
      });
      expect(l.coEdit, isTrue);
      expect(l.shareMode, ListShareMode.coEdit);
      expect(
          TaskList.fromJson(
                  {'id': 'x', 'name': 'n', 'color': 'c', 'items': []})
              .shareMode,
          ListShareMode.off);
      final restored = TaskList.fromJson(
          Map<String, dynamic>.from(jsonDecode(jsonEncode(l.toJson())) as Map));
      expect(restored.coEdit, isTrue);
      expect(restored.shared, isTrue);
    });

    test('AppData coedits 序列化往返，缺键兼容', () {
      final d = AppData(
          lists: [], tasks: [], habits: [], journal: {},
          coedits: {
            'l1': {'i1': item('i1', 'TA 加的', 9)},
          });
      final back = AppData.decode(d.encode());
      expect(back.coedits['l1']!['i1']!.title, 'TA 加的');
      expect(
          AppData.decode('{"lists":[],"tasks":[],"habits":[],"journal":{}}')
              .coedits,
          isEmpty);
    });

    test('applyCoEdits：新条目置顶并入，已有条目新者胜', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final l = store.addList('书单', '3E6B4F')!;
      store.setListCoEdit(l.id, true);
      l.items.add(item('e1', '原条目', 10));

      final changed = store.applyCoEdits({
        l.id: {
          'n1': item('n1', 'TA 加的', 20),
          'e1': item('e1', 'TA 勾完了', 30, done: true),
        },
      });
      expect(changed, isTrue);
      expect(l.items.first.id, 'n1');
      expect(l.items.firstWhere((x) => x.id == 'e1').done, isTrue);
    });

    test('applyCoEdits：非共同编辑清单拒收', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final l = store.addList('私密', '3E6B4F')!;
      final changed = store.applyCoEdits({
        l.id: {'x': item('x', '不该出现', 99)},
      });
      expect(changed, isFalse);
      expect(l.items, isEmpty);
    });

    test('applyCoEdits：所有者已删除的条目不回流复活', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final l = store.addList('书单', '3E6B4F')!;
      store.setListCoEdit(l.id, true);
      // 所有者删除过的条目：墓碑在案。
      store.tombstones['dead'] = DateTime.now().millisecondsSinceEpoch;
      final changed = store.applyCoEdits({
        l.id: {
          'dead': item('dead', '已删除却回流', 99),
          'alive': item('alive', '新条目', 50),
        },
      });
      expect(changed, isTrue);
      expect(l.items.map((e) => e.id), ['alive']);
    });

    test('TA 端 overlay：勾选与添加即时生效视图', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final src = item('i1', '共享条目', 10);
      final pl = TaskList(
          id: 'pl', name: 'TA 清单', color: '3E6B4F',
          items: [src], shared: true, coEdit: true);

      store.coEditToggleItem('pl', src);
      expect(store.data.coedits['pl']!['i1']!.done, isTrue);
      final view = store.coEditEffectiveItems(pl);
      expect(view.first.done, isTrue);
      expect(src.done, isFalse); // 只读快照原条目不动

      store.coEditAddItem('pl', 'TA 新增');
      final view2 = store.coEditEffectiveItems(pl);
      expect(view2.first.title, 'TA 新增');
      expect(view2.length, 2);
    });

    test('pruneCoEdits：已回流修剪，关闭共同编辑整单丢弃', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      store.data.coedits
        ..['a'] = {'x': item('x', '已回流', 50)}
        ..['b'] = {'y': item('y', '还在编', 50)};
      final partnerData = AppData(
          lists: [
            TaskList(id: 'a', name: 'A', color: '3E6B4F', coEdit: true,
                items: [item('x', '已回流', 100)]),
            TaskList(id: 'b', name: 'B', color: '3E6B4F',
                items: []),
          ],
          tasks: [], habits: [], journal: {});
      store.pruneCoEdits(partnerData);
      expect(store.data.coedits.containsKey('a'), isFalse);
      expect(store.data.coedits.containsKey('b'), isFalse);
    });

    test('pruneCoEdits：对方列表长期缺失的条目 48 小时后淘汰', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final fresh = item('n1', '刚加的', DateTime.now().millisecondsSinceEpoch);
      final stale = item(
          'old', '三天前的幽灵', DateTime.now().millisecondsSinceEpoch -
              3 * 86400000);
      store.data.coedits['c'] = {'n1': fresh, 'old': stale};
      final partnerData = AppData(
          lists: [
            TaskList(id: 'c', name: 'C', color: '3E6B4F', coEdit: true,
                items: []),
          ],
          tasks: [], habits: [], journal: {});
      store.pruneCoEdits(partnerData);
      // 新条目在回流窗口内保留，超期幽灵被清。
      expect(store.data.coedits['c']!.containsKey('n1'), isTrue);
      expect(store.data.coedits['c']!.containsKey('old'), isFalse);
      // 生效视图也不再显示幽灵。
      final view = store.coEditEffectiveItems(partnerData.lists.first);
      expect(view.map((e) => e.id), ['n1']);
    });

    test('AppData.fromJson 过滤畸形日期键', () {
      final d = AppData.decode(jsonEncode({
        'lists': [],
        'tasks': [],
        'habits': [
          {'id': 'h', 'name': 'x', 'color': '3E6B4F',
           'records': {'2026-10-07': 'done', 'bad': 'done', '': 'miss'}},
        ],
        'journal': {
          '2026-10-07': {'date': '2026-10-07', 'text': 'ok'},
          'oops': {'date': 'oops', 'text': 'bad'},
          '2026-10-07#abc123': {'date': '2026-10-07', 'id': 'abc123',
              'text': '第二篇'},
        },
      }));
      expect(d.journal.keys, ['2026-10-07', '2026-10-07#abc123']);
      expect(d.habits.single.records.keys, ['2026-10-07']);
    });

    test('日记单日多篇：键规则与当日条目', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final day = '2026-10-07';
      // 主条目（旧格式，无 id）。
      store.saveJournal(day, '第一篇', '主条目内容', null);
      expect(store.data.journal[day]!.id, '');
      // 追加篇章（带 id）。
      final extra = JournalEntry(
          date: day, id: 'abc', title: '第二篇', text: '追加内容',
          updatedAt: 50);
      store.addJournalEntry(extra);
      expect(store.data.journal['$day#abc'], same(extra));
      // 当日全部条目：主在前、附加在后，互不覆盖。
      final all = store.journalEntriesOn(day);
      expect(all.length, 2);
      expect(all[0].title, '第一篇');
      expect(all[1].title, '第二篇');
      // 按 id 更新只影响对应篇章。
      store.updateJournalEntry('abc', '第二篇改', '新内容', null,
          weather: '', shared: true);
      expect(store.data.journal['$day#abc']!.title, '第二篇改');
      expect(store.data.journal[day]!.title, '第一篇');
      expect(store.data.journal['$day#abc']!.shared, isTrue);
      expect(store.data.journal[day]!.shared, isFalse);
      // 往返序列化保留 id 与键。
      final back = AppData.decode(store.data.encode());
      expect(back.journal.containsKey('$day#abc'), isTrue);
      expect(back.journal['$day#abc']!.id, 'abc');
    });

    test('mergeAppData：coedits 条目级新者胜（多端 overlay）', () {
      final mine = AppData(
          lists: [], tasks: [], habits: [], journal: {},
          coedits: {'l': {'x': item('x', '设备A旧', 10)}});
      final theirs = AppData(
          lists: [], tasks: [], habits: [], journal: {},
          coedits: {
            'l': {'x': item('x', '设备B新', 20), 'y': item('y', '仅B', 5)},
          });
      final (m, _) = AppStore.mergeAppData(
          mine: mine, theirs: theirs, myTombs: {}, theirTombs: {});
      expect(m.coedits['l']!['x']!.title, '设备B新');
      expect(m.coedits['l']!.containsKey('y'), isTrue);
    });

    test('Habit reminder 序列化往返与提醒时间回退', () {
      final h = Habit.fromJson({
        'id': 'h1', 'name': '喝水', 'color': '3E6B4F',
        'records': {}, 'time': '07:30', 'remind': true, 'u': 1,
      });
      expect(h.reminder, isTrue);
      expect(h.reminderTime, '07:30');
      final restored = Habit.fromJson(
          Map<String, dynamic>.from(jsonDecode(jsonEncode(h.toJson())) as Map));
      expect(restored.reminder, isTrue);
      // 缺键兼容：旧数据无 remind 键解析为关。
      final legacy = Habit.fromJson(
          {'id': 'h2', 'name': '旧习惯', 'color': '3E6B4F', 'records': {}});
      expect(legacy.reminder, isFalse);
      // 未设时间默认 20:00 提醒。
      expect(legacy.reminderTime, '20:00');
    });
  });
}
