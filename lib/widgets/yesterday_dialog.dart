import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../util/dates.dart';
import 'm3_dialog.dart';

/// 昨日未完成任务建议弹窗。
Future<void> maybeShowYesterdaySuggestion(
  BuildContext context,
  AppStore store,
) async {
  final prefs = await SharedPreferences.getInstance();
  final todayStr = dateKey(today());
  if (prefs.getString('gd2_suggest_date') == todayStr) return;

  final yesterday = today().subtract(const Duration(days: 1));
  // 只建议一次性任务。
  final undone = store
      .tasksOn(dateKey(yesterday))
      .where((t) => !t.isDoneOn(yesterday) && !t.isRecurring)
      .toList();
  if (undone.isEmpty) return;

  await prefs.setString('gd2_suggest_date', todayStr);
  if (!context.mounted) return;
  await showM3Dialog<void>(
    context: context,
    builder: (dialogContext) =>
        _SuggestionDialog(yesterday: yesterday, undone: undone),
  );
}

class _SuggestionDialog extends StatefulWidget {
  const _SuggestionDialog({required this.yesterday, required this.undone});

  final DateTime yesterday;
  final List<PlanTask> undone;

  @override
  State<_SuggestionDialog> createState() => _SuggestionDialogState();
}

class _SuggestionDialogState extends State<_SuggestionDialog> {
  late final Set<String> _selected = {for (final t in widget.undone) t.id};

  Future<void> _moveSelected() async {
    final store = context.read<AppStore>();
    final selectedTasks = widget.undone
        .where((t) => _selected.contains(t.id))
        .toList();
    if (selectedTasks.isEmpty) return;
    store.moveTasksToToday(selectedTasks, from: widget.yesterday);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('昨天还有 ${widget.undone.length} 项没完成'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in widget.undone)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _selected.contains(t.id),
                onChanged: (v) => setState(() {
                  v == true ? _selected.add(t.id) : _selected.remove(t.id);
                }),
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              '勾选后移到今天（${monthDay(today())}）',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('忽略'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty ? null : () => _moveSelected(),
          child: const Text('移到今天'),
        ),
      ],
    );
  }
}
