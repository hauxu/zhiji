import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import '../ui/breakpoints.dart';
import '../util/dates.dart';
import '../widgets/m3_dialog.dart';
import '../widgets/responsive.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 归档：任务归档（右滑归档的任务）与消息归档（收藏的留言）两个分栏。
/// 桌面 expanded 下每个分栏都是左列表右详情。
class ArchivedPage extends StatelessWidget {
  const ArchivedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('归档'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '任务'),
              Tab(text: '消息'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_TaskArchiveTab(), _MessageArchiveTab()],
        ),
      ),
    );
  }
}

class _TaskArchiveTab extends StatefulWidget {
  const _TaskArchiveTab();

  @override
  State<_TaskArchiveTab> createState() => _TaskArchiveTabState();
}

class _TaskArchiveTabState extends State<_TaskArchiveTab> {
  String? _selectedId;

  Future<void> _confirmPurge(BuildContext context, AppStore store, t) async {
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('彻底删除？'),
        content: Text('删除后无法恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: errorFilledButtonStyle(Theme.of(context)),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    store.deleteTask(t.id);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final archived = store.data.tasks.where((t) => t.archived).toList();
    if (archived.isEmpty) {
      return const ResponsiveContent(
        child: _ArchivedEmpty(
          icon: Icons.inventory_2_outlined,
          title: '没有归档的任务',
          subtitle: '右滑或长按任务归档',
        ),
      );
    }
    if (context.isExpanded) {
      var selected = archived.first;
      for (final t in archived) {
        if (t.id == _selectedId) {
          selected = t;
          break;
        }
      }
      return Row(
        children: [
          SizedBox(
            width: 320,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                for (final t in archived)
                  Card(
                    child: ListTile(
                      dense: true,
                      selected: t.id == selected.id,
                      leading: Icon(
                        t.done
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: t.id == selected.id
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        t.done ? '已完成' : '已归档',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () => setState(() => _selectedId = t.id),
                    ),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selected.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          selected.done ? '已完成' : '未完成',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (selected.note.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            selected.note,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () => store.restoreTask(selected.id),
                              icon: const Icon(Icons.undo_rounded, size: 18),
                              label: const Text('恢复'),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: scheme.error,
                              ),
                              onPressed: () =>
                                  _confirmPurge(context, store, selected),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                              ),
                              label: const Text('彻底删除'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ResponsiveContent(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final t in archived)
            Card(
              child: ListTile(
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: t.done ? scheme.onSurfaceVariant : scheme.onSurface,
                    decoration: t.done
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                  ),
                ),
                subtitle: t.note.isNotEmpty
                    ? Text(
                        t.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '恢复',
                      icon: const Icon(Icons.undo_rounded, size: 20),
                      onPressed: () => store.restoreTask(t.id),
                    ),
                    IconButton(
                      tooltip: '彻底删除',
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        size: 20,
                        color: scheme.error,
                      ),
                      onPressed: () => _confirmPurge(context, store, t),
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

class _MessageArchiveTab extends StatefulWidget {
  const _MessageArchiveTab();

  @override
  State<_MessageArchiveTab> createState() => _MessageArchiveTabState();
}

class _MessageArchiveTabState extends State<_MessageArchiveTab> {
  String? _selectedId;

  Future<void> _unarchive(String messageId) async {
    try {
      await context.read<SyncService>().unarchiveMessage(messageId);
    } catch (_) {
      if (mounted) showTopToast('取消归档失败，请稍后再试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final items = sync.archivedMessages;
    if (items.isEmpty) {
      return const ResponsiveContent(
        child: _ArchivedEmpty(
          icon: Icons.bookmark_border_rounded,
          title: '没有归档的留言',
          subtitle: '长按留言板消息归档',
        ),
      );
    }
    if (context.isExpanded) {
      Map<String, dynamic> selected = items.first;
      for (final m in items) {
        if ('${m['id']}' == _selectedId) {
          selected = m;
          break;
        }
      }
      return Row(
        children: [
          SizedBox(
            width: 320,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                for (final m in items)
                  Card(
                    child: ListTile(
                      dense: true,
                      selected: '${m['id']}' == '${selected['id']}',
                      leading: Icon(
                        Icons.bookmark_rounded,
                        size: 20,
                        color: '${m['id']}' == '${selected['id']}'
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      title: Text(
                        '${m['sender'] ?? ''}',
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '${m['text'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () => setState(() => _selectedId = '${m['id']}'),
                    ),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${selected['sender'] ?? ''} · '
                          '${_archiveDate(selected['createdAt'])}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          '${selected['text'] ?? ''}',
                          style: const TextStyle(fontSize: 15, height: 1.6),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.tonalIcon(
                          onPressed: () => _unarchive('${selected['id']}'),
                          icon: const Icon(
                            Icons.bookmark_remove_rounded,
                            size: 18,
                          ),
                          label: const Text('取消归档'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ResponsiveContent(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final m in items)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${m['sender'] ?? ''} · '
                            '${_archiveDate(m['createdAt'])}',
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${m['text'] ?? ''}',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '取消归档',
                      icon: const Icon(Icons.bookmark_remove_rounded, size: 20),
                      onPressed: () => _unarchive('${m['id']}'),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '归档只存本机，TA 撤回不影响',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArchivedEmpty extends StatelessWidget {
  const _ArchivedEmpty({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

String _archiveDate(dynamic ms) {
  if (ms is! int || ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final today = DateTime.now();
  if (dateKey(d) == dateKey(today)) return '今天';
  if (dateKey(d) == dateKey(today.subtract(const Duration(days: 1)))) {
    return '昨天';
  }
  return '${d.month}月${d.day}日';
}
