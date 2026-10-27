import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/data/store.dart';
import 'package:goalday/util/dates.dart';

/// 多设备合并：Habit.records / PlanTask.doneDates 是实体内部集合，
/// 整实体 updatedAt LWW 会丢另一台设备上的打卡/完成记录。
/// 设计语义（见 store.dart 中 _mergeHabitRecords/_mergeTaskDoneDates 注释）：
/// - 日期取并集，不丢打卡/完成记录；
/// - 同一天状态冲突以 updatedAt 新者为准（平手取本地 mine）；
/// - 删除语义：没有逐条墓碑，"缺键"分不清"从未记录"与"被清除"，
///   因此单端清除某天不会被并集尊重（可能被另一端旧记录复活）；
///   整条实体删除仍由 tombstones 决定。
AppData _data({List<PlanTask> tasks = const [], List<Habit> habits = const []}) =>
    AppData(lists: [], tasks: tasks, habits: habits, journal: {});

PlanTask _task(
  String id, {
  required int u,
  String title = '任务',
  TaskRepeatMode repeat = TaskRepeatMode.none,
  List<String> doneDates = const [],
  bool done = false,
}) =>
    PlanTask(
      id: id,
      title: title,
      updatedAt: u,
      repeatMode: repeat,
      doneDates: List<String>.from(doneDates),
      done: done,
    );

Habit _habit(
  String id, {
  required int u,
  required Map<String, HabitStatus> records,
  String? name,
}) =>
    Habit(
      id: id,
      updatedAt: u,
      name: name ?? '习惯',
      color: '3E6B4F',
      records: Map<String, HabitStatus>.of(records),
    );

