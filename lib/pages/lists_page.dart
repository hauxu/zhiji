import 'dart:async';
import 'dart:io';
import 'dart:ui' show lerpDouble;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../data/colors.dart';
import '../data/models.dart';
import '../data/seed.dart';
import '../data/store.dart';
import '../sync/sync_service.dart';
import '../util/dates.dart';
import '../theme.dart';
import '../ui/breakpoints.dart';
import '../widgets/responsive.dart';
import '../widgets/partner_widgets.dart';
import '../util/attachments.dart';
import '../util/open.dart';
import '../widgets/m3e_progress.dart';
import '../widgets/celebration.dart';
import '../widgets/empty_state.dart';
import '../widgets/burn_effect.dart';
import '../widgets/magnet_reorder.dart';
import '../widgets/slide_action.dart';
import '../widgets/entity_dialog.dart';
import '../widgets/m3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 清单页：独立长久清单。
class ListsPage extends StatefulWidget {
  const ListsPage({super.key});

  @override
  State<ListsPage> createState() => _ListsPageState();
}

class _ListsPageState extends State<ListsPage> {
  String? _selectedListId;
  bool _showDone = false;

  /// TA 共享的清单：页级空态与「全部」视图共用。
  List<TaskList> _partnerSharedLists() {
    final sync = context.watch<SyncService>();
    if (!sync.isBound || sync.partner == null) return const [];
    return sync.partner!.data.lists
        .where((l) => l.shared && l.items.isNotEmpty)
        .toList();
  }

  void _confirmDeleteList(TaskList list) {
    if (list.id == AppStore.unfiledListId) {
      showTopToast('未分类集合不能删除');
      return;
    }
    final store = context.read<AppStore>();
    showM3Dialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除清单「${list.name}」？'),
        content: Text('清单及 ${list.items.length} 个条目将一起删除'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              store.deleteList(list.id);
              setState(() {
                if (_selectedListId == list.id) _selectedListId = null;
              });
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showNewListDialog() {
    showEntitySheet(
      context,
      title: '新建清单',
      hint: '清单名称，比如「想读的书」',
      confirmLabel: '创建',
      suggestions: const ['想读的书', '观影记录', '旅行愿望', '购物清单'],
      exists: (name) =>
          name == AppStore.unfiledListName ||
          context.read<AppStore>().data.lists.any((l) => l.name == name),
      showShared: context.read<SyncService>().isBound,
      // 已绑定时新建清单默认共享，不手动关就一直同步给 TA。
      initialShared: context.read<SyncService>().isBound,
      onSubmit: (name, color, _, shared, coEdit, _) {
        final l = context.read<AppStore>().addList(name, color);
        if (l != null) {
          context.read<AppStore>().setListCoEdit(l.id, coEdit);
          if (shared) context.read<AppStore>().setListShared(l.id, true);
        }
        setState(() => _selectedListId = null);
      },
    );
  }

  void _showQuickAddSheet() {
    final store = context.read<AppStore>();
    final selectedId = _selectedListId;
    var initial = selectedId == null ? null : store.listById(selectedId);
    if (initial == null && selectedId != null) {
      // 选中的清单可能已被同步删除，清掉悬空选中。
      setState(() => _selectedListId = null);
    }
    initial ??= store.ensureUnfiled();
    showM3Sheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) =>
          _QuickAddSheet(store: store, initialTarget: initial),
    );
  }

  void _showEditListDialog(TaskList list) {
    showEntitySheet(
      context,
      title: '编辑清单',
      hint: '清单名称',
      confirmLabel: '保存',
      initialName: list.name,
      initialColor: list.color,
      exists: (name) =>
          name != list.name &&
          (name == AppStore.unfiledListName ||
              context.read<AppStore>().data.lists.any((l) => l.name == name)),
      showShared: context.read<SyncService>().isBound,
      initialShared: list.shared,
      initialCoEdit: list.coEdit,
      onSubmit: (name, color, _, shared, coEdit, _) {
        final store = context.read<AppStore>();
        store.updateList(list.id, name: name, color: color);
        store.setListShared(list.id, shared);
        store.setListCoEdit(list.id, coEdit);
      },
    );
  }

