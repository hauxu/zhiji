import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../data/colors.dart';
import '../data/milestone_icons.dart';
import '../data/models.dart';
import '../theme.dart';
import '../ui_prefs.dart';
import '../util/dates.dart';
import '../widgets/burn_effect.dart';
import '../widgets/magnet_reorder.dart' show MagnetAction, showActionsPill;
import '../widgets/slide_action.dart';
import '../data/store.dart';
import 'm3_dialog.dart';
import 'milestone_edit_sheet.dart';
import '../pages/milestone_book_page.dart';

/// 「日子」页内嵌的倒数本卡：收起显示最近几条，展开看全部分组。
class MilestoneBookCard extends StatefulWidget {
  const MilestoneBookCard({
    super.key,
    required this.merged,
    required this.partnerName,
    this.coupleMode = false,
    this.collapsedCount,
  });

  /// 双方合并并排好序的条目，第二位标记是否来自 TA。
  final List<(Milestone, bool)> merged;
  final String partnerName;

  /// 情侣「纪念日」卡：读独立设置套。
  final bool coupleMode;

  /// 外部直接指定外显条数（概览卡用），空则按本卡设置。
  final int? collapsedCount;

  @override
  State<MilestoneBookCard> createState() => _MilestoneBookCardState();
}

class _MilestoneBookCardState extends State<MilestoneBookCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final prefs = context.watch<UiPrefs>();
    final collapsedCount = widget.collapsedCount ?? prefs.bookCollapsedCount;
    final merged = widget.merged;
    final featured = merged.where((r) => r.$1.featured).toList();
    final hasHidden =
        featured.length > collapsedCount || featured.length < merged.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 0),
                  child: Text(
                    '倒数本',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                const Spacer(),
                if (hasHidden)
                  TextButton(
                    onPressed: () {
                      m3HapticSelect();
                      if (_expanded) {
                        setState(() => _expanded = false);
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MilestoneBookPage(
                              merged: widget.merged,
                              partnerName: widget.partnerName,
                            ),
                          ),
                        );
                      }
                    },
                    child: Text(_expanded ? '收起' : '查看全部'),
                  ),
                IconButton(
                  tooltip: '添加倒数日',
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
                  onPressed: () => showMilestoneEditSheet(context),
                ),
              ],
            ),
            if (merged.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 0, bottom: 6),
                child: Text(
                  '记下生日、纪念日和重要的日子，一起倒数',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else if (!_expanded && featured.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 0, bottom: 6),
                child: Text(
                  '条目都设为不外显了，点「查看全部」查看',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else if (!_expanded)
              for (final r in featured.take(collapsedCount))
                MilestoneBookRow(
                  key: ValueKey(r.$1.id),
                  milestone: r.$1,
                  mine: !r.$2,
                  partnerName: widget.partnerName,
                )
            else
              ..._grouped(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _grouped(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = today();
    final merged = widget.merged;
    final pinned = merged.where((r) => r.$1.pinned).toList();
    final upcoming = merged
        .where((r) => !r.$1.pinned && !r.$1.isPast(now))
        .toList();
    final past = merged.where((r) => !r.$1.pinned && r.$1.isPast(now)).toList();

    Widget section(String label, List<(Milestone, bool)> rows) => rows.isEmpty
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 0, top: 4, bottom: 2),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final r in rows)
                MilestoneBookRow(
                  key: ValueKey(r.$1.id),
                  milestone: r.$1,
                  mine: !r.$2,
                  partnerName: widget.partnerName,
                ),
            ],
          );

    return [
      section('置顶', pinned),
      section('即将到来', upcoming),
      section('已过去', past),
    ];
  }
}

/// 倒数本条目行：右滑置顶、左滑燃烧删除、点按编辑；TA 的只读。子页面复用。
class MilestoneBookRow extends StatefulWidget {
  const MilestoneBookRow({
    super.key,
    required this.milestone,
    required this.mine,
    required this.partnerName,
    this.coupleMode = false,
  });

  final Milestone milestone;
  final bool mine;
  final String partnerName;

  /// 情侣「纪念日」行：读独立设置套（农历/已过天数）。
  final bool coupleMode;

  @override
  State<MilestoneBookRow> createState() => _MilestoneBookRowState();
}

