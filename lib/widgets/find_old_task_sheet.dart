import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../sync/sync_service.dart';
import '../util/dates.dart';
import 'm3_dialog.dart';

/// 找回旧计划：只列没做完但已过期的计划，选中后复制到今天。
/// 做完的过去计划去「历史计划」页左滑找回，这里不再出现。
Future<void> showFindOldTaskSheet(BuildContext context) async {
  await showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _FindOldTaskSheet(),
  );
}

class _FindOldTaskSheet extends StatefulWidget {
  const _FindOldTaskSheet();

  @override
  State<_FindOldTaskSheet> createState() => _FindOldTaskSheetState();
}

class _FindOldTaskSheetState extends State<_FindOldTaskSheet> {
  final Set<String> _added = {};

  /// 候选：未完成且日期已过去的计划，过期越近的在前。
  List<PlanTask> _candidates(AppStore store) {
    final todayStr = dateKey(today());
    final seen = <String, PlanTask>{};
    for (final t in store.data.tasks) {
      if (t.done || t.archived) continue;
      // 重复任务没有「过期的这一天」（date 只是创建锚点），不在找回范围。
      if (t.isRecurring) continue;
      // 无日期的周任务没有「过去」概念，未来与今天的也不算过期。
      if (t.date.isEmpty || t.date.compareTo(todayStr) >= 0) continue;
      // 重复任务按 doneDates 记完成，当天勾完的不算「没做完」。
      if (t.doneDates.contains(t.date)) continue;
      final prev = seen[t.title];
      if (prev == null ||
          t.date.compareTo(prev.date) > 0 ||
          (t.date == prev.date && t.updatedAt >= prev.updatedAt)) {
        seen[t.title] = t;
      }
    }
    final list = seen.values.toList()
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : b.updatedAt.compareTo(a.updatedAt);
      });
    return list;
  }

  String _subtitle(PlanTask t) {
    final bits = <String>[];
    if (t.date.isNotEmpty) {
      try {
        final p = t.date.split('-');
        final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
        bits.add('${d.month}月${d.day}日');
      } catch (_) {}
    }
    if (t.start.isNotEmpty) bits.add(t.start);
    return bits.isEmpty ? '未设日期' : bits.join(' · ');
  }

  Future<void> _add(PlanTask t) async {
    final store = context.read<AppStore>();
    final sync = context.read<SyncService>();
    final copy = store.addTask(
      title: t.title,
      date: dateKey(today()),
      start: t.start,
      end: t.end,
      remindBefore: t.remindBefore,
    );
    // 经 store 写备注，保证落盘与推送。
    if (t.note.isNotEmpty) store.updateTask(copy.id, note: t.note);
    // 有伴侣时立刻推送，TA 也能看到找回的计划。
    sync.syncNow(push: true);
    if (mounted) {
      setState(() => _added.add(t.title));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final candidates = _candidates(store);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text(
              '找回旧计划',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '没做完的过期计划，点击加到今天',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              child: Text(
                '没有需要找回的计划\n做完的过去计划可在「我的 → 历史计划」里左滑添加到今天',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  for (final t in candidates)
                    ListTile(
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: _added.contains(t.title)
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
                      subtitle: Text(
                        _subtitle(t),
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: _added.contains(t.title)
                          ? Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: scheme.primary,
                            )
                          : IconButton.filledTonal(
                              tooltip: '添加到今天',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _add(t),
                              icon: const Icon(Icons.add_rounded, size: 18),
                            ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
