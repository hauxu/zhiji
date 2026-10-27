import 'package:flutter/material.dart';

import '../widgets/responsive.dart';

import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../data/colors.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../sync/couple_models.dart';
import '../sync/sync_service.dart';
import '../util/dates.dart';
import '../widgets/burn_effect.dart';
import '../widgets/empty_state.dart';
import '../widgets/magnet_reorder.dart';
import '../widgets/celebration.dart';
import '../widgets/slide_action.dart';
import '../widgets/entity_dialog.dart';
import '../widgets/partner_widgets.dart';
import '../widgets/m3_dialog.dart';
import '../theme.dart';
import '../widgets/m3e_progress.dart';
import 'habit_detail_page.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 习惯页：周打卡与本周统计。
class HabitsPage extends StatelessWidget {
  const HabitsPage({super.key});

  void _showNewHabitDialog(BuildContext context) {
    showEntitySheet(
      context,
      title: '新建习惯',
      hint: '习惯名称，如「每天走 6000 步」',
      confirmLabel: '创建',
      colors: habitColors,
      exists: (name) =>
          context.read<AppStore>().data.habits.any((h) => h.name == name),
      showTime: true,
      showReminder: true,
      onSubmit: (name, color, time, _, _, reminder) {
        context.read<AppStore>().addHabit(
          name,
          color,
          time: time,
          reminder: reminder,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final habits = store.habitsDisplay();
    final weekStart = weekStartOf(today());
    final days = List.generate(7, (i) => weekStart.add(Duration(days: i)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('习惯'),
        actions: const [_WeekCheckinInline()],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新建习惯',
        onPressed: () => _showNewHabitDialog(context),
        child: const Icon(Icons.add_rounded),
      ),
      body: ResponsiveContent(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            const SizedBox(height: 4),
            if (habits.isEmpty)
              Card(
                child: SizedBox(
                  height: 260,
                  child: EmptyState(
                    icon: Icons.emoji_events_outlined,
                    title: '还没有习惯',
                    subtitle: '从一个简单的习惯开始',
                    action: FilledButton.icon(
                      onPressed: () => _showNewHabitDialog(context),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('新建习惯'),
                    ),
                  ),
                ),
              )
            else
              MagnetReorder(
                onReorder: (from, to) =>
                    context.read<AppStore>().reorderHabit(from, to),
                actions: (i) {
                  final h = habits[i];
                  final key = HabitCard.keyFor(h.id);
                  final todayDone =
                      h.records[dateKey(today())] == HabitStatus.done;
                  return [
                    MagnetAction(
                      icon: Icons.edit_outlined,
                      label: '编辑',
                      onTap: () => key.currentState?.editViaMenu(),
                    ),
                    if (!todayDone)
                      MagnetAction(
                        icon: Icons.check_circle_outline_rounded,
                        label: '打卡',
                        onTap: () => key.currentState?.checkTodayViaMenu(),
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
                  for (final h in habits)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: HabitCard(
                        key: HabitCard.keyFor(h.id),
                        habit: h,
                        days: days,
                        weekLabel: _weekCountLabel(h, days),
                        onDeleted: () {
                          store.deleteHabit(h.id);
                        },
                      ),
                    ),
                ],
              ),
            const _TaHabitsSection(),
          ],
        ),
      ),
    );
  }

  String _weekCountLabel(Habit h, List<DateTime> days) {
    var n = 0;
    for (final d in days) {
      if (h.records[dateKey(d)] == HabitStatus.done) n++;
    }
    return '本周 $n/7';
  }
}

class HabitCard extends StatefulWidget {
  const HabitCard({
    super.key,
    required this.habit,
    required this.days,
    required this.weekLabel,
    required this.onDeleted,
  });

  final Habit habit;
  final List<DateTime> days;
  final String weekLabel;
  final VoidCallback onDeleted;

  /// 供操作胶囊调用卡内动画。
  static final Map<String, GlobalKey<HabitCardState>> _keys = {};
  static GlobalKey<HabitCardState> keyFor(String habitId) =>
      _keys.putIfAbsent(habitId, () => GlobalKey<HabitCardState>());

  @override
  HabitCardState createState() => HabitCardState();
}

class HabitCardState extends State<HabitCard> with TickerProviderStateMixin {
  late final AnimationController _burnCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );
  late final SlidableController _slideCtrl = SlidableController(this);
  bool _leaving = false;
  late final String _cacheKey = widget.habit.id;

  void editViaMenu() => _showEditSheet();

  void _showEditSheet() {
    final store = context.read<AppStore>();
    final h = widget.habit;
    showEntitySheet(
      context,
      title: '编辑习惯',
      hint: '习惯名称',
      confirmLabel: '保存',
      initialName: h.name,
      initialColor: h.color,
      colors: habitColors,
      showTime: true,
      initialTime: h.time,
      showReminder: true,
      initialReminder: h.reminder,
      exists: (name) =>
          name != h.name && store.data.habits.any((x) => x.name == name),
      onSubmit: (name, color, time, _, _, reminder) {
        store.updateHabit(
          h.id,
          name: name,
          color: color,
          time: time,
          reminder: reminder,
        );
      },
    );
  }

  @override
  void dispose() {
    HabitCard._keys.remove(_cacheKey);
    _burnCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  void checkTodayViaMenu() {
    final store = context.read<AppStore>();
    final day = today();
    if (widget.habit.records[dateKey(day)] == HabitStatus.done) return;
    store.cycleHabitRecord(widget.habit.id, dateKey(day));
    Celebration.complete(context);
  }

  void deleteViaMenu() => _confirmDelete();

  Future<void> _confirmDelete() async {
    if (_leaving) return;
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('烧掉习惯「${widget.habit.name}」？'),
        content: const Text('打卡记录一并删除，无法恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('烧掉'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _leaving = true;
    HapticFeedback.lightImpact();
    try {
      await _burnCtrl.forward().orCancel;
    } catch (_) {
      // 中断时直接落库。
    }
    widget.onDeleted();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final h = widget.habit;
    final days = widget.days;
    final todayKey = dateKey(DateTime.now());

    final card = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => HabitDetailPage(habit: h)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: colorFromHex(h.color),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      h.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (h.time.isNotEmpty) ...[
                    Icon(
                      Icons.schedule_rounded,
                      size: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      h.time,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.weekLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i == 6 ? 0 : 6),
                      child: _DayCell(
                        habit: h,
                        day: days[i],
                        label: weekdayLabels[i],
                        isToday: dateKey(days[i]) == todayKey,
                        onTap: _leaving
                            ? () {}
                            : () => store.cycleHabitRecord(
                                h.id,
                                dateKey(days[i]),
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Slidable(
        key: ValueKey('habit-${h.id}'),
        controller: _slideCtrl,
        groupTag: 'goalday',
        endActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.22,
          children: [
            M3SlideAction(
              onTap: _confirmDelete,
              color: scheme.errorContainer,
              iconColor: scheme.onErrorContainer,
              icon: Icons.local_fire_department_rounded,
              label: '删除',
            ),
          ],
        ),
        child: AnimatedBuilder(
          animation: Listenable.merge([_burnCtrl, _slideCtrl.animation]),
          builder: (context, child) {
            final slide = _slideCtrl.animation.value.clamp(0.0, 1.0);
            Widget result = child!;
            if (slide > 0) {
              result = Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14 * slide),
                ),
                child: result,
              );
            }
            if (_leaving && _burnCtrl.value > 0) {
              result = BurnEffect(t: _burnCtrl.value, child: result);
            }
            return result;
          },
          child: card,
        ),
      ),
    );
  }
}

class _DayCell extends StatefulWidget {
  const _DayCell({
    required this.habit,
    required this.day,
    required this.label,
    required this.isToday,
    required this.onTap,
  });

