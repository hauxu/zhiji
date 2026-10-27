import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../sync/sync_service.dart';
import '../ui/breakpoints.dart';
import '../util/dates.dart';
import '../widgets/responsive.dart';
import '../widgets/slide_action.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 历史计划：本机保存的任务完成记录，按月分组回看。
/// 完成过的计划左滑即可添加到今天；桌面宽屏左列表、右详情。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  /// 桌面双栏当前选中的日期键；'week' 表示本周任务分组。
  String? _selectedKey;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final base = today();

    // 近 90 天已完成的计划。
    //
    // 这里只收「当天确实完成」的条目：tasksOn 会把每天/每周重复任务
    // 投影到每一天，直接摆出来会让历史页被同一个任务刷满 90 行。
    final dayData = <DateTime, List<PlanTask>>{};
    for (var i = 1; i <= 90; i++) {
      final d = base.subtract(Duration(days: i));
      final done = store
          .tasksOn(dateKey(d))
          .where((t) => t.isDoneOn(d))
          .toList();
      if (done.isNotEmpty) dayData[d] = done;
    }
    final weekScoped = store.weekTasks();
    final sortedDays = dayData.keys.toList()..sort((a, b) => b.compareTo(a));
    final months = <String, List<DateTime>>{};
    for (final d in sortedDays) {
      months.putIfAbsent('${d.year}-${d.month}', () => []).add(d);
    }
    final isEmpty = dayData.isEmpty && weekScoped.isEmpty;

    if (context.isExpanded && !isEmpty) {
      final selectedKey =
          _selectedKey ??
          (sortedDays.isNotEmpty
              ? dateKey(sortedDays.first)
              : (weekScoped.isNotEmpty ? 'week' : null));
      DateTime? selectedDay;
      for (final d in sortedDays) {
        if (dateKey(d) == selectedKey) {
          selectedDay = d;
          break;
        }
      }
      return Scaffold(
        appBar: AppBar(title: const Text('历史计划')),
        body: Row(
          children: [
            SizedBox(
              width: 320,
              child: _DesktopHistoryList(
                months: months,
                dayData: dayData,
                weekScoped: weekScoped,
                selectedKey: selectedKey,
                onSelect: (k) => setState(() => _selectedKey = k),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: SlidableAutoCloseBehavior(
                child: selectedKey == 'week'
                    ? _HistoryDayPane(
                        title: '本周任务',
                        subtitle: '${weekScoped.length} 项',
                        tasks: weekScoped,
                        day: base,
                      )
                    : selectedDay == null
                    ? const _HistoryEmpty()
                    : _HistoryDayPane(
                        title:
                            '${monthDay(selectedDay)} ${weekdayCn(selectedDay)}',
                        subtitle: '完成 ${dayData[selectedDay]!.length} 项',
                        tasks: dayData[selectedDay]!,
                        day: selectedDay,
                      ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('历史计划')),
      body: ResponsiveContent(
        child: isEmpty
            ? const _HistoryEmpty()
            : SlidableAutoCloseBehavior(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    if (weekScoped.isNotEmpty) ...[
                      const _MonthLabel('本周任务'),
                      Card(
                        child: Column(
                          children: [
                            for (final t in weekScoped)
                              _HistoryTile(task: t, done: t.done),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    for (final month in months.keys) ...[
                      _MonthLabel(
                        '${month.substring(0, 4)}年${month.substring(5)}月',
                      ),
                      for (final d in months[month]!) ...[
                        _HistoryDayCard(day: d, tasks: dayData[d]!),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

/// 桌面双栏左列：按月份分组的日期清单。
class _DesktopHistoryList extends StatelessWidget {
  const _DesktopHistoryList({
    required this.months,
    required this.dayData,
    required this.weekScoped,
    required this.selectedKey,
    required this.onSelect,
  });

  final Map<String, List<DateTime>> months;
  final Map<DateTime, List<PlanTask>> dayData;
  final List<PlanTask> weekScoped;
  final String? selectedKey;
  final void Function(String key) onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (weekScoped.isNotEmpty)
          Card(
            child: ListTile(
              dense: true,
              selected: selectedKey == 'week',
              leading: Icon(
                Icons.calendar_view_week_rounded,
                size: 20,
                color: selectedKey == 'week'
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              title: const Text('本周任务', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                '${weekScoped.length} 项',
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => onSelect('week'),
            ),
          ),
        for (final month in months.keys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Text(
              '${month.substring(0, 4)}年${month.substring(5)}月',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
          for (final d in months[month]!)
            Card(
              child: ListTile(
                dense: true,
                selected: selectedKey == dateKey(d),
                leading: Icon(
                  Icons.event_available_rounded,
                  size: 20,
                  color: selectedKey == dateKey(d)
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                title: Text(
                  '${monthDay(d)} ${weekdayCn(d)}',
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  '完成 ${dayData[d]!.length} 项',
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () => onSelect(dateKey(d)),
              ),
            ),
        ],
      ],
    );
  }
}

/// 桌面双栏右列：某一天/本周的任务明细。
class _HistoryDayPane extends StatelessWidget {
  const _HistoryDayPane({
    required this.title,
    required this.subtitle,
    required this.tasks,
    required this.day,
  });

  final String title;
  final String subtitle;
  final List<PlanTask> tasks;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              for (final t in tasks)
                _HistoryTile(task: t, done: t.isDoneOn(day)),
            ],
          ),
        ),
      ],
    );
  }
}

class _HistoryEmpty extends StatelessWidget {
  const _HistoryEmpty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_rounded,
              size: 44,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const Text(
              '还没有历史记录',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              '完成的任务按日期保存',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthLabel extends StatelessWidget {
  const _MonthLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _HistoryDayCard extends StatelessWidget {
  const _HistoryDayCard({required this.day, required this.tasks});

  final DateTime day;
  final List<PlanTask> tasks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = tasks.where((t) => t.isDoneOn(day)).length;

    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(
            '${monthDay(day)} ${weekdayCn(day)}',
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Text(
            '完成 $done/${tasks.length}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          children: [
            for (final t in tasks) _HistoryTile(task: t, done: t.isDoneOn(day)),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// 历史记录行：完成的可左滑「添加到今天」，未完成仅回看。
/// 加过一次后收起左滑入口，避免同一条历史被连点复制出多个今日任务。
class _HistoryTile extends StatefulWidget {
  const _HistoryTile({required this.task, required this.done});

  final PlanTask task;
  final bool done;

  @override
  State<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends State<_HistoryTile> {
  bool _added = false;

  void _addToToday(BuildContext context) {
    if (_added) return;
    final task = widget.task;
    final store = context.read<AppStore>();
    final copy = store.addTask(
      title: task.title,
      date: dateKey(today()),
      start: task.start,
      end: task.end,
      remindBefore: task.remindBefore,
    );
    // 经 store 写备注，保证落盘与推送。
    if (task.note.isNotEmpty) store.updateTask(copy.id, note: task.note);
    context.read<SyncService>().syncNow(push: true);
    setState(() => _added = true);
    // 历史页本身没有变化，需要一次反馈告诉用户确实加过了。
    showTopToast('已添加到今天');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final task = widget.task;
    final done = widget.done;
    final row = ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(
        done ? Icons.check_circle_rounded : Icons.cancel_rounded,
        size: 18,
        color: done ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        [if (task.timeLabel.isNotEmpty) task.timeLabel, task.title].join('  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          decoration: done ? TextDecoration.lineThrough : TextDecoration.none,
          color: done ? scheme.onSurfaceVariant : scheme.onSurface,
        ),
      ),
    );
    if (!done || _added) return row;
    return Slidable(
      key: ValueKey('history-${task.id}'),
      groupTag: 'history',
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.28,
        children: [
          M3SlideAction(
            onTap: () => _addToToday(context),
            color: scheme.primaryContainer,
            iconColor: scheme.onPrimaryContainer,
            icon: Icons.today_rounded,
            label: '添加到今天',
          ),
        ],
      ),
      child: row,
    );
  }
}