class _MilestoneBookRowState extends State<MilestoneBookRow>
    with TickerProviderStateMixin {
  late final AnimationController _burnCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );
  late final SlidableController _slideCtrl = SlidableController(this);
  bool _leaving = false;
  Offset _lastPress = Offset.zero;

  @override
  void dispose() {
    _burnCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  /// 长按/右键胶囊：与磁贴组一致的交互入口。
  void _showActions(BuildContext context) {
    if (_leaving || !widget.mine) return;
    final scheme = Theme.of(context).colorScheme;
    showActionsPill(context, _lastPress, [
      MagnetAction(
        icon: Icons.edit_outlined,
        label: '编辑',
        onTap: () =>
            showMilestoneEditSheet(context, milestone: widget.milestone),
      ),
      MagnetAction(
        icon: widget.milestone.pinned
            ? Icons.push_pin_outlined
            : Icons.push_pin_rounded,
        label: widget.milestone.pinned ? '取消置顶' : '置顶',
        onTap: _togglePin,
      ),
      MagnetAction(
        icon: Icons.local_fire_department_rounded,
        label: '删除',
        color: scheme.error,
        onTap: () => _confirmDelete(context),
      ),
    ]);
  }

  /// TA 条目的只读详情。
  void _showPartnerDetail(BuildContext context) {
    final m = widget.milestone;
    showM3Sheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: colorFromHex(m.color).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      milestoneIcon(m.icon),
                      size: 18,
                      color: colorFromHex(m.color),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      m.title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                [
                  m.occurrenceLabel,
                  if (m.repeatLabel.isNotEmpty) m.repeatLabel,
                  if (m.pinned) '置顶',
                  if (m.remindLabel != '不提醒') '提醒：${m.remindLabel}',
                  'TA 添加',
                ].join(' · '),
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                m.daysLabel(today()),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: colorFromHex(m.color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _togglePin() {
    if (_leaving) return;
    m3HapticSelect();
    final store = context.read<AppStore>();
    final m = widget.milestone;
    m.pinned = !m.pinned;
    store.replaceMilestone(m);
  }

  Future<void> _confirmDelete(BuildContext context) async {
    if (_leaving) return;
    // 收起滑动面板，避免燃烧期间残留敞开的删除窗格。
    await _slideCtrl.close();
    if (!context.mounted) return;
    // 关键：先捕获条目 id，燃烧期间列表可能重排（同步轮询/置顶），
    // widget 会被重绑到别的数据上，落库必须用打开确认框时的那条。
    final id = widget.milestone.id;
    final title = widget.milestone.title;
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条倒数日？'),
        content: Text('「$title」将被移除'),
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
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    _leaving = true;
    HapticFeedback.lightImpact();
    final store = context.read<AppStore>();
    try {
      await _burnCtrl.forward().orCancel;
    } catch (_) {
      // 中断时直接落库。
    }
    store.deleteMilestone(id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final prefs = context.watch<UiPrefs>();
    final color = colorFromHex(widget.milestone.color);
    final m = widget.milestone;
    final days = m.daysUntil(today());
    final urgent = !m.isPast(today()) && days >= 0 && days <= 3;

    final row = Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Slidable(
          key: ValueKey('ms-${m.id}'),
          controller: _slideCtrl,
          groupTag: 'goalday',
          startActionPane: widget.mine
              ? ActionPane(
                  motion: const DrawerMotion(),
                  extentRatio: 0.18,
                  children: [
                    M3SlideAction(
                      onTap: _togglePin,
                      color: scheme.tertiaryContainer,
                      iconColor: scheme.onTertiaryContainer,
                      icon: m.pinned
                          ? Icons.push_pin_outlined
                          : Icons.push_pin_rounded,
                      label: m.pinned ? '取消置顶' : '置顶',
                    ),
                  ],
                )
              : null,
          endActionPane: widget.mine
              ? ActionPane(
                  motion: const DrawerMotion(),
                  extentRatio: 0.22,
                  children: [
                    M3SlideAction(
                      onTap: () => _confirmDelete(context),
                      color: scheme.errorContainer,
                      iconColor: scheme.onErrorContainer,
                      icon: Icons.local_fire_department_rounded,
                      label: '删除',
                    ),
                  ],
                )
              : null,
          child: Stack(
            children: [
              if (urgent)
                Positioned(
                  left: 0,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _leaving
                    ? null
                    : widget.mine
                    ? () => showMilestoneEditSheet(context, milestone: m)
                    : () => _showPartnerDetail(context),
                onLongPress: widget.mine ? () => _showActions(context) : null,
                onSecondaryTapUp: widget.mine
                    ? (d) {
                        _lastPress = d.globalPosition;
                        _showActions(context);
                      }
                    : null,
                child: Listener(
                  onPointerDown: (e) => _lastPress = e.position,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: urgent ? 15 : 12,
                      right: 12,
                      top: 10,
                      bottom: 10,
                    ),
                    child: Row(
                      // 名称/日期列与右侧天数基线对齐，底边绝对平齐。
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(
                                  milestoneIcon(m.icon),
                                  size: 16,
                                  color: color,
                                ),
                              ),
                              if (m.pinned)
                                Positioned(
                                  right: -4,
                                  top: -4,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: scheme.surface,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.push_pin_rounded,
                                      size: 10,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                [
                                  m.title,
                                  if (m.pinned) '置顶',
                                  if (!widget.mine) '${widget.partnerName} 添加',
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                // forceStrut 钉住行高，全角字符不再撑行盒。
                                strutStyle: const StrutStyle(
                                  fontSize: 13,
                                  height: 1.35,
                                  forceStrutHeight: true,
                                ),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: _leaving
                                      ? scheme.onSurfaceVariant
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                [
                                  if ((widget.coupleMode
                                          ? prefs.cbookLunar
                                          : prefs.bookLunar) &&
                                      m.lunarLabel().isNotEmpty)
                                    '农历${m.lunarLabel()}'
                                  else
                                    m.occurrenceLabel,
                                  if (m.repeatLabel.isNotEmpty) m.repeatLabel,
                                ].join(' · '),
                                strutStyle: const StrutStyle(
                                  fontSize: 11,
                                  height: 1.3,
                                  forceStrutHeight: true,
                                ),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          m.isPast(today()) &&
                                  !(widget.coupleMode
                                      ? prefs.cbookPastDays
                                      : prefs.bookPastDays)
                              ? m.occurrenceLabel
                              : m.daysLabel(today()),
                          strutStyle: const StrutStyle(
                            fontSize: 12,
                            height: 1.35,
                            forceStrutHeight: true,
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 燃烧删除动画层。
    return AnimatedBuilder(
      animation: _burnCtrl,
      builder: (context, child) => _burnCtrl.value == 0
          ? child!
          : BurnEffect(t: _burnCtrl.value, child: child!),
      child: row,
    );
  }
}
