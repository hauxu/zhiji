import 'package:flutter/material.dart';

import '../widgets/responsive.dart';

import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import '../widgets/m3e_progress.dart';
import '../util/dates.dart';
import '../widgets/empty_state.dart';
import '../widgets/find_old_task_sheet.dart';
import '../widgets/magnet_reorder.dart';
import '../widgets/partner_widgets.dart';
import '../widgets/task_edit_sheet.dart';
import '../widgets/task_row.dart';

enum PlanViewMode { day, week }

enum PlanFilter { all, mine, ta }

/// 计划页：日/周视图。
class PlanPage extends StatefulWidget {
  const PlanPage({super.key});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> with WidgetsBindingObserver {
  PlanViewMode _mode = PlanViewMode.day;
  PlanFilter _filter = PlanFilter.all;
  DateTime _selected = today();

  /// 上次看到的「今天」；跨天后仍停在今天就跟着跳，避免页面一直显示昨天。
  DateTime _todayRef = today();
  final Map<int, GlobalKey> _dayKeys = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final now = today();
    final followsToday = _mode == PlanViewMode.day
        ? dateKey(_selected) == dateKey(_todayRef)
        : dateKey(_weekStart) == dateKey(weekStartOf(_todayRef));
    if (followsToday && dateKey(now) != dateKey(_todayRef)) {
      setState(() => _selected = now);
    }
    _todayRef = now;
  }

  DateTime get _weekStart => weekStartOf(_selected);

  bool get _isCurrentWeek =>
      dateKey(_weekStart) == dateKey(weekStartOf(today()));

