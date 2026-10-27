import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ai/ai_config.dart';
import '../ai/ai_service.dart';
import '../data/store.dart';
import '../theme.dart';

import '../data/models.dart';
import '../util/dates.dart';
import 'entity_dialog.dart';
import 'm3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 任务编辑弹层：日期、重复、起止时间、结束前提醒；
/// 所有选择仅用着重色表达，可再次点击取消。
Future<void> showTaskEditSheet(
  BuildContext context, {
  PlanTask? task,
  String? defaultDate,
}) {
  // 关闭只走取消/保存/系统返回（均有未保存确认），禁用下拉关闭防误丢草稿。
  return showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    builder: (_) => _TaskEditSheet(task: task, defaultDate: defaultDate),
  );
}

class _TaskEditSheet extends StatefulWidget {
  const _TaskEditSheet({this.task, this.defaultDate});

  final PlanTask? task;
  final String? defaultDate;

  @override
  State<_TaskEditSheet> createState() => _TaskEditSheetState();
}

class _TaskEditSheetState extends State<_TaskEditSheet> {
  late final TextEditingController _title = TextEditingController(
    text: widget.task?.title ?? '',
  );
  late String _date = widget.task?.date ?? widget.defaultDate ?? '';
  late TaskRepeatMode _repeat = widget.task?.repeatMode ?? TaskRepeatMode.none;
  late List<int> _weekdays = List<int>.from(
    widget.task?.repeatWeekdays ?? const [],
  );
  late final bool _starred = widget.task?.starred ?? false;
  late final TextEditingController _note = TextEditingController(
    text: widget.task?.note ?? '',
  );
  String _start = '';
  String _end = '';
  late int _remind = widget.task?.remindBefore ?? 0;

  static const _remindPresets = [0, 15, 30, 60, 120, 1440];
  static const _remindPresetLabels = ['关闭', '15分钟', '30分钟', '1小时', '2小时', '1天'];

  bool get _isCustomRemind => _remind > 0 && !_remindPresets.contains(_remind);

  bool get _isRecurring => _repeat != TaskRepeatMode.none;

