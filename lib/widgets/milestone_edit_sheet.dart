import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPicker;
import 'package:lunar/lunar.dart';
import 'package:provider/provider.dart';

import '../data/colors.dart';
import '../data/milestone_icons.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../theme.dart';
import '../util/dates.dart';
import 'm3_dialog.dart';

/// 倒数日编辑弹层：日期（公历/农历）、每年重复、多档提醒、颜色与图标。
Future<void> showMilestoneEditSheet(
  BuildContext context, {
  Milestone? milestone,
}) {
  // 关闭只走取消/保存/系统返回（有未保存确认），禁用下拉关闭防误丢草稿。
  return showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    builder: (_) => _MilestoneEditSheet(milestone: milestone),
  );
}

class _MilestoneEditSheet extends StatefulWidget {
  const _MilestoneEditSheet({this.milestone});

  final Milestone? milestone;

  @override
  State<_MilestoneEditSheet> createState() => _MilestoneEditSheetState();
}

class _MilestoneEditSheetState extends State<_MilestoneEditSheet> {
  late final TextEditingController _title = TextEditingController(
    text: widget.milestone?.title ?? '',
  );
  late String _date = widget.milestone?.date ?? dateKey(today());
  late bool _pinned = widget.milestone?.pinned ?? false;
  late String _color = widget.milestone?.color ?? milestoneColors.first;
  late String _icon = widget.milestone?.icon ?? milestoneIcons.keys.first;
  late final List<int> _reminds = List<int>.from(
    widget.milestone?.reminds ?? const [0],
  );
  late final int _customRemindDays =
      widget.milestone?.reminds
          .where((v) => v > 0 && !_remindChoices.contains(v))
          .firstOrNull ??
      0;
  late bool _lunar = widget.milestone?.lunar ?? false;
  late int _lunarMonth = widget.milestone?.lunarMonth ?? 0;
  late int _lunarDay = widget.milestone?.lunarDay ?? 0;
  late bool _lunarLeap = widget.milestone?.lunarLeap ?? false;
  late bool _featured = widget.milestone?.featured ?? true;
  late bool _plusOne = widget.milestone?.plusOne ?? false;
  late bool _highlight = widget.milestone?.highlight ?? false;

  static const _remindChoices = [7, 3, 1, 0];
  late String _repeat = widget.milestone?.repeat ?? 'none';

  bool get _isEdit => widget.milestone != null;

  void _select(VoidCallback fn) {
    m3HapticSelect();
    setState(fn);
  }