  final Habit habit;
  final DateTime day;
  final String label;
  final bool isToday;
  final VoidCallback onTap;

  @override
  State<_DayCell> createState() => _DayCellState();
}

class _DayCellState extends State<_DayCell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late final Animation<double> _pop = Tween<double>(
    begin: 0.4,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));

  @override
  void initState() {
    super.initState();
    // 完成态默认全尺寸，打卡时弹跳放大。
    if (widget.habit.records[dateKey(widget.day)] == HabitStatus.done) {
      _ctrl.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant _DayCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同步后完成态保持全尺寸。
    if (widget.habit.records[dateKey(widget.day)] == HabitStatus.done &&
        _ctrl.value == 0) {
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _handleTap(BuildContext context) {
    final before = widget.habit.records[dateKey(widget.day)];
    widget.onTap();
    final after = widget.habit.records[dateKey(widget.day)];
    if (after == HabitStatus.done && before != HabitStatus.done) {
      Celebration.complete(context);
      _ctrl.forward(from: 0);
      // 3 秒内可撤销打卡；先清掉排队中的旧提示，保证准时消失。
      showTopToast(
        '已打卡',
        actionLabel: '取消打卡',
        onAction: () {
          context.read<AppStore>().setHabitRecord(
            widget.habit.id,
            dateKey(widget.day),
            before,
          );
        },
      );
    } else {
      Celebration.light();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = widget.habit.records[dateKey(widget.day)];
    // 过去未打卡与手动点叉共用渲染与点击逻辑。
    final showsMiss =
        status == HabitStatus.miss ||
        (status == null && widget.day.isBefore(today()));

    return Column(
      children: [
        Text(
          widget.label,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: 1,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _handleTap(context),
              borderRadius: BorderRadius.circular(12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: status == HabitStatus.done
                      ? scheme.primary
                      : showsMiss
                      ? scheme.errorContainer
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: widget.isToday
                      ? Border.all(color: scheme.primary, width: 2)
                      : null,
                ),
                child: status == HabitStatus.done
                    ? ScaleTransition(
                        scale: _pop,
                        child: Icon(
                          Icons.check_rounded,
                          size: 22,
                          color: scheme.onPrimary,
                        ),
                      )
                    : showsMiss
                    ? Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: scheme.onErrorContainer,
                      )
                    : null,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// TA 的习惯，只读可点赞。
class _TaHabitsSection extends StatelessWidget {
  const _TaHabitsSection();

  @override
  Widget build(BuildContext context) {
    final couple = context.watch<SyncService>();
    if (!couple.isBound ||
        couple.partner == null ||
        couple.partner!.data.habits.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final habits = couple.partner!.data.habits;
    final weekStart = weekStartOf(today());
    final days = List.generate(7, (i) => weekStart.add(Duration(days: i)));
    final todayKey = dateKey(today());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            const TaBadge(),
            const SizedBox(width: 8),
            Text(
              '${couple.partnerName} 的习惯',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final h in habits) ...[
          Card(
            // 点卡片任意处查看 TA 习惯详情（只读）。
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => HabitDetailPage(habit: h, isPartner: true),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: colorFromHex(h.color),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            h.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: '赞一下',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => showEvaluateSheet(
                            context,
                            targetId: h.id,
                            targetKind: kindHabit,
                            title: h.name,
                            kindLabel: '习惯',
                          ),
                          icon: const Icon(Icons.favorite_rounded, size: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (var i = 0; i < 7; i++)
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(right: i == 6 ? 0 : 6),
                              child: Column(
                                children: [
                                  Text(
                                    weekdayLabels[i],
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  AspectRatio(
                                    aspectRatio: 1,
                                    child: AnimatedContainer(
                                      duration: m3Small,
                                      curve: m3CurveIn,
                                      decoration: BoxDecoration(
                                        color: switch (h.records[dateKey(
                                          days[i],
                                        )]) {
                                          HabitStatus.done => scheme.primary,
                                          HabitStatus.miss =>
                                            scheme.errorContainer,
                                          null => scheme.surfaceContainerHigh,
                                        },
                                        borderRadius: BorderRadius.circular(12),
                                        border: dateKey(days[i]) == todayKey
                                            ? Border.all(
                                                color: scheme.primary,
                                                width: 2,
                                              )
                                            : null,
                                      ),
                                      child: switch (h.records[dateKey(
                                        days[i],
                                      )]) {
                                        HabitStatus.done => Icon(
                                          Icons.check_rounded,
                                          size: 18,
                                          color: scheme.onPrimary,
                                        ),
                                        HabitStatus.miss => Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                          color: scheme.onErrorContainer,
                                        ),
                                        null => null,
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _WeekCheckinInline extends StatelessWidget {
  const _WeekCheckinInline();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final habits = store.data.habits;
    final weekStart = weekStartOf(today());
    var done = 0;
    for (final h in habits) {
      for (var i = 0; i < 7; i++) {
        final d = weekStart.add(Duration(days: i));
        if (h.records[dateKey(d)] == HabitStatus.done) done++;
      }
    }
    final total = habits.length * 7;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '本周打卡 $done/$total',
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
            width: 72,
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