  bool get _isCustomDate =>
      _date.isNotEmpty &&
      _date != dateKey(today()) &&
      _date != dateKey(today().add(const Duration(days: 1))) &&
      _date != dateKey(today().add(const Duration(days: 7)));

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    _start = widget.task?.start ?? '';
    _end = widget.task?.end ?? '';
    // 入口只在配置好 AI 时出现：缓存值先渲染，再读一次本机配置刷新。
    AiConfig.load().then((cfg) {
      if (!mounted || cfg.isConfigured == _aiAvailable) return;
      setState(() => _aiAvailable = cfg.isConfigured);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  void _select(VoidCallback fn) {
    m3HapticSelect();
    setState(fn);
  }

  Future<void> _pickDate() async {
    final initial = _parseKey(_date) ?? today();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today().subtract(const Duration(days: 365)),
      lastDate: today().add(const Duration(days: 365 * 2)),
    );
    if (picked != null) {
      setState(() => _date = dateKey(picked));
    }
  }

  Future<void> _pickTime({required bool isStart}) async {
    final current = isStart ? _start : _end;
    TimeOfDay initial = TimeOfDay.now();
    if (current.isNotEmpty) {
      final parts = current.split(':');
      if (parts.length == 2) {
        initial = TimeOfDay(
          hour: int.tryParse(parts[0]) ?? 8,
          minute: int.tryParse(parts[1]) ?? 0,
        );
      }
    }
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    final value =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (isStart) {
        _start = value;
      } else {
        _end = value;
      }
    });
  }

  bool get _weeklyInvalid =>
      _repeat == TaskRepeatMode.weekly && _weekdays.isEmpty;

  bool get _timeInvalid =>
      _start.isNotEmpty && _end.isNotEmpty && !_timeOrderOk;

  bool get _timeOrderOk {
    if (_start.isEmpty || _end.isEmpty) return true;
    final s = _start.split(':').map(int.parse).toList();
    final e = _end.split(':').map(int.parse).toList();
    return s[0] * 60 + s[1] < e[0] * 60 + e[1];
  }

  bool _recognizing = false;

  /// 配置好 AI（启用 + 接口地址 + Key）才显示 ✨ 入口。
  bool _aiAvailable = AiConfig.cached.isConfigured;

  /// 识别输入框内容 → AI 解析 → 填充本表单或直接创建其他类型条目。
  Future<void> _recognize() async {
    if (_recognizing) return;
    if (_title.text.trim().isEmpty) {
      showTopToast('先在输入框写下要做的事，再点 ✨ 识别');
      return;
    }
    setState(() => _recognizing = true);
    try {
      final pick = await AiService.recognize(_title.text);
      if (!mounted) return;
      if (pick.message != null) {
        showTopToast(pick.message!);
        return;
      }
      final store = context.read<AppStore>();
      if (pick.type == 'countdown') {
        final date = pick.date.length == 10
            ? pick.date
            : dateKey(DateTime.now().add(const Duration(days: 7)));
        store.addMilestone(title: pick.title, date: date);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (pick.type == 'habit') {
        store.addHabit(
          pick.title,
          kDefaultSeed.toString().substring(2, 8).toUpperCase(),
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (pick.type == 'list') {
        final unfiled = store.unfiled;
        final items = pick.items.isEmpty ? [pick.title] : pick.items;
        if (unfiled != null) {
          for (final it in items) {
            store.addListItem(unfiled.id, it);
          }
        }
        if (mounted) Navigator.of(context).pop();
        return;
      }
      // plan：填充当前表单。
      setState(() {
        _title.text = pick.title;
        if (pick.date.length == 10) _date = pick.date;
        // 识别出的时刻是「开始时间」，时间段才带结束时间。
        if (pick.time.isNotEmpty) {
          final parts = pick.time.split(':');
          if (parts.length == 2) _start = pick.time;
        }
        if (pick.endTime.isNotEmpty) {
          final parts = pick.endTime.split(':');
          if (parts.length == 2 && pick.time.isNotEmpty) _end = pick.endTime;
        }
        if (pick.location.isNotEmpty && _note.text.trim().isEmpty) {
          _note.text = '地点：${pick.location}';
        }
      });
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty || _weeklyInvalid || _timeInvalid) return;
    // 清空结束时间会一并关闭提醒，明确告知。
    if (_end.isEmpty && _remind > 0) {}
    final store = context.read<AppStore>();
    // 重复任务的锚点：无日期时以今天为起点。
    final anchor = (_isRecurring && _date.isEmpty) ? dateKey(today()) : _date;
    if (_isEdit) {
      store.updateTask(
        widget.task!.id,
        title: title,
        date: anchor,
        repeatMode: _repeat,
        repeatWeekdays: _weekdays,
        start: _start,
        end: _end,
        starred: _starred,
        note: _note.text.trim(),
        remindBefore: _end.isEmpty ? 0 : _remind,
      );
    } else {
      final t = store.addTask(
        title: title,
        date: anchor,
        repeatMode: _repeat,
        repeatWeekdays: _weekdays,
        start: _start,
        end: _end,
        remindBefore: _end.isEmpty ? 0 : _remind,
      );
      if (_starred) store.setTaskStarred(t.id, true);
      if (_note.text.trim().isNotEmpty) {
        store.updateTask(t.id, note: _note.text.trim());
      }
    }
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final task = widget.task!;
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这个任务？'),
        content: Text(task.isRecurring ? '重复任务的全部记录都会被删除' : '删除后无法恢复'),
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
      context.read<AppStore>().deleteTask(task.id);
      Navigator.of(context).pop();
    }
  }

  /// 当前内容签名：与打开时不同即视为有未保存修改。
  String _signature() {
    final weekdays = List<int>.from(_weekdays)..sort();
    return [
      _title.text,
      _note.text,
      _date,
      _start,
      _end,
      _repeat.name,
      weekdays.join(','),
      '$_remind',
    ].join('');
  }

  late final String _initialSignature = _signature();
  bool get _dirty => _signature() != _initialSignature;

  /// 统一的三条退出路径（系统返回/取消/下拉关闭）确认逻辑。
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canSave =
        _title.text.trim().isNotEmpty && !_weeklyInvalid && !_timeInvalid;
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
                    Text(
                      _isEdit ? '编辑任务' : '新任务',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      autofocus: !_isEdit,
                      controller: _title,
                      decoration: InputDecoration(
                        labelText: '任务',
                        suffixIcon: !_aiAvailable
                            ? null
                            : _recognizing
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : IconButton(
                                tooltip: 'AI 识别输入框内容',
                                onPressed: _recognize,
                                icon: Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 22,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _save(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _note,
                      minLines: 1,
                      maxLines: 3,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(
                        labelText: '备注',
                        prefixIcon: Icon(Icons.notes_rounded, size: 20),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _FieldLabel('日期（留空=本周内完成）'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          selected: _date == dateKey(today()),
                          onSelected: (_) => _select(
                            () => _date = _date == dateKey(today())
                                ? ''
                                : dateKey(today()),
                          ),
                          label: const Text('今天'),
                        ),
                        FilterChip(
                          selected:
                              _date ==
                              dateKey(today().add(const Duration(days: 1))),
                          onSelected: (_) => _select(
                            () => _date =
                                _date ==
                                    dateKey(
                                      today().add(const Duration(days: 1)),
                                    )
                                ? ''
                                : dateKey(today().add(const Duration(days: 1))),
                          ),
                          label: const Text('明天'),
                        ),
                        FilterChip(
                          selected:
                              _date ==
                              dateKey(today().add(const Duration(days: 7))),
                          onSelected: (_) => _select(
                            () => _date =
                                _date ==
                                    dateKey(
                                      today().add(const Duration(days: 7)),
                                    )
                                ? ''
                                : dateKey(today().add(const Duration(days: 7))),
                          ),
                          label: const Text('下周'),
                        ),
                        FilterChip(
                          selected: _isCustomDate,
                          onSelected: (_) => _isCustomDate
                              ? _select(() => _date = '')
                              : _pickDate(),
                          label: Text(
                            _isCustomDate ? friendlyDateLabel(_date) : '选择日期…',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _FieldLabel('重复（不设置则仅一次）'),
                    if (_repeat == TaskRepeatMode.weekly && _weekdays.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '每周重复需要至少选择一天',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final mode in TaskRepeatMode.values)
                          FilterChip(
                            selected: _repeat == mode,
                            onSelected: (_) => _select(() {
                              _repeat = _repeat == mode
                                  ? TaskRepeatMode.none
                                  : mode;
                              if (_repeat != TaskRepeatMode.weekly) {
                                _weekdays = [];
                              }
                              if (_weekdays.isEmpty &&
                                  _repeat == TaskRepeatMode.weekly) {
                                _weekdays = [DateTime.now().weekday];
                              }
                            }),
                            label: Text(switch (mode) {
                              TaskRepeatMode.daily => '每天',
                              TaskRepeatMode.weekly => '每周',
                              TaskRepeatMode.none => '不重复',
                            }),
                          ),
                        if (_repeat == TaskRepeatMode.weekly)
                          for (var i = 1; i <= 7; i++)
                            FilterChip(
                              selected: _weekdays.contains(i),
                              onSelected: (_) => _select(() {
                                _weekdays.contains(i)
                                    ? _weekdays.remove(i)
                                    : _weekdays.add(i);
                                _weekdays.sort();
                              }),
                              label: Text(weekdayLabels[i - 1]),
                            ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _FieldLabel('时间（留空=当天完成）'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilterChip(
                          selected: _start.isNotEmpty,
                          onSelected: (_) => _start.isNotEmpty
                              ? _select(() => _start = '')
                              : _pickTime(isStart: true),
                          label: Text(_start.isEmpty ? '开始时间' : _start),
                        ),
                        FilterChip(
                          selected: _end.isNotEmpty,
                          onSelected: (_) => _end.isNotEmpty
                              ? _select(() => _end = '')
                              : _pickTime(isStart: false),
                          label: Text(_end.isEmpty ? '结束时间' : _end),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _timeInvalid ? '结束时间需要晚于开始时间' : '开始、结束可只设一个',
                      style: TextStyle(
                        fontSize: 11,
                        color: _timeInvalid
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _FieldLabel('提醒（结束时间前）'),
                    const SizedBox(height: 8),
                    if (_end.isEmpty)
                      Text(
                        _remind > 0 ? '设置结束时间后生效' : '先设置结束时间',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < _remindPresets.length; i++)
                            FilterChip(
                              selected: _remind == _remindPresets[i],
                              onSelected: (_) =>
                                  _select(() => _remind = _remindPresets[i]),
                              label: Text(_remindPresetLabels[i]),
                            ),
                          FilterChip(
                            selected: _isCustomRemind,
                            onSelected: (_) => _pickCustomRemind(),
                            label: Text(
                              _isCustomRemind
                                  ? remindBeforeHuman(_remind)
                                  : '自定义…',
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
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
                    if (_isEdit)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.error,
                        ),
                        onPressed: _confirmDelete,
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                        ),
                        label: const Text('删除'),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: _confirmDiscard,
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: canSave ? _save : null,
                      child: Text(_isEdit ? '保存' : '创建'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  DateTime? _parseKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  /// 自定义提前量：1 分钟 ~ 7 天。
  Future<void> _pickCustomRemind() async {
    final hCtrl = TextEditingController(
      text: _remind >= 60 ? '${_remind ~/ 60}' : '',
    );
    final mCtrl = TextEditingController(
      text: _remind > 0 ? '${_remind % 60}' : '',
    );
    String? error;
    final ok = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final h = int.tryParse(hCtrl.text.trim()) ?? 0;
            final m = int.tryParse(mCtrl.text.trim()) ?? 0;
            final total = h * 60 + m;
            if (total < 1 || total > 7 * 1440) {
              setDialogState(() => error = '请输入 1 分钟到 7 天之间的提前量');
              return;
            }
            _remind = total;
            Navigator.of(dialogContext).pop(true);
          }

          return AlertDialog(
            title: const Text('自定义提醒提前量'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: hCtrl,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(3),
                          ],
                          decoration: const InputDecoration(labelText: '小时'),
                          onSubmitted: (_) => submit(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: mCtrl,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(3),
                          ],
                          decoration: const InputDecoration(labelText: '分钟'),
                          onSubmitted: (_) => submit(),
                        ),
                      ),
                    ],
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(dialogContext).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('确定')),
            ],
          );
        },
      ),
    );
    hCtrl.dispose();
    mCtrl.dispose();
    if (ok == true && mounted) {
      _select(() {});
    }
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
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
