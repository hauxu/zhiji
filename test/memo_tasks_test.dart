import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/data/store.dart';

PlanTask task({
  required String id,
  String title = 't',
  String date = '',
  bool done = false,
  int sort = 0,
  bool archived = false,
}) {
  return PlanTask(
    id: id,
    title: title,
    date: date,
    done: done,
    sort: sort,
    archived: archived,
  );
}

AppStore storeWith(List<PlanTask> tasks) {
  final store = AppStore();
  store.replaceData(
    AppData(
      lists: <TaskList>[],
      tasks: tasks,
      habits: <Habit>[],
      journal: <String, JournalEntry>{},
    ),
  );
  return store;
}

void main() {
  test('没有日期的计划进 memoTasks，有日期的不进', () {
    final store = storeWith([
      task(id: 'a', title: '无日期'),
      task(id: 'b', title: '有日期', date: '2026-11-03'),
      task(id: 'c', title: '无日期已完成', done: true),
    ]);

    final memos = store.memoTasks();
    expect(memos.map((t) => t.id), containsAll(['a', 'c']));
    expect(memos.map((t) => t.id), isNot(contains('b')));
  });

  test('归档后的备忘录不再出现', () {
    final store = storeWith([
      task(id: 'a', title: '无日期'),
      task(id: 'b', title: '已归档', archived: true),
    ]);
    expect(store.memoTasks().map((t) => t.id), ['a']);
  });

  test('备忘录与周无关，任何一天查到的是同一批', () {
    final store = storeWith([
      task(id: 'a', title: '甲'),
      task(id: 'b', title: '乙', date: '2026-11-03'),
    ]);
    expect(store.memoTasks().length, store.weekTasks().length);
    expect(
      store.memoTasks().map((t) => t.id).toSet(),
      store.weekTasks().map((t) => t.id).toSet(),
    );
  });

  test('排序：未完成在前，手动排序优先', () {
    final store = storeWith([
      task(id: 'done', title: '已完成', done: true),
      task(id: 'late', title: '乙', sort: 20),
      task(id: 'early', title: '甲', sort: 10),
    ]);
    expect(store.memoTasks().map((t) => t.id).toList(), ['early', 'late', 'done']);
  });
}
