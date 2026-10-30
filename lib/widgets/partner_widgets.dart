import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../sync/couple_models.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import '../util/dates.dart';
import 'm3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// TA 心形小徽标，区分对方同步的内容
class TaBadge extends StatelessWidget {
  const TaBadge({super.key, this.highlight = true});

  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.favorite_rounded, size: 10, color: scheme.primary),
          const SizedBox(width: 3),
          Text(
            'TA',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 对方任务行（只读），点击查看并评价。
class PartnerTaskRow extends StatelessWidget {
  const PartnerTaskRow({
    super.key,
    required this.task,
    required this.day,
    required this.onTap,
  });

  final PlanTask task;
  final DateTime day;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final couple = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final done = task.isDoneOn(day);
    final commentCount = couple.myCommentsFor(task.id, kindTask).length;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? scheme.primary : Colors.transparent,
                    border: done
                        ? null
                        : Border.all(color: scheme.outline, width: 2),
                  ),
                  child: done
                      ? Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: scheme.onPrimary,
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 2),
            const TaBadge(),
            const SizedBox(width: 8),
            const Icon(
              Icons.today_rounded,
              size: 14,
              color: Colors.transparent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                task.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  color: done ? scheme.onSurfaceVariant : scheme.onSurface,
                  decoration: done
                      ? TextDecoration.lineThrough
                      : TextDecoration.none,
                ),
              ),
            ),
            if (commentCount > 0) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 13,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 2),
              Text(
                '$commentCount',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
            if (task.timeLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                task.timeLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

const evaluateReactions = <String>['like', 'love', 'cheer'];

IconData reactionIcon(String? emojiOrKind) => switch (emojiOrKind) {
  'like' || '👍' => Icons.thumb_up_rounded,
  'cheer' || '🎉' => Icons.celebration_rounded,
  _ => Icons.favorite_rounded,
};

Future<void> showEvaluateSheet(
  BuildContext context, {
  required String targetId,
  required String targetKind,
  required String title,
  String kindLabel = '计划',
}) {
  return showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EvaluateSheet(
      targetId: targetId,
      targetKind: targetKind,
      title: title,
      kindLabel: kindLabel,
    ),
  );
}

class _EvaluateSheet extends StatefulWidget {
  const _EvaluateSheet({
    required this.targetId,
    required this.targetKind,
    required this.title,
    required this.kindLabel,
  });

  final String targetId;
  final String targetKind;
  final String title;
  final String kindLabel;

  @override
  State<_EvaluateSheet> createState() => _EvaluateSheetState();
}

class _EvaluateSheetState extends State<_EvaluateSheet> {
  final _textCtrl = TextEditingController();

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendReaction(String kind) async {
    final sync = context.read<SyncService>();
    Navigator.of(context).pop();
    await sync.addComment(
      targetId: widget.targetId,
      targetKind: widget.targetKind,
      displayTitle: widget.title,
      emoji: kind,
    );
    _toastSendError(sync);
  }

  /// 发送失败必须告知（弹层已关闭，否则用户不知道留言没发出去）。
  void _toastSendError(SyncService sync) {
    if (sync.lastError != null) {
      showTopToast('发送失败：${sync.lastError}');
    }
  }

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    final sync = context.read<SyncService>();
    Navigator.of(context).pop();
    await sync.addComment(
      targetId: widget.targetId,
      targetKind: widget.targetKind,
      displayTitle: widget.title,
      text: text,
    );
    _toastSendError(sync);
  }

  @override
  Widget build(BuildContext context) {
    final couple = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final mine = couple.myCommentsFor(widget.targetId, widget.targetKind);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '给 TA 的${widget.kindLabel}评价',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '「${widget.title}」',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final kind in evaluateReactions) ...[
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () {
                        m3HapticSelect();
                        _sendReaction(kind);
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            reactionIcon(kind),
                            size: 22,
                            color: scheme.primary,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            reactionLabel(kind),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (kind != evaluateReactions.last) const SizedBox(width: 10),
                ],
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textCtrl,
              autofocus: true,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(hintText: '写句备注送给 TA……'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _sendText,
                child: const Text('发送备注'),
              ),
            ),
            if (mine.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '我送出的',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              for (final c in mine)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        c.kind == 'emoji'
                            ? reactionIcon(c.emoji)
                            : Icons.chat_bubble_rounded,
                        size: 14,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.kind == 'emoji'
                              ? '${reactionLabel(c.emoji)}了 TA'
                              : c.text,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String _repeatLabel(PlanTask task) {
  if (!task.isRecurring) return '';
  if (task.repeatMode == TaskRepeatMode.daily) return '每天';
  final names = task.repeatWeekdays.map((i) => weekdayLabels[i - 1]).join('、');
  return '每周$names';
}

Future<void> showPartnerTaskSheet(
  BuildContext context,
  PlanTask task, {
  DateTime? day,
}) {
  return showM3Sheet<void>(
    context: context,
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const TaBadge(),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            [
              if (task.isRecurring) _repeatLabel(task),
              if (task.date.isNotEmpty) task.date,
              if (task.timeLabel.isNotEmpty) task.timeLabel,
              if (task.remindBefore > 0) remindBeforeHuman(task.remindBefore),
              task.isDoneOn(day ?? DateTime.now()) ? '已完成' : '还没完成',
            ].where((s) => s.isNotEmpty).join(' · '),
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (task.starred)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.star_rounded,
                    size: 15,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'TA 为这项标了星',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (task.note.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                task.note,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              showEvaluateSheet(
                context,
                targetId: task.id,
                targetKind: kindTask,
                title: task.title,
              );
            },
            icon: const Icon(Icons.favorite_rounded, size: 18),
            label: const Text('评价这个计划'),
          ),
        ],
      ),
    ),
  );
}