  void _showInspirationSheet() {
    showM3Sheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _InspirationSheet(),
    );
  }

  /// 回收站弹层：任意清单删除的条目，可按原清单恢复或永久删除。
  void _showTrashSheet() {
    showM3Sheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ListTrashSheet(store: context.read<AppStore>()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    // 未分类集合不显示为标签。
    final lists = store.data.lists
        .where((l) => l.id != AppStore.unfiledListId)
        .toList();
    final selected = _selectedListId == null
        ? null
        : store.listById(_selectedListId!);
    final trashCount = store.data.trash.length;

    final expanded = context.isExpanded;
    return PopScope(
      // 清单详情是页内状态：窄屏不接管返回键的话，系统返回会直接退出 App；
      // 桌面双栏不占用返回键。
      canPop: _selectedListId == null || expanded,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        m3HapticSelect();
        setState(() => _selectedListId = null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('清单'),
          actions: [
            IconButton(
              tooltip: trashCount > 0 ? '回收站（$trashCount）' : '回收站',
              onPressed: _showTrashSheet,
              icon: Badge(
                isLabelVisible: trashCount > 0,
                label: Text('$trashCount'),
                child: Icon(
                  trashCount > 0
                      ? Icons.restore_from_trash_rounded
                      : Icons.delete_outline_rounded,
                  size: 22,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: '快速添加',
          onPressed: _showQuickAddSheet,
          child: const Icon(Icons.add_rounded),
        ),
        body: expanded
            ? _DesktopListsBody(
                selected: selected,
                showDone: _showDone,
                onOpenList: (id) => setState(() => _selectedListId = id),
                onBack: () => setState(() => _selectedListId = null),
                onToggleDone: () => setState(() => _showDone = !_showDone),
                onDelete: selected == null
                    ? null
                    : () => _confirmDeleteList(selected),
                onEdit: selected == null
                    ? null
                    : () => _showEditListDialog(selected),
              )
            : ResponsiveContent(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Text(
                        '想长久做的事，和日/周计划分开记录',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          ChoiceChip(
                            selected: _selectedListId == null,
                            onSelected: (_) {
                              m3HapticSelect();
                              setState(() => _selectedListId = null);
                            },
                            label: const Text('全部'),
                          ),
                          const SizedBox(width: 8),
                          for (final l in lists) ...[
                            ChoiceChip(
                              selected: _selectedListId == l.id,
                              onSelected: (_) {
                                m3HapticSelect();
                                setState(() => _selectedListId = l.id);
                              },
                              // 删除入口在清单详情页。
                              label: Text(
                                l.undoneCount > 0
                                    ? '${l.name} ${l.undoneCount}'
                                    : l.name,
                              ),
                              avatar: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: colorFromHex(l.color),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          ActionChip(
                            avatar: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('新建清单'),
                            onPressed: _showNewListDialog,
                          ),
                          const SizedBox(width: 8),
                          ActionChip(
                            avatar: const Icon(
                              Icons.lightbulb_outline_rounded,
                              size: 18,
                            ),
                            label: const Text('灵感库'),
                            onPressed: _showInspirationSheet,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child:
                          lists.isEmpty &&
                              (store.unfiled?.items.isEmpty ?? true)
                          ? _ListsEmptyWithPartner(
                              partnerShared: _partnerSharedLists(),
                              partnerName: context
                                  .read<SyncService>()
                                  .partnerName,
                              onNewList: _showNewListDialog,
                            )
                          : AnimatedSwitcher(
                              duration: m3Medium,
                              switchInCurve: m3CurveIn,
                              switchOutCurve: m3CurveOut,
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      scale: Tween(
                                        begin: 0.96,
                                        end: 1.0,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  ),
                              child: selected == null
                                  ? _AllListsView(
                                      key: const ValueKey('lists-all'),
                                      selectedListId: _selectedListId,
                                      onOpenList: (id) =>
                                          setState(() => _selectedListId = id),
                                    )
                                  : _ListDetail(
                                      key: ValueKey('lists-${selected.id}'),
                                      list: selected,
                                      showDone: _showDone,
                                      onToggleDone: () => setState(
                                        () => _showDone = !_showDone,
                                      ),
                                      onDelete: () =>
                                          _confirmDeleteList(selected),
                                      onBack: () => setState(
                                        () => _selectedListId = null,
                                      ),
                                      onEdit: () =>
                                          _showEditListDialog(selected),
                                    ),
                            ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// 桌面 expanded 下的清单双栏：左侧全部清单，右侧详情。
class _DesktopListsBody extends StatelessWidget {
  const _DesktopListsBody({
    required this.selected,
    required this.showDone,
    required this.onOpenList,
    required this.onBack,
    required this.onToggleDone,
    required this.onDelete,
    required this.onEdit,
  });

  final TaskList? selected;
  final bool showDone;
  final void Function(String listId) onOpenList;
  final VoidCallback onBack;
  final VoidCallback onToggleDone;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 340,
          child: _AllListsView(
            selectedListId: selected?.id,
            onOpenList: onOpenList,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.checklist_rounded,
                          size: 44,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '从左侧选择一个清单',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '点清单查看条目；右键可编辑或删除',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : _ListDetail(
                  key: ValueKey('lists-${selected!.id}'),
                  list: selected!,
                  showDone: showDone,
                  onToggleDone: onToggleDone,
                  onDelete: onDelete ?? () {},
                  onBack: onBack,
                  onEdit: onEdit ?? () {},
                ),
        ),
      ],
    );
  }
}

/// 回收站弹层：任意清单删除的条目，按原清单归位或永久删除。
class _ListTrashSheet extends StatefulWidget {
  const _ListTrashSheet({required this.store});

  final AppStore store;

  @override
  State<_ListTrashSheet> createState() => _ListTrashSheetState();
}

class _ListTrashSheetState extends State<_ListTrashSheet> {
  String _titleOf(TrashEntry t) =>
      t.item.title.trim().isEmpty ? '（无标题）' : t.item.title.trim();

  /// 来源清单名；原清单已删除时提示恢复会回退到未分类。
  String _sourceOf(TrashEntry t) {
    if (t.listId == AppStore.unfiledListId) return AppStore.unfiledListName;
    final l = widget.store.listById(t.listId);
    return l?.name ?? '${AppStore.unfiledListName}（原清单已删除）';
  }

  /// 删除时间的相对描述；旧快照数据没有删除时间。
  String _deletedAgo(int ms) {
    if (ms <= 0) return '旧数据，无删除时间';
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60 * 1000) return '删除于刚刚';
    if (diff < 60 * 60 * 1000) return '删除于 ${diff ~/ (60 * 1000)} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) {
      return '删除于 ${diff ~/ (60 * 60 * 1000)} 小时前';
    }
    return '删除于 ${diff ~/ (24 * 60 * 60 * 1000)} 天前';
  }

  void _restore(TrashEntry t) {
    final ok = widget.store.restoreTrashEntry(t.item.id);
    if (!ok) showTopToast('条目已不存在');
  }

  Future<void> _confirmPermanentDelete(TrashEntry t) async {
    final ok = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('永久删除这条？'),
        content: Text('「${_titleOf(t)}」将被永久删除'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: errorFilledButtonStyle(Theme.of(context)),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    widget.store.permanentlyDeleteTrash(t.item.id);
  }

  Future<void> _confirmClear() async {
    final ok = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空回收站？'),
        content: const Text('清空后无法找回'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: errorFilledButtonStyle(Theme.of(context)),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    widget.store.clearTrash();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final trash = widget.store.data.trash;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '回收站',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      trash.isEmpty
                          ? ''
                          : '${trash.length} 条 · 最多保留 30 条 / 30 天',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (trash.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 36),
                    child: Column(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          size: 34,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '回收站是空的',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: trash.length,
                      itemBuilder: (context, i) {
                        final t = trash[i];
                        final color = widget.store.listById(t.listId)?.color;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: SizedBox(
                            width: 20,
                            height: 20,
                            child: Center(
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: colorFromHex(color ?? '8A8A8A'),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                          title: Text(
                            _titleOf(t),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5),
                          ),
                          subtitle: Text(
                            '来源：${_sourceOf(t)} · ${_deletedAgo(t.deletedAt)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '恢复到原清单',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _restore(t),
                                icon: Icon(
                                  Icons.restore_rounded,
                                  size: 20,
                                  color: scheme.primary,
                                ),
                              ),
                              IconButton(
                                tooltip: '永久删除',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _confirmPermanentDelete(t),
                                icon: Icon(
                                  Icons.delete_forever_outlined,
                                  size: 20,
                                  color: scheme.error,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                if (trash.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: _confirmClear,
                      icon: Icon(
                        Icons.delete_sweep_outlined,
                        size: 18,
                        color: scheme.error,
                      ),
                      label: Text(
                        '清空回收站',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 全部视图：平铺未分类 + 按清单分组
class _AllListsView extends StatefulWidget {
  const _AllListsView({
    super.key,
    required this.onOpenList,
    this.selectedListId,
  });

  final void Function(String listId) onOpenList;
  final String? selectedListId;

  @override
  State<_AllListsView> createState() => _AllListsViewState();
}

class _AllListsViewState extends State<_AllListsView> {
  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final groups = <TaskList, List<ListItem>>{};
    for (final l in store.data.lists) {
      if (l.id == AppStore.unfiledListId) continue; // 未分类单独平铺
      final undone = store.undoneOf(l);
      if (undone.isNotEmpty) groups[l] = undone;
    }
    final unfiled = store.unfiled?.items ?? const <ListItem>[];
    final unfiledUndone = store.undoneOf(store.unfiled);
    final sync = context.watch<SyncService>();
    final partnerShared = sync.isBound && sync.partner != null
        ? sync.partner!.data.lists
              .where((l) => l.shared && l.items.isNotEmpty)
              .toList()
        : <TaskList>[];
    if (groups.isEmpty && unfiled.isEmpty) {
      // 自己没有待办时也要展示 TA 共享的清单。
      if (partnerShared.isNotEmpty) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _PartnerListsSection(
              lists: partnerShared,
              partnerName: sync.partnerName,
            ),
          ],
        );
      }
      return ListView(
        children: [
          const SizedBox(height: 48),
          Card(
            child: SizedBox(
              height: 240,
              child: EmptyState(
                icon: Icons.celebration_rounded,
                title: '全部完成',
                subtitle: '没有待办条目',
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (unfiled.isNotEmpty) ...[
          Card(
            color: widget.selectedListId == AppStore.unfiledListId
                ? scheme.secondaryContainer.withValues(alpha: 0.5)
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  onTap: () => widget.onOpenList(AppStore.unfiledListId),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: scheme.onSurfaceVariant,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            AppStore.unfiledListName,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${unfiledUndone.length}/${unfiled.length}',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                MagnetReorder(
                  onReorder: (from, to) => context
                      .read<AppStore>()
                      .reorderListItem(AppStore.unfiledListId, from, to),
                  actions: (i) => _itemActions(
                    context,
                    scheme,
                    store.unfiled!,
                    unfiledUndone[i],
                  ),
                  children: [
                    for (var i = 0; i < unfiledUndone.length; i++)
                      Column(
                        children: [
                          if (i > 0)
                            Divider(
                              indent: 64,
                              color: scheme.outlineVariant,
                              height: 1,
                            ),
                          ItemRow(
                            key: ItemRow.keyFor(
                              'all',
                              AppStore.unfiledListId,
                              unfiledUndone[i].id,
                            ),
                            scope: 'all',
                            list: store.unfiled!,
                            item: unfiledUndone[i],
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        for (final entry in groups.entries) ...[
          Card(
            color: widget.selectedListId == entry.key.id
                ? scheme.secondaryContainer.withValues(alpha: 0.5)
                : null,
            child: Column(
              children: [
                InkWell(
                  onTap: () => widget.onOpenList(entry.key.id),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: colorFromHex(entry.key.color),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            entry.key.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '共 ${entry.value.length} 项',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                MagnetReorder(
                  onReorder: (from, to) => context
                      .read<AppStore>()
                      .reorderListItem(entry.key.id, from, to),
                  actions: (i) =>
                      _itemActions(context, scheme, entry.key, entry.value[i]),
                  children: [
                    for (var i = 0; i < entry.value.length; i++)
                      Column(
                        children: [
                          if (i > 0)
                            Divider(
                              indent: 64,
                              color: scheme.outlineVariant,
                              height: 1,
                            ),
                          ItemRow(
                            key: ItemRow.keyFor(
                              'all',
                              entry.key.id,
                              entry.value[i].id,
                            ),
                            scope: 'all',
                            list: entry.key,
                            item: entry.value[i],
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (partnerShared.isNotEmpty) ...[
          const SizedBox(height: 12),
          _PartnerListsSection(
            lists: partnerShared,
            partnerName: sync.partnerName,
          ),
        ],
      ],
    );
  }

  List<MagnetAction> _itemActions(
    BuildContext context,
    ColorScheme scheme,
    TaskList list,
    ListItem item,
  ) {
    final key = ItemRow.keyFor('all', list.id, item.id);
    return [
      MagnetAction(
        icon: Icons.check_circle_outline_rounded,
        label: '完成',
        onTap: () => key.currentState?.toggleDoneViaMenu(),
      ),
      MagnetAction(
        icon: Icons.sticky_note_2_outlined,
        label: '备注',
        onTap: () => key.currentState?.noteViaMenu(),
      ),
      MagnetAction(
        icon: Icons.event_outlined,
        label: item.date.isEmpty ? '日期' : '改日期',
        onTap: () async {
          final now = today();
          DateTime? initial;
          if (item.date.isNotEmpty) {
            final p = item.date.split('-');
            if (p.length == 3) {
              initial = DateTime(
                int.parse(p[0]),
                int.parse(p[1]),
                int.parse(p[2]),
              );
            }
          }
          final picked = await showDatePicker(
            context: context,
            initialDate: initial ?? now,
            firstDate: DateTime(now.year - 5),
            lastDate: DateTime(now.year + 10),
          );
          if (!context.mounted) return;
          context.read<AppStore>().setListItemDate(
            list.id,
            item.id,
            picked == null ? '' : dateKey(picked),
          );
        },
      ),
      MagnetAction(
        icon: Icons.attach_file_rounded,
        label: '附件',
        onTap: () => key.currentState?.attachViaMenu(),
      ),
      MagnetAction(
        icon: Icons.local_fire_department_rounded,
        label: '删除',
        color: scheme.error,
        onTap: () => key.currentState?.deleteViaMenu(),
      ),
    ];
  }
}

/// TA 共享的清单：分类级开关控制，只读展示。
/// 清单详情页的同步开关：已绑定时显示，点击弹出
/// 仅自己 / 共享 / 共同编辑 三态选择，详情页内即可控制同步方式。
class _SharedToggleButton extends StatelessWidget {
  const _SharedToggleButton({required this.list});

  final TaskList list;

  Future<void> _pick(BuildContext context) async {
    final store = context.read<AppStore>();
    final picked = await showM3Sheet<ListShareMode>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '同步给 TA',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            for (final mode in const [
              (
                ListShareMode.off,
                Icons.lock_outline_rounded,
                '仅自己',
                '清单对 TA 隐藏',
              ),
              (
                ListShareMode.readOnly,
                Icons.visibility_outlined,
                '共享',
                'TA 可以查看，不能修改',
              ),
              (
                ListShareMode.coEdit,
                Icons.edit_outlined,
                '共同编辑',
                'TA 可以勾选完成、添加条目',
              ),
            ])
              ListTile(
                leading: Icon(
                  mode.$2,
                  size: 20,
                  color: list.shareMode == mode.$1
                      ? Theme.of(sheetContext).colorScheme.primary
                      : Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
                title: Text(mode.$3, style: const TextStyle(fontSize: 14)),
                subtitle: Text(mode.$4, style: const TextStyle(fontSize: 11)),
                trailing: list.shareMode == mode.$1
                    ? Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(mode.$1),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || picked == list.shareMode) return;
    store.setListShared(list.id, picked != ListShareMode.off);
    store.setListCoEdit(list.id, picked == ListShareMode.coEdit);
    m3HapticSelect();
    if (!context.mounted) return;
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    if (!sync.isBound) return const SizedBox.shrink();
    return IconButton(
      tooltip: switch (list.shareMode) {
        ListShareMode.off => '仅自己可见 · 点击设置同步',
        ListShareMode.readOnly => 'TA 可查看 · 点击设置同步',
        ListShareMode.coEdit => '共同编辑 · 点击设置同步',
      },
      onPressed: () => _pick(context),
      icon: Icon(
        switch (list.shareMode) {
          ListShareMode.off => Icons.lock_outline_rounded,
          ListShareMode.readOnly => Icons.visibility_outlined,
          ListShareMode.coEdit => Icons.edit_outlined,
        },
        size: 20,
        color: list.shareMode == ListShareMode.off
            ? Theme.of(context).colorScheme.onSurfaceVariant
            : Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

/// 自己还没有任何清单时的页级空态；TA 有共享清单则一并展示。
class _ListsEmptyWithPartner extends StatelessWidget {
  const _ListsEmptyWithPartner({
    required this.partnerShared,
    required this.partnerName,
    required this.onNewList,
  });

  final List<TaskList> partnerShared;
  final String partnerName;
  final VoidCallback onNewList;

  @override
  Widget build(BuildContext context) {
    if (partnerShared.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _PartnerListsSection(lists: partnerShared, partnerName: partnerName),
          const SizedBox(height: 16),
          Card(
            child: SizedBox(
              height: 200,
              child: EmptyState(
                icon: Icons.checklist_rounded,
                title: '还没有清单',
                subtitle: '记录想长久做的事',
              ),
            ),
          ),
        ],
      );
    }
    return EmptyState(
      key: const ValueKey('lists-empty'),
      icon: Icons.checklist_rounded,
      title: '还没有清单',
      subtitle: '记录想长久做的事',
      action: FilledButton.icon(
        onPressed: onNewList,
        icon: const Icon(Icons.add_rounded),
        label: const Text('新建清单'),
      ),
    );
  }
}

class _PartnerListsSection extends StatelessWidget {
  const _PartnerListsSection({required this.lists, required this.partnerName});

  final List<TaskList> lists;
  final String partnerName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            const TaBadge(),
            const SizedBox(width: 8),
            Text(
              '共享的清单',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final l in lists)
          _PartnerListCard(
            key: ValueKey('pl-${l.id}'),
            list: l,
            partnerName: partnerName,
          ),
      ],
    );
  }
}

/// TA 的一张共享清单卡；共同编辑清单可勾选、添加条目，
/// 修改先写本机 overlay 立即生效，经快照回流给对方。
class _PartnerListCard extends StatefulWidget {
  const _PartnerListCard({
    super.key,
    required this.list,
    required this.partnerName,
  });

  final TaskList list;
  final String partnerName;

  @override
  State<_PartnerListCard> createState() => _PartnerListCardState();
}

class _PartnerListCardState extends State<_PartnerListCard> {
  final _addCtrl = TextEditingController();

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  void _toggleDone(TaskList l, ListItem item) {
    context.read<AppStore>().coEditToggleItem(l.id, item);
    m3HapticSelect();
    context.read<SyncService>().syncNow(push: true);
  }

  void _addItem(TaskList l) {
    final t = _addCtrl.text.trim();
    if (t.isEmpty) return;
    context.read<AppStore>().coEditAddItem(l.id, t);
    _addCtrl.clear();
    FocusScope.of(context).unfocus();
    context.read<SyncService>().syncNow(push: true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = context.watch<AppStore>();
    final l = widget.list;
    final coEdit = l.coEdit;
    // 共同编辑清单展示 overlay 合并视图（自己的勾选/新增即时可见）。
    final items = coEdit ? store.coEditEffectiveItems(l) : l.items;
    final undone = items.where((e) => !e.done).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colorFromHex(l.color),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${widget.partnerName} 的「${l.name}」',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (coEdit) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 10,
                          color: scheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '共同编辑',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  '$undone/${items.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final item in items.take(20))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    if (coEdit)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _toggleDone(l, item),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            item.done
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 15,
                            color: item.done
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      Icon(
                        item.done
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 15,
                        color: item.done
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: item.done
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                          decoration: item.done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                    if (item.date.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.event_outlined,
                        size: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                    if (item.note.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.sticky_note_2_outlined,
                        size: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            if (items.length > 20)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '… 共 ${items.length} 条',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (coEdit) ...[
              const SizedBox(height: 4),
              TextField(
                controller: _addCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '添加到这份清单',
                  prefixIcon: Icon(
                    Icons.add_rounded,
                    size: 18,
                    color: scheme.primary,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addItem(l),
              ),
            ],
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// 单个清单详情：快速添加 + 进度 + 未完成/已完成分组。
class _ListDetail extends StatelessWidget {
  const _ListDetail({
    super.key,
    required this.list,
    required this.showDone,
    required this.onToggleDone,
    required this.onDelete,
    required this.onBack,
    required this.onEdit,
  });

  final TaskList list;
  final bool showDone;
  final VoidCallback onToggleDone;
  final VoidCallback onDelete;
  final VoidCallback onBack;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    // 与拖动排序同一顺序（手动序优先，未排序按插入序）。
    final undone = store.undoneOf(list);
    final done = list.items.where((i) => i.done).toList();
    final progress = list.items.isEmpty ? 0.0 : done.length / list.items.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onBack,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: colorFromHex(list.color),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          list.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 未分类与普通清单一致：可共享、可编辑；仅删除保留限制。
            _SharedToggleButton(list: list),
            IconButton(
              tooltip: '编辑清单',
              onPressed: onEdit,
              icon: Icon(
                Icons.edit_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (list.id != AppStore.unfiledListId)
              IconButton(
                tooltip: '删除清单',
                onPressed: onDelete,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                _QuickAddListBar(list: list),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '已完成 ${done.length}/${list.items.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(progress * 100).round()}%',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                M3EWavyProgress(value: progress),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (undone.isEmpty && done.isEmpty)
          Card(
            child: SizedBox(
              height: 180,
              child: EmptyState(
                icon: Icons.check_circle_outline_rounded,
                title: '还没有条目',
                subtitle: '输入后回车添加',
              ),
            ),
          )
        else ...[
          if (undone.isNotEmpty)
            Card(
              child: MagnetReorder(
                onReorder: (from, to) =>
                    context.read<AppStore>().reorderListItem(list.id, from, to),
                actions: (i) {
                  final key = ItemRow.keyFor('detail', list.id, undone[i].id);
                  return [
                    MagnetAction(
                      icon: Icons.check_circle_outline_rounded,
                      label: '完成',
                      onTap: () => key.currentState?.toggleDoneViaMenu(),
                    ),
                    MagnetAction(
                      icon: Icons.sticky_note_2_outlined,
                      label: '备注',
                      onTap: () => key.currentState?.noteViaMenu(),
                    ),
                    MagnetAction(
                      icon: Icons.event_outlined,
                      label: undone[i].date.isEmpty ? '日期' : '改日期',
                      onTap: () async {
                        final now = today();
                        DateTime? initial;
                        final ds = undone[i].date;
                        if (ds.isNotEmpty) {
                          final p = ds.split('-');
                          if (p.length == 3) {
                            initial = DateTime(
                              int.parse(p[0]),
                              int.parse(p[1]),
                              int.parse(p[2]),
                            );
                          }
                        }
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: initial ?? now,
                          firstDate: DateTime(now.year - 5),
                          lastDate: DateTime(now.year + 10),
                        );
                        if (!context.mounted) return;
                        context.read<AppStore>().setListItemDate(
                          list.id,
                          undone[i].id,
                          picked == null ? '' : dateKey(picked),
                        );
                      },
                    ),
                    MagnetAction(
                      icon: Icons.attach_file_rounded,
                      label: '附件',
                      onTap: () => key.currentState?.attachViaMenu(),
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
                  for (var i = 0; i < undone.length; i++)
                    Column(
                      children: [
                        if (i > 0)
                          Divider(
                            indent: 64,
                            color: scheme.outlineVariant,
                            height: 1,
                          ),
                        ItemRow(
                          key: ItemRow.keyFor('detail', list.id, undone[i].id),
                          scope: 'detail',
                          list: list,
                          item: undone[i],
                        ),
                      ],
                    ),
                ],
              ),
            ),
          if (done.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onToggleDone,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      showDone
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '已完成 ${done.length}',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (showDone)
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < done.length; i++) ...[
                      if (i > 0)
                        Divider(indent: 64, color: scheme.outlineVariant),
                      ItemRow(
                        key: ValueKey('li-done-${done[i].id}'),
                        scope: 'detail',
                        list: list,
                        item: done[i],
                        selfActions: true,
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ],
      ],
    );
  }
}

class ItemRow extends StatefulWidget {
  const ItemRow({
    super.key,
    required this.scope,
    required this.list,
    required this.item,
    this.selfActions = false,
  });

  /// 所在视图作用域（'all' / 'detail'），与 keyFor 一致。
  final String scope;
  final TaskList list;
  final ListItem item;

  /// true = 自带长按/右键操作胶囊。
  final bool selfActions;

  /// 供操作胶囊调用行内动画。
  static final Map<String, GlobalKey<ItemRowState>> _keys = {};

  /// [scope] 区分「全部」视图与详情页，避免过渡帧同一行挂两个同键 GlobalKey。
  static GlobalKey<ItemRowState> keyFor(
    String scope,
    String listId,
    String itemId,
  ) => _keys.putIfAbsent(
    '$scope-$listId-$itemId',
    () => GlobalKey<ItemRowState>(),
  );

  @override
  ItemRowState createState() => ItemRowState();
}

class ItemRowState extends State<ItemRow> with TickerProviderStateMixin {
  late final AnimationController _burnCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );
  late final SlidableController _slideCtrl = SlidableController(this);
  bool _leaving = false;
  late final String _cacheKey =
      '${widget.scope}-${widget.list.id}-${widget.item.id}';

  @override
  void didUpdateWidget(covariant ItemRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 复用时清除上一条目动画残留。
    if (widget.item.id != oldWidget.item.id) {
      _leaving = false;
      _burnCtrl.reset();
    }
  }

  @override
  void dispose() {
    ItemRow._keys.remove(_cacheKey);
    _burnCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  void toggleDoneViaMenu() {
    final store = context.read<AppStore>();
    _setDone(context, store, !widget.item.done);
  }

  void deleteViaMenu() => _confirmDelete(context, context.read<AppStore>());

  void noteViaMenu() => _showNoteSheet();

  void attachViaMenu() => _showAttachmentSheet();

  void _showNoteSheet() {
    final store = context.read<AppStore>();
    final ctrl = TextEditingController(text: widget.item.note);
    final newImages = <String>[];
    showM3Sheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> addImages() async {
            final picked = await ImagePicker().pickMultiImage(
              imageQuality: 82,
              limit: 9,
            );
            for (final p in picked) {
              final saved = await copyIntoAppDir(p.path, 'item_attachments');
              if (saved != null && newImages.length < 9) newImages.add(saved);
            }
            if (picked.isNotEmpty) setSheetState(() {});
          }

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '备注 · ${widget.item.title}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(hintText: '补充说明，留空清除'),
                  ),
                  if (newImages.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 56,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (var i = 0; i < newImages.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      File(newImages[i]),
                                      width: 56,
                                      height: 56,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        width: 56,
                                        height: 56,
                                        color: Theme.of(sheetContext)
                                            .colorScheme
                                            .surfaceContainerHigh,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    right: 0,
                                    child: InkWell(
                                      onTap: () => setSheetState(
                                        () => newImages.removeAt(i),
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        color: Theme.of(sheetContext)
                                            .colorScheme
                                            .scrim
                                            .withValues(alpha: 0.55),
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 12,
                                          color: Theme.of(sheetContext)
                                              .colorScheme
                                              .onSurface,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      IconButton(
                        tooltip: '添加图片（保存在本机）',
                        onPressed: newImages.length >= 9 ? null : addImages,
                        icon: const Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 20,
                        ),
                      ),
                      Text(
                        '图片随附件保存',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(sheetContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          store.setListItemNote(
                            widget.list.id,
                            widget.item.id,
                            ctrl.text,
                          );
                          if (newImages.isNotEmpty) {
                            store.setListItemAttached(
                              widget.list.id,
                              widget.item.id,
                              [...widget.item.attached, ...newImages],
                            );
                          }
                          Navigator.of(sheetContext).pop();
                        },
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(ctrl.dispose);
  }

  void _showAttachmentSheet() {
    final store = context.read<AppStore>();
    showM3Sheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) =>
          _AttachmentSheet(list: widget.list, item: widget.item, store: store),
    );
  }

  Future<void> _confirmDelete(BuildContext context, AppStore store) async {
    if (_leaving) return;
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条？'),
        content: Text('「${widget.item.title}」将移入回收站'),
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
    if (confirmed != true || !mounted) return;
    _leaving = true;
    HapticFeedback.lightImpact();
    try {
      await _burnCtrl.forward().orCancel;
    } catch (_) {
      // 中断时直接落库。
    }
    final itemId = widget.item.id;
    store.deleteListItem(widget.list.id, itemId);
    // 3.4 秒内可撤销：直接按原清单归位。
    showTopToast(
      '已移入回收站',
      actionLabel: '撤销',
      onAction: () => store.restoreTrashEntry(itemId),
    );
  }

  void _setDone(BuildContext context, AppStore store, bool done) {
    if (done) {
      Celebration.complete(context);
      // 3 秒内可撤销打勾。
      showTopToast(
        '「${widget.item.title}」已完成',
        actionLabel: '取消打勾',
        onAction: () =>
            store.setListItemDone(widget.list.id, widget.item.id, false),
      );
    } else {
      Celebration.light();
    }
    store.setListItemDone(widget.list.id, widget.item.id, done);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;

    final tile = InkWell(
      onTap: _leaving ? null : () => _setDone(context, store, !item.done),
      onLongPress: widget.selfActions && !_leaving
          ? () => showActionsPill(context, const Offset(40, 80), [
              MagnetAction(
                icon: Icons.check_circle_outline_rounded,
                label: '取消完成',
                onTap: () => toggleDoneViaMenu(),
              ),
              MagnetAction(
                icon: Icons.local_fire_department_rounded,
                label: '删除',
                color: scheme.error,
                onTap: () => deleteViaMenu(),
              ),
            ])
          : null,
      onSecondaryTapUp: widget.selfActions && !_leaving
          ? (d) => showActionsPill(context, d.globalPosition, [
              MagnetAction(
                icon: Icons.check_circle_outline_rounded,
                label: '取消完成',
                onTap: () => toggleDoneViaMenu(),
              ),
              MagnetAction(
                icon: Icons.local_fire_department_rounded,
                label: '删除',
                color: scheme.error,
                onTap: () => deleteViaMenu(),
              ),
            ])
          : null,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedBuilder(
        animation: _slideCtrl.animation,
        builder: (context, child) {
          final slide = _slideCtrl.animation.value.clamp(0.0, 1.0);
          final radius = lerpDouble(0, 14, slide)!;
          return Container(
            decoration: BoxDecoration(
              color: slide > 0
                  ? scheme.surfaceContainerHigh.withValues(alpha: slide)
                  : null,
              borderRadius: BorderRadius.circular(radius),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: child,
          );
        },
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: Checkbox(
                value: item.done,
                onChanged: _leaving
                    ? null
                    : (v) => _setDone(context, store, v ?? false),
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.35,
                      color: item.done
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface,
                      decoration: item.done
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                    ),
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (item.note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        item.note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (item.date.isNotEmpty) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.event_outlined,
                size: 13,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 2),
              Text(
                '${DateTime.parse(item.date).month}/${DateTime.parse(item.date).day}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            if (item.attached.isNotEmpty) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.attachment_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Slidable(
        key: ValueKey('item-${item.id}'),
        controller: _slideCtrl,
        groupTag: 'goalday',
        endActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.22,
          children: [
            M3SlideAction(
              onTap: () => _confirmDelete(context, store),
              color: scheme.errorContainer,
              iconColor: scheme.onErrorContainer,
              icon: Icons.local_fire_department_rounded,
              label: '删除',
            ),
          ],
        ),
        startActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.22,
          children: [
            M3SlideAction(
              onTap: () {
                if (_leaving) return;
                _setDone(context, store, !item.done);
              },
              color: scheme.primaryContainer,
              iconColor: scheme.onPrimaryContainer,
              icon: item.done ? Icons.undo_rounded : Icons.check_rounded,
              label: item.done ? '撤销' : '完成',
            ),
          ],
        ),
        child: AnimatedBuilder(
          animation: _burnCtrl,
          builder: (context, child) {
            if (!_leaving || _burnCtrl.value == 0) return child!;
            return BurnEffect(t: _burnCtrl.value, child: child!);
          },
          child: tile,
        ),
      ),
    );
  }
}

/// 灵感清单库：模板套用。
class _InspirationSheet extends StatelessWidget {
  const _InspirationSheet();

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '灵感清单库',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '挑一个模板就能开始',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                for (final template in inspirationTemplates)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      title: Text(
                        template.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '${template.desc} · ${template.items.length} 项',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: () {
                          final ok = store.addListWithItems(
                            template,
                            listColors.first,
                          );
                          // 重名时不关闭弹层，用户可直接换一个模板。
                          if (!ok) return;
                          Navigator.of(context).pop();
                        },
                        child: const Text('套用'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAddListBar extends StatefulWidget {
  const _QuickAddListBar({required this.list});

  final TaskList list;

  @override
  State<_QuickAddListBar> createState() => _QuickAddListBarState();
}

class _QuickAddListBarState extends State<_QuickAddListBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!mounted) return; // 组件卸载触发的失焦不再提交
    final hadFocus = _focused;
    setState(() => _focused = _focus.hasFocus);
    // 失焦时自动提交未保存文字。
    if (hadFocus && !_focus.hasFocus && _ctrl.text.trim().isNotEmpty) {
      _submit();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    context.read<AppStore>().addListItem(widget.list.id, v);
    m3HapticSelect();
    _ctrl.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      textInputAction: TextInputAction.done,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: '添加到「${widget.list.name}」，回车确认',
        prefixIcon: const Icon(Icons.add_rounded, size: 20),
        suffixIcon: _focused && _ctrl.text.trim().isNotEmpty
            ? IconButton(
                tooltip: '保存',
                visualDensity: VisualDensity.compact,
                onPressed: _submit,
                icon: Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
              )
            : null,
      ),
    );
  }
}

class _AttachmentSheet extends StatefulWidget {
  const _AttachmentSheet({
    required this.list,
    required this.item,
    required this.store,
  });

  final TaskList list;
  final ListItem item;
  final AppStore store;

  @override
  State<_AttachmentSheet> createState() => _AttachmentSheetState();
}

class _AttachmentSheetState extends State<_AttachmentSheet> {
  late final List<String> _paths = List<String>.from(widget.item.attached);
  bool _busy = false;

  Future<void> _addImages() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picker = ImagePicker();
      final pics = await picker.pickMultiImage(imageQuality: 82);
      for (final p in pics) {
        final saved = await copyIntoAppDir(p.path, 'item_attachments');
        if (saved != null) _paths.add(saved);
      }
      // 先落库（context-free），弹层已关闭也不丢附件。
      widget.store.setListItemAttached(widget.list.id, widget.item.id, _paths);
      if (!mounted) return;
      setState(() {});
    } catch (_) {
      // 选图取消/失败时静默返回。
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFile() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: '文件')],
      );
      if (file == null) return;
      final saved = await copyIntoAppDir(file.path, 'item_attachments');
      if (saved == null) return;
      _paths.add(saved);
      // 先落库（context-free），弹层已关闭也不丢附件。
      widget.store.setListItemAttached(widget.list.id, widget.item.id, _paths);
      if (!mounted) return;
      setState(() {});
    } catch (_) {
      // 用户取消或类型不支持时静默返回。
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove(int index) {
    final removed = _paths.removeAt(index);
    setState(() {});
    widget.store.setListItemAttached(widget.list.id, widget.item.id, _paths);
    // 先落数据再删文件：别的条目/共同编辑里可能还引用同一个路径。
    unawaited(
      widget.store.removeAttachmentsIfUnused([removed], 'item_attachments'),
    );
  }

  bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '附件 · ${widget.item.title}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (_paths.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  '暂无附件，图片和文件只存本机',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < _paths.length; i++)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _isImage(_paths[i])
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(_paths[i]),
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Icon(
                                    Icons.image_outlined,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : Icon(
                                Icons.insert_drive_file_outlined,
                                color: scheme.onSurfaceVariant,
                              ),
                        title: Text(
                          _paths[i]
                              .split(Platform.pathSeparator)
                              .last
                              .split('/')
                              .last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: () => openExternally(_paths[i]),
                        trailing: IconButton(
                          tooltip: '移除',
                          icon: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          onPressed: () => _remove(i),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _addImages,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('图片'),
                ),
                const SizedBox(width: 10),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _addFile,
                  icon: const Icon(Icons.attach_file_rounded, size: 18),
                  label: const Text('文件'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAddSheet extends StatefulWidget {
  const _QuickAddSheet({required this.store, required this.initialTarget});

  final AppStore store;
  final TaskList? initialTarget;

  @override
  State<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<_QuickAddSheet> {
  late final TextEditingController _ctrl = TextEditingController();
  String? _targetId;

  @override
  void initState() {
    super.initState();
    _targetId = widget.initialTarget?.id;
    widget.store.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  List<TaskList> _listChoices() {
    final unfiled = widget.store.unfiled;
    return [
      ?unfiled,
      ...widget.store.data.lists.where((l) => l.id != AppStore.unfiledListId),
    ];
  }

  /// 优先用当前选择，选择已被删除时落到第一个可用清单。
  TaskList? _resolveTarget(List<TaskList> choices) {
    final targetId = _targetId;
    if (targetId != null) {
      for (final l in choices) {
        if (l.id == targetId) return l;
      }
    }
    return choices.isEmpty ? null : choices.first;
  }

  void _submit(TaskList target) {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    m3HapticSelect();
    widget.store.addListItem(target.id, v);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final choices = _listChoices();
    final target = _resolveTarget(choices);
    final targetName = target?.name ?? '选择清单';
    final canSave = target != null && _ctrl.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '快速添加到「$targetName」',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (target != null) _submit(target);
              },
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '想做的事，回车保存',
                prefixIcon: PopupMenuButton<TaskList>(
                  tooltip: '选择清单',
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  onSelected: (l) {
                    m3HapticSelect();
                    setState(() => _targetId = l.id);
                  },
                  itemBuilder: (context) => [
                    for (final l in choices)
                      PopupMenuItem(
                        value: l,
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: colorFromHex(l.color),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              l.name,
                              style: TextStyle(
                                fontSize: 13.5,
                                color: target?.id == l.id
                                    ? scheme.primary
                                    : scheme.onSurface,
                                fontWeight: target?.id == l.id
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: const Icon(Icons.add_rounded, size: 20),
                ),
                suffixIcon: IconButton(
                  tooltip: '保存',
                  onPressed: canSave ? () => _submit(target) : null,
                  icon: Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              target == null ? '没有可用清单，请先新建清单' : '点左侧 + 可切换清单',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
