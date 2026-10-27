import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/responsive.dart';

import '../data/colors.dart';
import '../data/models.dart';
import '../util/dates.dart';
import '../theme.dart';

/// 习惯详情：统计 + 近一年热力图 + 全部打卡记录（仅查看）。
/// 点热力图亮格或点记录行都会互相定位：格子高亮 + 显示该日状态。
class HabitDetailPage extends StatefulWidget {
  const HabitDetailPage({
    super.key,
    required this.habit,
    this.isPartner = false,
  });

  final Habit habit;

  /// 是否 TA 的习惯：决定详情页标题。
  final bool isPartner;

  @override
  State<HabitDetailPage> createState() => _HabitDetailPageState();
}

class _HabitDetailPageState extends State<HabitDetailPage> {
  /// 当前选中的日期（yyyy-MM-dd）：热力图格子与记录行双向联动。
  String? _selected;

  Timer? _autoClear;

  final GlobalKey<_HeatmapCardState> _heatKey = GlobalKey<_HeatmapCardState>();

  @override
  void dispose() {
    _autoClear?.cancel();
    super.dispose();
  }

  void _select(String? key) {
    _autoClear?.cancel();
    setState(() => _selected = key);
    if (key != null) {
      // 选中状态 4 秒后自动落下，避免一直挂着高亮。
      _autoClear = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _selected = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final habit = widget.habit;
    final scheme = Theme.of(context).colorScheme;
    final now = today();

    final doneKeys =
        habit.records.entries
            .where((e) => e.value == HabitStatus.done)
            .map((e) => e.key)
            .toList()
          ..sort();
    final totalDone = doneKeys.length;
    final monthDone = habit.records.entries
        .where(
          (e) =>
              e.value == HabitStatus.done &&
              e.key.startsWith(dateKey(now).substring(0, 7)),
        )
        .length;
    // 连续天数：从今天（或昨天）往回数 done。
    var streak = 0;
    var cursor = habit.records.containsKey(dateKey(now))
        ? now
        : now.subtract(const Duration(days: 1));
    while (habit.records[dateKey(cursor)] == HabitStatus.done) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    // 历史最长连续。
    var best = 0;
    var run = 0;
    DateTime? prev;
    for (final k in doneKeys) {
      final p = k.split('-');
      final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
      if (prev != null && d.difference(prev).inDays == 1) {
        run++;
      } else {
        run = 1;
      }
      if (run > best) best = run;
      prev = d;
    }
    final trackedDays = habit.records.length;
    final rate = trackedDays == 0 ? 0 : (totalDone * 100 / trackedDays).round();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isPartner ? 'TA 的习惯 · ${habit.name}' : habit.name),
      ),
      body: ResponsiveContent(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colorFromHex(habit.color)
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.repeat_rounded,
                        size: 22,
                        color: colorFromHex(habit.color),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        habit.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (habit.time.isNotEmpty)
                      Text(
                        habit.time,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '统计',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _StatCell(label: '总打卡', value: '$totalDone'),
                        _StatCell(label: '当前连续', value: '$streak 天'),
                        _StatCell(label: '最长连续', value: '$best 天'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _StatCell(label: '本月打卡', value: '$monthDone'),
                        _StatCell(label: '记录天数', value: '$trackedDays'),
                        _StatCell(label: '完成率', value: '$rate%'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _HeatmapCard(
              key: _heatKey,
              habit: habit,
              now: now,
              selected: _selected,
              onCellTap: _select,
            ),
            const SizedBox(height: 12),
            _HistoryCard(
              habit: habit,
              selected: _selected,
              onSelect: (key) {
                _select(key);
                _heatKey.currentState?.scrollToDate(key);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 近 52 周 GitHub 风格热力图：列=周（旧→新），行=周一..周日。
/// 打开时自动定位到最右（今天附近），不必从最旧端手动滚。
/// 点击已打卡/错过的格子显示该日日期与状态，再点一次或 4 秒后自动收起。
class _HeatmapCard extends StatefulWidget {
  const _HeatmapCard({
    super.key,
    required this.habit,
    required this.now,
    required this.selected,
    required this.onCellTap,
  });

  final Habit habit;
  final DateTime now;
  final String? selected;
  final void Function(String? key) onCellTap;

  @override
  State<_HeatmapCard> createState() => _HeatmapCardState();
}

class _HeatmapCardState extends State<_HeatmapCard> {
  final ScrollController _heatCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    // 布局完成后直接跳到最新一列（今天），旧的月份向左翻看。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_heatCtrl.hasClients) return;
      _heatCtrl.jumpTo(_heatCtrl.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _heatCtrl.dispose();
    super.dispose();
  }

  DateTime get _start {
    const weeks = 52;
    final thisMonday = widget.now.subtract(
      Duration(days: widget.now.weekday - 1),
    );
    return thisMonday.subtract(const Duration(days: 7 * (weeks - 1)));
  }

  /// 把 [key]（yyyy-MM-dd）所在列滚进可视区中央（记录行点击反向定位用）。
  void scrollToDate(String key) {
    if (!_heatCtrl.hasClients) return;
    final p = key.split('-');
    if (p.length < 3) return;
    final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    final w = d.difference(_start).inDays ~/ 7;
    if (w < 0) return;
    final pos = _heatCtrl.position;
    final target = (w * 15.0 - pos.viewportDimension / 2 + 7.5).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    _heatCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = widget.now;
    final base = colorFromHex(widget.habit.color);
    const weeks = 52;
    final start = _start;
    final sel = widget.selected;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sel != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _selLabel(sel),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => widget.onCellTap(null),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              )
            else
              const Text(
                '近一年 · 点格子看日期',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              controller: _heatCtrl,
              scrollDirection: Axis.horizontal,
              reverse: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var dow = 0; dow < 7; dow++)
                    Row(
                      children: [
                        for (var w = 0; w < weeks; w++)
                          Builder(
                            builder: (context) {
                              final day = start.add(
                                Duration(days: w * 7 + dow),
                              );
                              if (day.isAfter(now)) {
                                return const SizedBox(width: 12, height: 12);
                              }
                              final key = dateKey(day);
                              final status = widget.habit.records[key];
                              final selectable =
                                  status == HabitStatus.done ||
                                  status == HabitStatus.miss;
                              Color c;
                              if (status == HabitStatus.done) {
                                c = base;
                              } else if (status == HabitStatus.miss) {
                                c = scheme.errorContainer;
                              } else {
                                c = scheme.surfaceContainerHigh;
                              }
                              final isSelected = selectable && sel == key;
                              return GestureDetector(
                                onTap: selectable
                                    ? () => widget.onCellTap(
                                        widget.selected == key ? null : key,
                                      )
                                    : null,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  margin: const EdgeInsets.all(1.5),
                                  decoration: BoxDecoration(
                                    color: c,
                                    borderRadius: BorderRadius.circular(3),
                                    border: isSelected
                                        ? Border.all(
                                            color: scheme.onSurface,
                                            width: 1.4,
                                          )
                                        : null,
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '12 个月前',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  '今天',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _selLabel(String key) {
    final p = key.split('-');
    final status = widget.habit.records[key];
    final label = status == HabitStatus.done
        ? '已打卡'
        : status == HabitStatus.miss
        ? '错过'
        : '未记录';
    final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    final nowKey = dateKey(widget.now);
    final prefix = key == nowKey
        ? '今天'
        : (key == dateKey(widget.now.subtract(const Duration(days: 1)))
              ? '昨天'
              : '${d.year}年${d.month}月${d.day}日');
    return '$prefix · $label';
  }
}

/// 全部打卡记录，倒序；仅查看，点击可在热力图中定位高亮该日。
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.habit,
    required this.selected,
    required this.onSelect,
  });

  final Habit habit;
  final String? selected;
  final void Function(String key) onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keys = habit.records.keys.toList()..sort((a, b) => b.compareTo(a));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '全部记录（${keys.length}）',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            if (keys.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '还没有打卡记录',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final k in keys)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                selected: k == selected,
                selectedTileColor: scheme.primary.withValues(alpha: 0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                leading: Icon(
                  habit.records[k] == HabitStatus.done
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: 18,
                  color: habit.records[k] == HabitStatus.done
                      ? scheme.primary
                      : scheme.error,
                ),
                title: Text(_dayLabel(k), style: const TextStyle(fontSize: 13)),
                trailing: Text(
                  habit.records[k] == HabitStatus.done ? '已打卡' : '错过',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                onTap: () {
                  m3HapticSelect();
                  onSelect(k);
                },
              ),
          ],
        ),
      ),
    );
  }

  String _dayLabel(String key) {
    final p = key.split('-');
    final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    final now = today();
    if (key == dateKey(now)) return '今天';
    if (key == dateKey(now.subtract(const Duration(days: 1)))) return '昨天';
    return '${d.year}/${d.month}/${d.day}';
  }
}