  Future<void> _pickDate() async {
    if (_lunar) {
      final picked = await showM3Sheet<(int, int, bool)>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _LunarPickerSheet(
          year: Lunar.fromDate(today()).getYear(),
          initialMonth: _lunarLeap ? -_lunarMonth : _lunarMonth,
          initialDay: _lunarDay,
        ),
      );
      if (picked == null) return;
      final (code, day, _) = picked;
      final leap = code < 0;
      final month = leap ? -code : code;
      final solar = lunarToSolar(
        Lunar.fromDate(today()).getYear(),
        month,
        day,
        leap,
      );
      final anchor =
          solar.isBefore(DateTime(today().year, today().month, today().day))
          ? lunarToSolar(
              Lunar.fromDate(today()).getYear() + 1,
              month,
              day,
              leap,
            )
          : solar;
      _select(() {
        _lunarMonth = month;
        _lunarDay = day;
        _lunarLeap = leap;
        _date = dateKey(DateTime(anchor.year, anchor.month, anchor.day));
      });
      return;
    }
    final now = today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _parseKey(_date) ?? now,
      firstDate: DateTime(now.year - 100, now.month, now.day),
      lastDate: DateTime(now.year + 10, now.month, now.day),
    );
    if (picked != null) {
      setState(() => _date = dateKey(picked));
    }
  }

  void _toggleLunar(bool on) {
    if (!on) {
      _select(() => _lunar = false);
      return;
    }
    final lu = Lunar.fromDate(today());
    final raw = lu.getMonth();
    final leap = raw < 0;
    final month = leap ? -raw : raw;
    final solar = lunarToSolar(lu.getYear(), month, lu.getDay(), leap);
    final anchor =
        solar.isBefore(DateTime(today().year, today().month, today().day))
        ? lunarToSolar(lu.getYear() + 1, month, lu.getDay(), leap)
        : solar;
    _select(() {
      _lunar = true;
      _repeat = 'year';
      _lunarMonth = month;
      _lunarDay = lu.getDay();
      _lunarLeap = leap;
      _date = dateKey(DateTime(anchor.year, anchor.month, anchor.day));
    });
  }

  DateTime? _parseKey(String key) {
    final p = key.split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty || _date.length != 10) return;
    final store = context.read<AppStore>();
    final reminds = [..._reminds]..sort();
    if (_isEdit) {
      final m = store.milestoneById(widget.milestone!.id);
      if (m != null) {
        m
          ..title = title
          ..date = _date
          ..yearly = _repeat == 'year'
          ..pinned = _pinned
          ..color = _color
          ..icon = _icon
          ..reminds = reminds
          ..lunar = _lunar
          ..lunarMonth = _lunarMonth
          ..lunarDay = _lunarDay
          ..lunarLeap = _lunarLeap
          ..featured = _featured
          ..plusOne = _plusOne
          ..highlight = _highlight;
        store.replaceMilestone(m);
      }
    } else {
      store.addMilestone(
        title: title,
        date: _date,
        yearly: _repeat == 'year',
        pinned: _pinned,
        color: _color,
        icon: _icon,
        reminds: reminds,
        lunar: _lunar,
        lunarMonth: _lunarMonth,
        lunarDay: _lunarDay,
        lunarLeap: _lunarLeap,
        featured: _featured,
        plusOne: _plusOne,
        highlight: _highlight,
      );
    }
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final m = widget.milestone!;
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条倒数日？'),
        content: Text('「${m.title}」将被移除'),
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
    if (confirmed == true && mounted) {
      context.read<AppStore>().deleteMilestone(m.id);
      Navigator.of(context).pop();
    }
  }

  /// 当前内容签名：与打开时不同即视为有未保存修改。
  String _signature() {
    final reminds = [..._reminds]..sort();
    return [
      _title.text,
      _date,
      _repeat,
      '$_pinned',
      _color,
      _icon,
      reminds.join(','),
      '$_lunar',
      '$_lunarMonth',
      '$_lunarDay',
      '$_lunarLeap',
      '$_featured',
      '$_plusOne',
      '$_highlight',
      '$_customRemindDays',
    ].join(' ');
  }

  late final String _initialSignature = _signature();
  bool get _dirty => _signature() != _initialSignature;

  Future<void> _confirmDiscard() async {
    if (!_dirty) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      return;
    }
    final discard = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('放弃修改？'),
        content: const Text('未保存的修改会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dirty = _dirty;

    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !dirty) return;
        await _confirmDiscard();
      },
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PreviewCard(
                        title: _title.text.trim().isEmpty
                            ? (widget.milestone?.title.isEmpty ?? true
                                  ? '未命名'
                                  : widget.milestone!.title)
                            : _title.text.trim(),
                        milestone: widget.milestone,
                        date: _date,
                        yearly: _repeat == 'year',
                        repeat: _repeat,
                        color: _color,
                        icon: _icon,
                        pinned: _pinned,
                        lunar: _lunar,
                        lunarMonth: _lunarMonth,
                        lunarDay: _lunarDay,
                        lunarLeap: _lunarLeap,
                        plusOne: _plusOne,
                        highlight: _highlight,
                        reminds: _reminds,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        autofocus: !_isEdit,
                        controller: _title,
                        maxLength: 30,
                        decoration: InputDecoration(
                          labelText: '名称',
                          counterText: '',
                          suffixIcon: IconButton(
                            tooltip: _pinned ? '取消置顶' : '置顶显示',
                            onPressed: () => _select(() => _pinned = !_pinned),
                            icon: Icon(
                              _pinned
                                  ? Icons.push_pin_rounded
                                  : Icons.push_pin_outlined,
                              size: 22,
                              color: _pinned
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        textInputAction: TextInputAction.done,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _save(),
                      ),
                      const SizedBox(height: 16),
                      _FieldLabel('目标日（未来为倒数，过去为正数）'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: _pickDate,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: Text(
                                  _dateText,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, label: Text('公历')),
                              ButtonSegment(value: true, label: Text('农历')),
                            ],
                            selected: {_lunar},
                            onSelectionChanged: (sel) =>
                                _toggleLunar(sel.first),
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _SwitchRow(
                        icon: Icons.push_pin_outlined,
                        label: '置顶',
                        value: _pinned,
                        onChanged: (v) => _select(() => _pinned = v),
                      ),
                      _SwitchRow(
                        icon: Icons.repeat_rounded,
                        label: '重复',
                        value: null,
                        valueLabel: _repeat == 'year'
                            ? '每年重复'
                            : _repeat == 'month'
                            ? '每月重复'
                            : _repeat == 'week'
                            ? '每周重复'
                            : '不重复',
                        onChanged: null,
                        onTap: () async {
                          final picked = await showM3Sheet<String>(
                            context: context,
                            builder: (_) => const _RepeatPickerSheet(),
                          );
                          if (picked != null) _select(() => _repeat = picked);
                        },
                      ),
                      Theme(
                        data: Theme.of(context)
                            .copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 8),
                          title: const Text(
                            '进阶设置',
                            style: TextStyle(fontSize: 14),
                          ),
                          children: [
                            _SwitchRow(
                              icon: Icons.looks_one_outlined,
                              label: '正数包含起始日（+1 天）',
                              value: _plusOne,
                              onChanged: (v) => _select(() => _plusOne = v),
                            ),
                            _SwitchRow(
                              icon: Icons.auto_awesome_rounded,
                              label: '高亮突出',
                              value: _highlight,
                              onChanged: (v) => _select(() => _highlight = v),
                            ),
                            _SwitchRow(
                              icon: Icons.visibility_outlined,
                              label: '在日子页外显',
                              value: _featured,
                              onChanged: (v) => _select(() => _featured = v),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                !_featured
                                    ? '只在「查看全部」里显示'
                                    : _lunar
                                    ? '按农历逐年推算'
                                    : _repeat == 'year'
                                    ? '按月日每年循环'
                                    : _repeat == 'month'
                                    ? '按号日每月循环'
                                    : _repeat == 'week'
                                    ? '按星期每周循环。'
                                    : '可选过去或未来的某一天。',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _FieldLabel('提醒'),
                      const SizedBox(height: 8),
                      _SwitchRow(
                        icon: Icons.notifications_none_rounded,
                        label: '提醒',
                        value: null,
                        onChanged: null,
                        valueLabel: _reminds.isEmpty
                            ? '不提醒'
                            : '提前 ${_reminds.first} 天',
                        onTap: () async {
                          final picked = await showM3Sheet<int>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => _RemindWheelSheet(
                              initialDays: _reminds.isEmpty
                                  ? 0
                                  : _reminds.first,
                            ),
                          );
                          if (picked != null) {
                            _select(() {
                              _reminds
                                ..clear()
                                ..add(picked);
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      _FieldLabel('颜色与图标'),
                      const SizedBox(height: 8),
                      GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 6,
                        childAspectRatio: 0.85,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        children: [
                          for (var i = 0; i < milestoneColors.length; i++)
                            Column(
                              children: [
                                SizedBox(
                                  width: 38,
                                  height: 38,
                                  child: _ColorDot(
                                    color: colorFromHex(milestoneColors[i]),
                                    selected: _color == milestoneColors[i],
                                    onTap: () => _select(
                                      () => _color = milestoneColors[i],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  milestoneColorNames[i],
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          // 旧条目的历史颜色不在新色板时补一个圆点。
                          if (!milestoneColors.contains(_color))
                            Column(
                              children: [
                                SizedBox(
                                  width: 38,
                                  height: 38,
                                  child: _ColorDot(
                                    color: colorFromHex(_color),
                                    selected: true,
                                    onTap: () {},
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '当前',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 5,
                        childAspectRatio: 0.85,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        children: [
                          for (final entry in milestoneIcons.entries)
                            Column(
                              children: [
                                SizedBox(
                                  width: 38,
                                  height: 38,
                                  child: _IconDot(
                                    icon: entry.value,
                                    color: colorFromHex(_color),
                                    selected: _icon == entry.key,
                                    onTap: () =>
                                        _select(() => _icon = entry.key),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  milestoneIconNames[entry.key] ?? '',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // 固定操作条：长表单滚到底也能直接保存。
              Material(
                color: Colors.transparent,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    10,
                    20,
                    12 + MediaQuery.viewPaddingOf(context).bottom,
                  ),
                  child: Row(
                    children: [
                      if (_isEdit) ...[
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.error,
                          ),
                          onPressed: _confirmDelete,
                          child: const Text('删除'),
                        ),
                        const Spacer(),
                      ],
                      TextButton(
                        onPressed: _confirmDiscard,
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: _isEdit ? 2 : 1,
                        child: FilledButton(
                          onPressed: _title.text.trim().isEmpty ? null : _save,
                          child: Text(_isEdit ? '保存' : '添加'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _dateText {
    if (_lunar) {
      final label = lunarLabelOf(_lunarMonth, _lunarDay, _lunarLeap);
      if (label.isNotEmpty) return '农历$label';
    }
    final d = _parseKey(_date);
    if (d == null) return '选择日期';
    // 循环感知：每周/每月显示对应星期与号数。
    if (_repeat == 'week') return '每周${weekdayCn(d)}';
    if (_repeat == 'month') return '每月${d.day}号';
    final now = today();
    if (_date == dateKey(now)) return '今天 · ${d.month}月${d.day}日';
    return '${d.year}年${d.month}月${d.day}日';
  }
}

/// 农历月/日选择器；闰月仅在该农历年存在时出现。
class _LunarPickerSheet extends StatefulWidget {
  const _LunarPickerSheet({
    required this.year,
    this.initialMonth = 0,
    this.initialDay = 0,
  });

  final int year;
  final int initialMonth;
  final int initialDay;

  @override
  State<_LunarPickerSheet> createState() => _LunarPickerSheetState();
}

class _LunarPickerSheetState extends State<_LunarPickerSheet> {
  late final int _leapMonth = LunarYear.fromYear(widget.year).getLeapMonth();
  late int _month = widget.initialMonth;
  late int _day = widget.initialDay;

  static const _monthNames = [
    '正月',
    '二月',
    '三月',
    '四月',
    '五月',
    '六月',
    '七月',
    '八月',
    '九月',
    '十月',
    '冬月',
    '腊月',
  ];
  static const _dayNames = [
    '初一',
    '初二',
    '初三',
    '初四',
    '初五',
    '初六',
    '初七',
    '初八',
    '初九',
    '初十',
    '十一',
    '十二',
    '十三',
    '十四',
    '十五',
    '十六',
    '十七',
    '十八',
    '十九',
    '二十',
    '廿一',
    '廿二',
    '廿三',
    '廿四',
    '廿五',
    '廿六',
    '廿七',
    '廿八',
    '廿九',
    '三十',
  ];

  int get _dayCount {
    final m = LunarMonth.fromYm(widget.year, _month);
    return m?.getDayCount() ?? 30;
  }

  void _pickMonth(int code) {
    m3HapticSelect();
    setState(() {
      _month = code;
      final count = LunarMonth.fromYm(widget.year, code)?.getDayCount() ?? 30;
      if (_day > count) _day = count;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '选择农历日期（${widget.year} 年）',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 14),
            _FieldLabel('月'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 1; i <= 12; i++)
                  FilterChip(
                    selected: _month == i,
                    onSelected: (_) => _pickMonth(i),
                    label: Text(_monthNames[i - 1]),
                  ),
                if (_leapMonth >= 1)
                  FilterChip(
                    selected: _month == -_leapMonth,
                    onSelected: (_) => _pickMonth(-_leapMonth),
                    label: Text('闰${_monthNames[_leapMonth - 1]}'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _FieldLabel('日'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 1; i <= _dayCount; i++)
                  FilterChip(
                    selected: _day == i,
                    onSelected: (_) {
                      m3HapticSelect();
                      setState(() => _day = i);
                    },
                    label: Text(_dayNames[i - 1]),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                onPressed: _month == 0 || _day == 0
                    ? null
                    : () =>
                          Navigator.of(context).pop((_month, _day, _month < 0)),
                child: Text(
                  _month == 0 || _day == 0
                      ? '先选月和日'
                      : '选定 ${_month < 0 ? '闰' : ''}${_monthNames[(_month < 0 ? -_month : _month) - 1]}${_dayNames[_day - 1]}',
                ),
              ),
            ),
            SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            width: selected ? 3 : 0,
            color: Theme.of(context).colorScheme.surface,
          ),
          boxShadow: selected
              ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
            : null,
      ),
    );
  }
}

class _IconDot extends StatelessWidget {
  const _IconDot({
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : null,
          shape: BoxShape.circle,
          border: Border.all(
            width: selected ? 2 : 1,
            color: selected ? color : scheme.outlineVariant,
          ),
        ),
        child: Icon(
          icon,
          size: 19,
          color: selected ? color : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 实时预览：与列表行同款展示，随所选内容即时刷新。
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.title,
    required this.milestone,
    required this.date,
    required this.yearly,
    required this.repeat,
    required this.color,
    required this.icon,
    required this.pinned,
    required this.lunar,
    required this.lunarMonth,
    required this.lunarDay,
    required this.lunarLeap,
    required this.plusOne,
    required this.highlight,
    required this.reminds,
  });

  final String title;
  final Milestone? milestone;
  final String date;
  final bool yearly;
  final String repeat;
  final String color;
  final String icon;
  final bool pinned;
  final bool lunar;
  final int lunarMonth;
  final int lunarDay;
  final bool lunarLeap;
  final bool plusOne;
  final bool highlight;
  final List<int> reminds;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = colorFromHex(color);
    final sample = Milestone(
      id: milestone?.id ?? 'preview',
      title: title,
      date: date,
      yearly: yearly,
      repeat: repeat,
      pinned: pinned,
      color: color,
      icon: icon,
      lunar: lunar,
      lunarMonth: lunarMonth,
      lunarDay: lunarDay,
      lunarLeap: lunarLeap,
      plusOne: plusOne,
      highlight: highlight,
      reminds: reminds,
    );
    final now = today();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: highlight
            ? c.withValues(alpha: 0.16)
            : c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: c.withValues(alpha: highlight ? 0.7 : 0.35),
          width: highlight ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(milestoneIcon(icon), size: 16, color: c),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (pinned) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.push_pin_rounded,
                        size: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    sample.occurrenceLabel,
                    if (sample.remindLabel != '不提醒') sample.remindLabel,
                  ].join(' · '),
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
            sample.daysLabel(now),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

/// 倒数日编辑的开关行：图标 + 标签（可选值文案）+ 右侧开关。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    this.value,
    required this.onChanged,
    this.valueLabel,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? valueLabel;

  /// value 为 null 时该行是选择行（无开关），整行点击触发 onTap。
  final bool? value;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pick = value == null;
    final body = Row(
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
        if (valueLabel != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              valueLabel!,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
        if (!pick)
          Switch(
            value: value!,
            onChanged: (v) => onChanged!(v),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        if (pick)
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
      ],
    );
    // 选择行整行可点；开关行仅开关本身可点。
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: pick ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: body,
      ),
    );
  }
}

/// 循环方式选择面板。
class _RepeatPickerSheet extends StatelessWidget {
  const _RepeatPickerSheet();

  @override
  Widget build(BuildContext context) {
    final options = [
      ('none', '不重复', Icons.radio_button_unchecked_rounded),
      ('week', '每周重复', Icons.date_range_rounded),
      ('month', '每月重复', Icons.calendar_month_rounded),
      ('year', '每年重复', Icons.emoji_events_outlined),
    ];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label, icon) in options)
            ListTile(
              leading: Icon(icon),
              title: Text(label, style: const TextStyle(fontSize: 14)),
              onTap: () {
                m3HapticSelect();
                Navigator.of(context).pop(v);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 提醒滚轮：当天或提前 1-14 天。
class _RemindWheelSheet extends StatefulWidget {
  const _RemindWheelSheet({required this.initialDays});

  final int initialDays;

  @override
  State<_RemindWheelSheet> createState() => _RemindWheelSheetState();
}

class _RemindWheelSheetState extends State<_RemindWheelSheet> {
  late int _days = widget.initialDays.clamp(0, 14);
  late final FixedExtentScrollController _ctrl = FixedExtentScrollController(
    initialItem: _days,
  );

  static String _label(int v) => v == 0 ? '当天提醒' : '提前 $v 天';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Text(
              '提醒时间',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(
            height: 180,
            child: CupertinoPicker(
              scrollController: _ctrl,
              itemExtent: 40,
              magnification: 1.1,
              squeeze: 1.0,
              useMagnifier: true,
              onSelectedItemChanged: (i) {
                m3HapticSelect();
                setState(() => _days = i);
              },
              children: [
                for (var v = 0; v <= 14; v++)
                  Center(
                    child: Text(
                      _label(v),
                      style: TextStyle(
                        fontSize: 16,
                        color: v == 0
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_days),
                child: const Text('确定'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
