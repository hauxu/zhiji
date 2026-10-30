import 'package:flutter/material.dart';

import '../widgets/responsive.dart';

import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../sync/sync_service.dart';
import '../util/dates.dart';
import '../ui_prefs.dart';
import '../widgets/book_settings_sheet.dart';
import '../widgets/milestone_book.dart';
import '../widgets/milestone_edit_sheet.dart';

/// 倒数本子页面：完整列表（含未外显条目），已过去分组默认折叠。
/// [source] 决定读写哪套界面设置：日子页与情侣倒数本各控制各的。
enum MilestoneBookSource { journal, couple }

class MilestoneBookPage extends StatefulWidget {
  const MilestoneBookPage({
    super.key,
    required this.merged,
    required this.partnerName,
    this.source = MilestoneBookSource.journal,
  });

  /// 双方合并并排好序的条目，第二位标记是否来自 TA。
  final List<(Milestone, bool)> merged;
  final String partnerName;
  final MilestoneBookSource source;

  @override
  State<MilestoneBookPage> createState() => _MilestoneBookPageState();
}

class _MilestoneBookPageState extends State<MilestoneBookPage> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final couple = widget.source == MilestoneBookSource.couple;
    // 现取合并数据：本地增删改与同步轮询即时反映，删除后不留残影。
    final sync = context.watch<SyncService>();
    final prefs = context.watch<UiPrefs>();
    var merged = sync.mergedMilestones(today());
    final hidePartner = couple ? prefs.cbookHidePartner : prefs.bookHidePartner;
    if (hidePartner) {
      merged = merged.where((r) => !r.$2).toList();
    }
    final now = today();
    final pinned = merged.where((r) => r.$1.pinned).toList();
    final upcoming = merged
        .where((r) => !r.$1.pinned && !r.$1.isPast(now))
        .toList();
    final past = merged.where((r) => !r.$1.pinned && r.$1.isPast(now)).toList();

    final title = couple
        ? (sync.coupleBookName.isEmpty ? '倒数本' : sync.coupleBookName)
        : '倒数本';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: '倒数本设置',
            onPressed: () => showBookSettingsSheet(
              context,
              couple: couple,
              currentName: sync.coupleBookName,
            ),
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showMilestoneEditSheet(context),
        child: const Icon(Icons.add_rounded),
      ),
      body: ResponsiveContent(
        child: merged.isEmpty
            ? Center(
                child: Text(
                  '记下重要的日子，一起倒数',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            : SlidableAutoCloseBehavior(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                  children: [
                    _section(context, '置顶', pinned),
                    _section(context, '即将到来', upcoming),
                    if (past.isNotEmpty) _section(context, '已过去', past),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String label,
    List<(Milestone, bool)> rows,
  ) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final couple = widget.source == MilestoneBookSource.couple;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
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
            coupleMode: couple,
          ),
      ],
    );
  }
}