  void _shiftDay(int days) {
    setState(() => _selected = _selected.add(Duration(days: days)));
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selected,
      firstDate: today().subtract(const Duration(days: 365 * 2)),
      lastDate: today().add(const Duration(days: 365 * 2)),
    );
    if (!mounted) return;
    if (picked != null) setState(() => _selected = picked);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 解绑后复位伴侣筛选。
    final bound = context.read<SyncService>().isBound;
    if (!bound && _filter != PlanFilter.all) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _filter = PlanFilter.all);
      });
    }
  }

  void _jumpToDay(int index) {
    final key = _dayKeys[index];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        alignment: 0.02,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('计划'),
        actions: [
          const _WeekProgressInline(),
          if (_mode == PlanViewMode.week) ...[
            IconButton(
              tooltip: '上一周',
              onPressed: () => setState(
                () => _selected = _selected.subtract(const Duration(days: 7)),
              ),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            IconButton(
              tooltip: '下一周',
              onPressed: () => setState(
                () => _selected = _selected.add(const Duration(days: 7)),
              ),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
          if (_mode == PlanViewMode.week && !_isCurrentWeek)
            TextButton(
              onPressed: () => setState(() => _selected = today()),
              child: const Text('回本周'),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'findOldTask',
            tooltip: '找回旧任务',
            onPressed: () => showFindOldTaskSheet(context),
            child: const Icon(Icons.history_rounded),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'newTask',
            onPressed: () =>
                showTaskEditSheet(context, defaultDate: dateKey(_selected)),
            child: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: ResponsiveContent(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Column(
                children: [
                  SegmentedButton<PlanViewMode>(
                    segments: const [
                      ButtonSegment(
                        value: PlanViewMode.day,
                        icon: Icon(Icons.today_rounded, size: 18),
                        label: Text('日计划'),
                      ),
                      ButtonSegment(
                        value: PlanViewMode.week,
                        icon: Icon(Icons.calendar_view_week_rounded, size: 18),
                        label: Text('周视图'),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) {
                      m3HapticSelect();
                      setState(() => _mode = s.first);
                    },
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: GestureDetector(
                // 空白处滑动切换日/周视图。
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v < -350 && _mode == PlanViewMode.day) {
                    m3HapticSelect();
                    setState(() => _mode = PlanViewMode.week);
                  } else if (v > 350 && _mode == PlanViewMode.week) {
                    m3HapticSelect();
                    setState(() => _mode = PlanViewMode.day);
                  }
                },
                child: AnimatedSwitcher(
                  duration: m3Duration,
                  switchInCurve: m3Curve,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _mode == PlanViewMode.day
                      ? ListView(
                          key: const ValueKey('day'),
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                          children: [
                            _DateNavRow(
                              selected: _selected,
                              onShift: _shiftDay,
                              onBackToday: () =>
                                  setState(() => _selected = today()),
                              onPickDate: _pickDate,
                            ),
                            const SizedBox(height: 8),
                            AnimatedSwitcher(
                              duration: m3Small,
                              switchInCurve: m3CurveIn,
                              switchOutCurve: m3CurveOut,
                              child: KeyedSubtree(
                                key: ValueKey(dateKey(_selected)),
                                child: DayTaskSection(
                                  date: _selected,
                                  filter: context.watch<SyncService>().isBound
                                      ? _filter
                                      : PlanFilter.all,
                                  onFilterChanged: (f) {
                                    m3HapticSelect();
                                    setState(() => _filter = f);
                                  },
                                ),
                              ),
                            ),
                          ],
                        )
                      : _WeekBody(
                          key: const ValueKey('week'),
                          weekStart: _weekStart,
                          dayKeys: _dayKeys,
                          onJump: _jumpToDay,
                          filter: context.watch<SyncService>().isBound
                              ? _filter
                              : PlanFilter.all,
                          onFilterChanged: (f) {
                            m3HapticSelect();
                            setState(() => _filter = f);
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 周完成进度条（仅自己的任务）。
class _WeekProgressInline extends StatelessWidget {
  const _WeekProgressInline();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final (done, total) = store.weekStat(weekStartOf(today()));
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '本周 $done/$total',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: total > 0 && done == total
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: M3EWavyProgress(
              value: total > 0 ? done / total : 0,
              height: 6,
            ),
          ),
        ],
      ),
    );
  }
}

class _DateNavRow extends StatelessWidget {
  const _DateNavRow({
    required this.selected,
    required this.onShift,
    required this.onBackToday,
    required this.onPickDate,
  });

  final DateTime selected;
  final void Function(int days) onShift;
  final VoidCallback onBackToday;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    final isToday = dateKey(selected) == dateKey(today());
    return Row(
      children: [
        IconButton(
          tooltip: '前一天',
          onPressed: () => onShift(-1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onPickDate,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '${monthDay(selected)} ${weekdayCn(selected)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: '后一天',
          onPressed: () => onShift(1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
        if (!isToday)
          TextButton(onPressed: onBackToday, child: const Text('回今天')),
      ],
    );
  }
}

/// 筛选下拉：全部/我的/对方。
class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({required this.filter, required this.onSelected});

  final PlanFilter filter;
  final void Function(PlanFilter) onSelected;

  @override
  Widget build(BuildContext context) {
    final couple = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final partnerLabel = couple.isBound && couple.partnerName.isNotEmpty
        ? couple.partnerName
        : '对方';
    final label = switch (filter) {
      PlanFilter.all => '全部',
      PlanFilter.mine => '我的',
      PlanFilter.ta => partnerLabel,
    };
    return PopupMenuButton<PlanFilter>(
      initialValue: filter,
      onSelected: onSelected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      itemBuilder: (context) => [
        for (final f in PlanFilter.values)
          PopupMenuItem(
            value: f,
            child: Row(
              children: [
                Icon(
                  switch (f) {
                    PlanFilter.all => Icons.apps_rounded,
                    PlanFilter.mine => Icons.person_rounded,
                    PlanFilter.ta => Icons.favorite_rounded,
                  },
                  size: 16,
                  color: filter == f ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  switch (f) {
                    PlanFilter.all => '全部',
                    PlanFilter.mine => '我的',
                    PlanFilter.ta => '对方（$partnerLabel）',
                  },
                  style: TextStyle(
                    fontSize: 13,
                    color: filter == f ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, {this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 某天任务展示，带筛选。
class DayTaskSection extends StatelessWidget {
  const DayTaskSection({
    super.key,
    required this.date,
    required this.filter,
    this.onFilterChanged,
  });

  final DateTime date;
  final PlanFilter filter;
  final void Function(PlanFilter)? onFilterChanged;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final couple = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final key = dateKey(date);

    final mine = store.tasksOn(key);
    final partnerTasks = <PlanTask>[];
    if (couple.isBound && couple.partner != null) {
      partnerTasks.addAll(
        couple.partner!.data.tasks
            .where((t) => t.occursOn(date) && !t.archived)
            .toList()
          ..sort((a, b) {
            if (a.done != b.done) return a.done ? 1 : -1;
            if (a.starred != b.starred) return a.starred ? -1 : 1;
            return timeSortKey(a.start).compareTo(timeSortKey(b.start));
          }),
      );
    }

    final showMine = filter == PlanFilter.all || filter == PlanFilter.mine;
    final showTa = filter == PlanFilter.all || filter == PlanFilter.ta;

    final sections = <Widget>[];
    // 筛选入口独立于「我的」卡片：选「对方」后卡片消失不会把入口一起带走。
    final filterRow = (couple.isBound && onFilterChanged != null)
        ? Align(
            alignment: Alignment.centerLeft,
            child: _FilterDropdown(
              filter: filter,
              onSelected: onFilterChanged!,
            ),
          )
        : null;
    if (showMine && mine.isNotEmpty) {
      sections.add(
        _TaskRowsSection(title: '我的', tasks: mine, scope: 'day', anchor: date),
      );
    }
    if (showTa && partnerTasks.isNotEmpty && couple.partner != null) {
      sections.add(const _SectionHeader('TA 的'));
      sections.add(
        _TaskCard(
          children: [
            for (var i = 0; i < partnerTasks.length; i++) ...[
              if (i > 0) Divider(indent: 64, color: scheme.outlineVariant),
              PartnerTaskRow(
                key: ValueKey('partner-day-${partnerTasks[i].id}'),
                task: partnerTasks[i],
                day: date,
                onTap: () =>
                    showPartnerTaskSheet(context, partnerTasks[i], day: date),
              ),
            ],
          ],
        ),
      );
    }

    if (sections.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (filterRow != null) ...[filterRow, const SizedBox(height: 10)],
          Card(
            child: SizedBox(
              height: 190,
              child: EmptyState(
                icon: Icons.event_available_rounded,
                title: filter == PlanFilter.ta ? 'TA 这一天还没有安排' : '这一天还没有安排',
                subtitle: filter == PlanFilter.ta
                    ? '点上面的筛选可以切回全部'
                    : '点右下角「+」新建一件今天要做的事',
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (filterRow != null) ...[filterRow, const SizedBox(height: 10)],
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          sections[i],
        ],
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(child: Column(children: children));
  }
}

/// 任务卡：长按弹操作胶囊、拖动磁吸排序；完成行沉底。
class _TaskRowsSection extends StatefulWidget {
  const _TaskRowsSection({
    required this.title,
    required this.tasks,
    required this.scope,
    required this.anchor,
    this.headerTrailing,
    this.emptyHint,
  });

  final String title;
  final Widget? headerTrailing;
  final List<PlanTask> tasks;

  /// 'day' 或 'week'。
  final String scope;
  final DateTime anchor;
  final String? emptyHint;

  @override
  State<_TaskRowsSection> createState() => _TaskRowsSectionState();
}

class _TaskRowsSectionState extends State<_TaskRowsSection> {
  bool _sorting = false;

  void _reorder(int from, int to) {
    final store = context.read<AppStore>();
    if (widget.scope == 'day') {
      store.reorderTaskOn(dateKey(widget.anchor), from, to);
    } else {
      store.reorderWeekTask(from, to);
    }
  }

  void _move(String taskId, int delta) {
    final store = context.read<AppStore>();
    if (widget.scope == 'day') {
      store.moveTaskUpDown(dateKey(widget.anchor), taskId, delta);
    } else {
      store.moveWeekTaskUpDown(taskId, delta);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final undone = widget.tasks
        .where((t) => !t.isDoneOn(widget.anchor))
        .toList();
    final done = widget.tasks.where((t) => t.isDoneOn(widget.anchor)).toList();

    final header = _SectionHeader(
      widget.title,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?widget.headerTrailing,
          IconButton(
            tooltip: _sorting ? '完成排序' : '调整顺序',
            icon: Icon(
              _sorting ? Icons.check_rounded : Icons.swap_vert_rounded,
            ),
            iconSize: 18,
            color: _sorting ? scheme.primary : scheme.onSurfaceVariant,
            onPressed: undone.length < 2
                ? null
                : () {
                    m3HapticSelect();
                    setState(() => _sorting = !_sorting);
                  },
          ),
        ],
      ),
    );

    if (widget.tasks.isEmpty) {
      return Column(
        children: [
          header,
          if (widget.emptyHint != null)
            Text(
              '  ${widget.emptyHint}',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
        ],
      );
    }

    return Column(
      children: [
        header,
        Card(
          child: Column(
            children: [
              MagnetReorder(
                onReorder: _reorder,
                actions: (i) {
                  final t = undone[i];
                  final key = TaskRow.keyFor(widget.scope, widget.anchor, t.id);
                  return [
                    MagnetAction(
                      icon: Icons.edit_outlined,
                      label: '编辑',
                      onTap: () => key.currentState?.editViaMenu(),
                    ),
                    MagnetAction(
                      icon: t.starred
                          ? Icons.star_outline_rounded
                          : Icons.star_rounded,
                      label: t.starred ? '取消置顶' : '置顶',
                      color: scheme.tertiary,
                      onTap: () => key.currentState?.starViaMenu(),
                    ),
                    // 重复任务按循环规则出现在每天，没有「移到今天」的概念，
                    // 旧代码点了只改 date 字段，界面不动却提示已移动。
                    if (!t.isRecurring)
                      MagnetAction(
                        icon: Icons.today_rounded,
                        label: '移到今天',
                        onTap: () => key.currentState?.moveToTodayViaMenu(),
                      ),
                    MagnetAction(
                      icon: Icons.inventory_2_outlined,
                      label: '归档',
                      onTap: () => key.currentState?.archiveViaMenu(),
                    ),
                    MagnetAction(
                      icon: Icons.delete_outline_rounded,
                      label: '删除',
                      color: scheme.error,
                      onTap: () => key.currentState?.deleteViaMenu(),
                    ),
                  ];
                },
                children: [
                  for (var i = 0; i < undone.length; i++)
                    Column(
                      children: [
                        if (i > 0)
                          Divider(
                            indent: 64,
                            color: scheme.outlineVariant,
                            height: 1,
                          ),
                        TaskRow(
                          task: undone[i],
                          day: widget.anchor,
                          index: i,
                          scope: widget.scope,
                          onTap: () =>
                              showTaskEditSheet(context, task: undone[i]),
                          trailing: _sorting
                              ? _Arrows(
                                  upEnabled: i > 0,
                                  downEnabled: i < undone.length - 1,
                                  onUp: () => _move(undone[i].id, -1),
                                  onDown: () => _move(undone[i].id, 1),
                                )
                              : null,
                        ),
                      ],
                    ),
                ],
              ),
              for (var j = 0; j < done.length; j++)
                Column(
                  children: [
                    if (j > 0 || undone.isNotEmpty)
                      Divider(indent: 64, color: scheme.outlineVariant),
                    TaskRow(
                      task: done[j],
                      day: widget.anchor,
                      index: undone.length + j,
                      scope: widget.scope,
                      selfActions: true,
                      onTap: () => showTaskEditSheet(context, task: done[j]),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 排序模式下的上下箭头。
class _Arrows extends StatelessWidget {
  const _Arrows({
    required this.upEnabled,
    required this.downEnabled,
    required this.onUp,
    required this.onDown,
  });

  final bool upEnabled;
  final bool downEnabled;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(IconData icon, bool enabled, VoidCallback onTap) => SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 17),
        color: enabled ? scheme.onSurfaceVariant : scheme.outline,
        onPressed: enabled ? onTap : null,
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.keyboard_arrow_up_rounded, upEnabled, onUp),
        btn(Icons.keyboard_arrow_down_rounded, downEnabled, onDown),
      ],
    );
  }
}

/// 周视图：按日期分节 + 点阵跳转。
class _WeekBody extends StatefulWidget {
  const _WeekBody({
    super.key,
    required this.weekStart,
    required this.dayKeys,
    required this.onJump,
    required this.filter,
    this.onFilterChanged,
  });

  final DateTime weekStart;
  final Map<int, GlobalKey> dayKeys;
  final void Function(int index) onJump;
  final PlanFilter filter;

  /// 提供时在周视图顶部显示「全部 / 我的 / 对方」筛选。
  final void Function(PlanFilter)? onFilterChanged;

  @override
  State<_WeekBody> createState() => _WeekBodyState();
}

class _WeekBodyState extends State<_WeekBody> {
  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final couple = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final filter = couple.isBound ? widget.filter : PlanFilter.all;
    final showMine = filter == PlanFilter.all || filter == PlanFilter.mine;
    final showTa = filter == PlanFilter.all || filter == PlanFilter.ta;
    final todayKey = dateKey(today());

    final dayTasks = <int, List<PlanTask>>{};
    final partnerDayTasks = <int, List<PlanTask>>{};
    for (var i = 0; i < 7; i++) {
      final d = widget.weekStart.add(Duration(days: i));
      dayTasks[i] = showMine ? store.tasksOn(dateKey(d)) : const <PlanTask>[];
      final pt = <PlanTask>[];
      if (showTa && couple.isBound && couple.partner != null) {
        pt.addAll(
          couple.partner!.data.tasks.where((t) => t.occursOn(d) && !t.archived),
        );
      }
      partnerDayTasks[i] = pt;
    }

    final filterRow = (couple.isBound && widget.onFilterChanged != null)
        ? Align(
            alignment: Alignment.centerLeft,
            child: _FilterDropdown(
              filter: filter,
              onSelected: widget.onFilterChanged!,
            ),
          )
        : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 96),
            children: [
              if (filterRow != null) ...[filterRow, const SizedBox(height: 10)],
              if (showMine)
                _TaskRowsSection(
                  title: '本周任务',
                  headerTrailing: Text(
                    '不设日期的任务都在这里完成',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  emptyHint: '不设日期的任务会显示在这里',
                  tasks: store.weekTasks(),
                  scope: 'week',
                  anchor: widget.weekStart,
                ),
              if (showMine) const SizedBox(height: 16),
              for (var i = 0; i < 7; i++)
                if ((dayTasks[i] ?? const []).isNotEmpty ||
                    (partnerDayTasks[i] ?? const []).isNotEmpty) ...[
                  _DaySection(
                    key: widget.dayKeys.putIfAbsent(i, GlobalKey.new),
                    index: i,
                    day: widget.weekStart.add(Duration(days: i)),
                    isToday:
                        dateKey(widget.weekStart.add(Duration(days: i))) ==
                        todayKey,
                    mine: dayTasks[i] ?? const [],
                    partnerTasks: partnerDayTasks[i] ?? const [],
                  ),
                  const SizedBox(height: 10),
                ],
            ],
          ),
        ),
        _WeekRail(
          weekStart: widget.weekStart,
          dayTasks: dayTasks,
          partnerDayTasks: partnerDayTasks,
          onJump: widget.onJump,
        ),
      ],
    );
  }
}

/// 有安排的单日分节。
class _DaySection extends StatelessWidget {
  const _DaySection({
    super.key,
    required this.index,
    required this.day,
    required this.isToday,
    required this.mine,
    required this.partnerTasks,
  });

  final int index;
  final DateTime day;
  final bool isToday;
  final List<PlanTask> mine;
  final List<PlanTask> partnerTasks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final doneCount =
        mine.where((t) => t.isDoneOn(day)).length +
        partnerTasks.where((t) => t.isDoneOn(day)).length;
    final total = mine.length + partnerTasks.length;
    // 拖动组只含未完成任务，索引空间与 reorderTaskOn 一致。
    final undone = mine.where((t) => !t.isDoneOn(day)).toList();
    final done = mine.where((t) => t.isDoneOn(day)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          isToday ? '${monthDay(day)} · 今天' : monthDay(day),
          trailing: Text(
            '$doneCount/$total',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        Card(
          child: Column(
            children: [
              MagnetReorder(
                onReorder: (from, to) => context.read<AppStore>().reorderTaskOn(
                  dateKey(day),
                  from,
                  to,
                ),
                actions: (i) {
                  final key = TaskRow.keyFor('section', day, undone[i].id);
                  return [
                    MagnetAction(
                      icon: Icons.edit_outlined,
                      label: '编辑',
                      onTap: () => key.currentState?.editViaMenu(),
                    ),
                    MagnetAction(
                      icon: Icons.local_fire_department_rounded,
                      label: '删除',
                      color: scheme.error,
                      onTap: () => key.currentState?.deleteViaMenu(),
                    ),
                  ];
                },
                children: [
                  for (var i = 0; i < undone.length; i++)
                    Column(
                      children: [
                        if (i > 0)
                          Divider(
                            indent: 64,
                            color: scheme.outlineVariant,
                            height: 1,
                          ),
                        TaskRow(
                          task: undone[i],
                          day: day,
                          index: i,
                          scope: 'section',
                          onTap: () =>
                              showTaskEditSheet(context, task: undone[i]),
                        ),
                      ],
                    ),
                ],
              ),
              for (var j = 0; j < done.length; j++) ...[
                if (undone.isNotEmpty || j > 0)
                  Divider(indent: 64, color: scheme.outlineVariant),
                TaskRow(
                  task: done[j],
                  day: day,
                  index: 0,
                  scope: 'section',
                  selfActions: true,
                  onTap: () => showTaskEditSheet(context, task: done[j]),
                ),
              ],
              for (var j = 0; j < partnerTasks.length; j++) ...[
                if (mine.isNotEmpty || j > 0)
                  Divider(indent: 64, color: scheme.outlineVariant),
                PartnerTaskRow(
                  key: ValueKey('partner-week-${partnerTasks[j].id}'),
                  task: partnerTasks[j],
                  day: day,
                  onTap: () =>
                      showPartnerTaskSheet(context, partnerTasks[j], day: day),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 点阵进度条：点击跳转分节。
class _WeekRail extends StatelessWidget {
  const _WeekRail({
    required this.weekStart,
    required this.dayTasks,
    required this.partnerDayTasks,
    required this.onJump,
  });

  final DateTime weekStart;
  final Map<int, List<PlanTask>> dayTasks;
  final Map<int, List<PlanTask>> partnerDayTasks;
  final void Function(int index) onJump;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final todayKey = dateKey(today());
    final entries = <int>[];
    for (var i = 0; i < 7; i++) {
      if ((dayTasks[i] ?? const []).isNotEmpty ||
          (partnerDayTasks[i] ?? const []).isNotEmpty) {
        entries.add(i);
      }
    }
    if (entries.isEmpty) return const SizedBox.shrink();

    return Container(
      width: 56,
      margin: const EdgeInsets.only(right: 6, top: 4),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final i in entries)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onJump(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
                child: Column(
                  children: [
                    Text(
                      '${weekStart.add(Duration(days: i)).day}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight:
                            dateKey(weekStart.add(Duration(days: i))) ==
                                todayKey
                            ? FontWeight.bold
                            : FontWeight.w400,
                        color:
                            dateKey(weekStart.add(Duration(days: i))) ==
                                todayKey
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _DotMatrix(
                      tasks: [...?dayTasks[i], ...?partnerDayTasks[i]],
                      day: weekStart.add(Duration(days: i)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 点阵进度条：实心=完成，超过 8 个变细条。
class _DotMatrix extends StatelessWidget {
  const _DotMatrix({required this.tasks, required this.day});

  final List<PlanTask> tasks;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (tasks.isEmpty) {
      return Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    if (tasks.length > 8) {
      final done = tasks.where((t) => t.isDoneOn(day)).length;
      return SizedBox(
        width: 40,
        child: M3EWavyProgress(value: done / tasks.length, height: 5),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tasks.length; i++)
          TweenAnimationBuilder<Color?>(
            tween: ColorTween(
              end: tasks[i].isDoneOn(day)
                  ? scheme.primary
                  : scheme.surfaceContainerHighest,
            ),
            duration: m3Medium,
            curve: m3CurveIn,
            builder: (context, color, _) => Container(
              width: 5,
              height: 5,
              margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
          ),
      ],
    );
  }
}
