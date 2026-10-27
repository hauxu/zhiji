import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/colors.dart';
import '../data/models.dart';
import '../theme.dart';
import '../util/dates.dart';
import 'm3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 日期键转友好文案，如 今天/明天/M月d日
String friendlyDateLabel(String key) {
  final parts = key.split('-');
  if (parts.length != 3) return key;
  final d = DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
  final k = dateKey(today());
  if (key == k) return '今天';
  if (key == dateKey(today().add(const Duration(days: 1)))) return '明天';
  return '${d.month}月${d.day}日';
}

/// 新建清单/习惯共用底部弹层。
/// [exists] 用于重名检查。
Future<void> showEntitySheet(
  BuildContext context, {
  required String title,
  required String hint,
  required String confirmLabel,
  required bool Function(String name) exists,
  required void Function(
    String name,
    String color,
    String time,
    bool shared,
    bool coEdit,
    bool reminder,
  )
  onSubmit,
  List<String> suggestions = const [],
  List<String> colors = listColors,
  String initialName = '',
  String? initialColor,
  bool showTime = false,
  String initialTime = '',
  bool showShared = false,
  bool initialShared = false,
  bool initialCoEdit = false,
  bool showReminder = false,
  bool initialReminder = false,
}) {
  return showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EntitySheet(
      title: title,
      hint: hint,
      confirmLabel: confirmLabel,
      exists: exists,
      onSubmit: onSubmit,
      suggestions: suggestions,
      colors: colors,
      initialName: initialName,
      initialColor: initialColor,
      showTime: showTime,
      initialTime: initialTime,
      showShared: showShared,
      initialShared: initialShared,
      initialCoEdit: initialCoEdit,
      showReminder: showReminder,
      initialReminder: initialReminder,
    ),
  );
}

class _EntitySheet extends StatefulWidget {
  const _EntitySheet({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    required this.exists,
    required this.onSubmit,
    required this.suggestions,
    required this.colors,
    this.initialName = '',
    this.initialColor,
    this.showTime = false,
    this.initialTime = '',
    this.showShared = false,
    this.initialShared = false,
    this.initialCoEdit = false,
    this.showReminder = false,
    this.initialReminder = false,
  });

  final String title;
  final String hint;
  final String confirmLabel;
  final bool Function(String name) exists;
  final void Function(
    String name,
    String color,
    String time,
    bool shared,
    bool coEdit,
    bool reminder,
  )
  onSubmit;
  final List<String> suggestions;
  final List<String> colors;
  final String initialName;
  final String? initialColor;
  final bool showTime;
  final String initialTime;
  final bool showShared;
  final bool initialShared;
  final bool initialCoEdit;
  final bool showReminder;
  final bool initialReminder;

  @override
  State<_EntitySheet> createState() => _EntitySheetState();
}

class _EntitySheetState extends State<_EntitySheet> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  late String _color = widget.initialColor ?? widget.colors.first;
  late String _time = widget.initialTime;
  late ListShareMode _shareMode = widget.initialShared
      ? (widget.initialCoEdit ? ListShareMode.coEdit : ListShareMode.readOnly)
      : ListShareMode.off;
  late bool _reminder = widget.initialReminder;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    if (widget.exists(name)) {
      Navigator.of(context).pop();
      showTopToast('已有同名「$name」，换个名字');
      return;
    }
    Navigator.of(context).pop();
    widget.onSubmit(
      name,
      _color,
      _time,
      _shareMode != ListShareMode.off,
      _shareMode == ListShareMode.coEdit,
      _reminder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              autofocus: true,
              controller: _nameController,
              decoration: InputDecoration(hintText: widget.hint),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              onChanged: (_) => setState(() {}),
            ),
            if (widget.suggestions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in widget.suggestions)
                    ActionChip(
                      label: Text(s, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        m3HapticSelect();
                        _nameController.text = s;
                        _nameController.selection = TextSelection.fromPosition(
                          TextPosition(offset: s.length),
                        );
                        setState(() {});
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(
              '颜色',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            _ColorSwatchGrid(
              colors: widget.colors,
              selected: _color,
              onSelect: (c) {
                m3HapticSelect();
                setState(() => _color = c);
              },
            ),

            if (widget.showTime)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      selected: _time.isNotEmpty,
                      avatar: const Icon(Icons.schedule_rounded, size: 16),
                      label: Text(_time.isEmpty ? '设置时间' : _time),
                      onSelected: (_) async {
                        if (_time.isNotEmpty) {
                          m3HapticSelect();
                          setState(() => _time = '');
                          return;
                        }
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.now(),
                        );
                        if (picked != null) {
                          if (!context.mounted) return;
                          m3HapticSelect();
                          setState(() {
                            _time =
                                '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                          });
                        }
                      },
                    ),
                    if (widget.showReminder)
                      FilterChip(
                        selected: _reminder,
                        avatar: Icon(
                          _reminder
                              ? Icons.notifications_active_rounded
                              : Icons.notifications_outlined,
                          size: 16,
                        ),
                        label: Text(
                          _reminder
                              ? '每日提醒 · ${_time.isEmpty ? '20:00' : _time}'
                              : '打卡提醒',
                          style: const TextStyle(fontSize: 13),
                        ),
                        onSelected: (v) {
                          m3HapticSelect();
                          setState(() => _reminder = v);
                        },
                      ),
                  ],
                ),
              ),

            if (widget.showShared)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '同步给 TA',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<ListShareMode>(
                      segments: const [
                        ButtonSegment(
                          value: ListShareMode.off,
                          icon: Icon(Icons.lock_outline_rounded, size: 15),
                          label: Text('仅自己', style: TextStyle(fontSize: 12)),
                        ),
                        ButtonSegment(
                          value: ListShareMode.readOnly,
                          icon: Icon(Icons.visibility_outlined, size: 15),
                          label: Text('共享', style: TextStyle(fontSize: 12)),
                        ),
                        ButtonSegment(
                          value: ListShareMode.coEdit,
                          icon: Icon(Icons.edit_outlined, size: 15),
                          label: Text('共同编辑', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                      selected: {_shareMode},
                      showSelectedIcon: false,
                      onSelectionChanged: (sel) {
                        m3HapticSelect();
                        setState(() => _shareMode = sel.first);
                      },
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                    onPressed: _nameController.text.trim().isEmpty
                        ? null
                        : _submit,
                    child: Text(widget.confirmLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorSwatchGrid extends StatelessWidget {
  const _ColorSwatchGrid({
    required this.colors,
    required this.selected,
    required this.onSelect,
  });

  final List<String> colors;
  final String selected;
  final void Function(String) onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      children: [
        for (final c in colors)
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onSelect(c);
            },
            customBorder: const CircleBorder(),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  width: 2,
                  color: selected == c ? colorFromHex(c) : Colors.transparent,
                ),
              ),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colorFromHex(c),
                  shape: BoxShape.circle,
                ),
                child: selected == c
                    ? Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: colorFromHex(c).computeLuminance() > 0.6
                            ? Colors.black
                            : Colors.white,
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}