void main() {
  group('mergeAppData 集合字段并集（多设备）', () {
    test('习惯：两端不同日期的打卡都保留，其余字段取 updatedAt 新者', () {
      const d1 = '2026-10-20';
      const d2 = '2026-10-21';
      final mine = _habit('h1', u: 100, records: {d1: HabitStatus.done});
      final theirs = _habit('h1',
          u: 200,
          records: {d2: HabitStatus.done},
          name: '新名字');
      final (m, _) = AppStore.mergeAppData(
          mine: _data(habits: [mine]),
          theirs: _data(habits: [theirs]),
          myTombs: {},
          theirTombs: {});
      final h = m.habits.single;
      expect(h.records, {d1: HabitStatus.done, d2: HabitStatus.done});
      expect(h.name, '新名字');
      expect(h.updatedAt, 200);
      // 合并不得就地修改入参对象（两端数据都还可能被其他逻辑引用）
      expect(mine.records, {d1: HabitStatus.done});
      expect(theirs.records, {d2: HabitStatus.done});
    });

    test('习惯：同一天状态冲突以 updatedAt 新者为准（平手取本地）', () {
      const d1 = '2026-10-20';
      final (m1, _) = AppStore.mergeAppData(
          mine: _data(habits: [
            _habit('h1', u: 100, records: {d1: HabitStatus.miss}),
          ]),
          theirs: _data(habits: [
            _habit('h1', u: 200, records: {d1: HabitStatus.done}),
          ]),
          myTombs: {},
          theirTombs: {});
      expect(m1.habits.single.records[d1], HabitStatus.done);

      // updatedAt 相同：本地（mine）优先。
      final (m2, _) = AppStore.mergeAppData(
          mine: _data(habits: [
            _habit('h1', u: 100, records: {d1: HabitStatus.done}),
          ]),
          theirs: _data(habits: [
            _habit('h1', u: 100, records: {d1: HabitStatus.miss}),
          ]),
          myTombs: {},
          theirTombs: {});
      expect(m2.habits.single.records[d1], HabitStatus.done);
    });

    test('习惯：单端清除某天不会跨端传播（并集语义，需两端分别清除）', () {
      const d1 = '2026-10-20';
      // mine 更新（updatedAt 更大）且已清除 d1；theirs 旧数据仍有 d1。
      final mine = _habit('h1', u: 200, records: {});
      final theirs = _habit('h1', u: 100, records: {d1: HabitStatus.done});
      final (m, _) = AppStore.mergeAppData(
          mine: _data(habits: [mine]),
          theirs: _data(habits: [theirs]),
          myTombs: {},
          theirTombs: {});
      expect(m.habits.single.records[d1], HabitStatus.done);
    });

    test('习惯：整条删除仍由墓碑阻止复活（不受并集影响）', () {
      const d1 = '2026-10-20';
      final (m, _) = AppStore.mergeAppData(
          mine: _data(habits: [_habit('h1', u: 200, records: {})]),
          theirs: _data(habits: [
            _habit('h1', u: 100, records: {d1: HabitStatus.done}),
          ]),
          myTombs: {'h1': 300},
          theirTombs: {});
      expect(m.habits, isEmpty);
    });

    test('重复任务：两端不同完成日期都保留、排序，其余字段取新者', () {
      const d1 = '2026-10-20';
      const d2 = '2026-10-21';
      final mine = _task('t1',
          u: 100,
          title: '旧标题',
          repeat: TaskRepeatMode.daily,
          doneDates: [d1]);
      final theirs = _task('t1',
          u: 200,
          title: '新标题',
          repeat: TaskRepeatMode.daily,
          doneDates: [d2]);
      final (m, _) = AppStore.mergeAppData(
          mine: _data(tasks: [mine]),
          theirs: _data(tasks: [theirs]),
          myTombs: {},
          theirTombs: {});
      final t = m.tasks.single;
      expect(t.title, '新标题');
      expect(t.updatedAt, 200);
      expect(t.isRecurring, isTrue);
      expect(t.doneDates, [d1, d2]); // 并集并按日期升序
      expect(mine.doneDates, [d1]);
      expect(theirs.doneDates, [d2]);
    });

    test('重复任务：先并集后按 400 天裁剪（不让旧日期被另一端复活）', () {
      final old = dateKey(today().subtract(const Duration(days: 401)));
      final recent = dateKey(today());
      final mine = _task('t1',
          u: 100, repeat: TaskRepeatMode.daily, doneDates: [old]);
      final theirs = _task('t1',
          u: 200, repeat: TaskRepeatMode.daily, doneDates: [recent]);
      final (m, _) = AppStore.mergeAppData(
          mine: _data(tasks: [mine]),
          theirs: _data(tasks: [theirs]),
          myTombs: {},
          theirTombs: {});
      expect(m.tasks.single.doneDates, [recent]);
    });

    test('非重复任务：保持整实体 updatedAt 新者胜', () {
      final mine = _task('t2', u: 100, title: '旧', done: true);
      final theirs = _task('t2', u: 200, title: '新', done: false);
      final (m, _) = AppStore.mergeAppData(
          mine: _data(tasks: [mine]),
          theirs: _data(tasks: [theirs]),
          myTombs: {},
          theirTombs: {});
      expect(m.tasks.single.title, '新');
      expect(m.tasks.single.done, isFalse);
    });

    test('合并结果可 JSON 往返（序列化格式不变）', () {
      const d1 = '2026-10-20';
      const d2 = '2026-10-21';
      final (m, _) = AppStore.mergeAppData(
          mine: _data(
            habits: [_habit('h1', u: 100, records: {d1: HabitStatus.done})],
            tasks: [
              _task('t1',
                  u: 100, repeat: TaskRepeatMode.daily, doneDates: [d1]),
            ],
          ),
          theirs: _data(
            habits: [_habit('h1', u: 200, records: {d2: HabitStatus.done})],
            tasks: [
              _task('t1',
                  u: 200, repeat: TaskRepeatMode.daily, doneDates: [d2]),
            ],
          ),
          myTombs: {},
          theirTombs: {});
      final back = AppData.decode(m.encode());
      expect(back.habits.single.records,
          {d1: HabitStatus.done, d2: HabitStatus.done});
      expect(back.tasks.single.doneDates, [d1, d2]);
    });
  });
}