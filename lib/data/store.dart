import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'seed.dart';
import '../util/attachments.dart';
import '../util/dates.dart';

/// 全局本地状态：数据持久化，损坏时回退种子数据。
class AppStore extends ChangeNotifier {
  static const _storageKey = 'goalday-m3:app-v2';

  late AppData data;
  SharedPreferences? _prefs;
  final Random _rng = Random();

  Future<void> load() async {
    AppData loaded;
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs!.getString(_storageKey);
      if (raw == null || raw.isEmpty) {
        loaded = seedData();
      } else {
        try {
          loaded = AppData.decode(raw);
        } catch (_) {
          // 快照整体损坏：先留档供人工找回，再以种子数据起步。
          await _prefs!.setString(_corruptKey, raw);
          loaded = seedData();
        }
      }
    } catch (_) {
      loaded = seedData();
    }
    data = loaded;
    _migrateInboxToUnfiled();
    // 过期条目先清掉，避免旧快照里的回收站随后续上传继续传播。
    final purged = _purgeTrashEntries(data.trash);
    _loadTombstones();
    _rebaseline();
    unawaited(_cleanupAttachments(
        purged.expand((t) => t.item.attached), _itemAttachDir));
  }

  static const _corruptKey = '$_storageKey:corrupt-backup';

  /// 最近一次解析失败前的原始快照；仅人工找回用。
  String? get corruptBackup => _prefs?.getString(_corruptKey);

  void replaceData(AppData next) {
    data = next;
    _migrateInboxToUnfiled();
    final purged = _purgeTrashEntries(data.trash);
    _rebaseline();
    _changed();
    unawaited(_cleanupAttachments(
        purged.expand((t) => t.item.attached), _itemAttachDir));
  }

  /// 收件箱清单迁移为未分类集合。
  void _migrateInboxToUnfiled() {
    final inbox = data.lists.where((l) => l.id == 'inbox').toList();
    if (inbox.isEmpty) return;
    for (final l in inbox) {
      final target = data.lists.where((x) => x.id == unfiledListId).firstOrNull;
      if (target == null) {
        data.lists.insert(
            0,
            TaskList(
                id: unfiledListId,
                name: unfiledListName,
                color: '8A8A8A',
                items: l.items));
      } else {
        target.items.insertAll(0, l.items);
      }
      data.lists.remove(l);
    }
  }

  /// 外部修改 data 后触发持久化与通知。
  void notifyDataChangedExternally() {
    _changed();
  }

  Future<void> _persist() async {
    try {
      await _prefs?.setString(_storageKey, data.encode());
    } catch (_) {
      // 写入失败不阻断使用。
    }
  }

  // ---- 多端合并：指纹 diff 打时间戳 + 删除墓碑 ----

  /// 实体 id -> 内容指纹（不含时间戳字段）。
  final Map<String, String> _fp = {};

  /// 已删除实体墓碑：id -> 删除时间 ms；随快照合并传播，30 天裁剪。
  final Map<String, int> tombstones = {};

  /// 数据被整体替换（载入/恢复/合并）后重算指纹基线，不产生墓碑。
  void _rebaseline() {
    _fp.clear();
    _forEachEntity((id, fp) => _fp[id] = fp);
  }

  void _forEachEntity(void Function(String id, String fp) fn) {
    String fp(Map<String, dynamic> j) => jsonEncode(j..remove('u'));
    for (final t in data.tasks) {
      fn(t.id, fp(t.toJson()));
    }
    for (final l in data.lists) {
      fn(l.id, fp(l.toJson()));
      for (final i in l.items) {
        fn(i.id, fp(i.toJson()));
      }
    }
    for (final i in data.trash) {
      fn(i.item.id, fp(i.item.toJson()));
    }
    for (final h in data.habits) {
      fn(h.id, fp(h.toJson()));
    }
    for (final m in data.milestones) {
      fn(m.id, fp(m.toJson()));
    }
    for (final e in data.journal.entries) {
      fn('j:${e.key}', fp(e.value.toJson()));
    }
  }

  /// 变更后与指纹基线对比：内容变化的实体打 updatedAt=now，
  /// 消失的实体记删除墓碑（整体替换走 _rebaseline，不在此列）。
  void _diffTouch() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = <String, String>{};

    for (final t in data.tasks) {
      final clean = t.toJson()..remove('u');
      final f = jsonEncode(clean);
      if (_fp[t.id] != f) t.updatedAt = now;
      next[t.id] = f;
    }
    for (final l in data.lists) {
      for (final i in l.items) {
        final clean = i.toJson()..remove('u');
        final f = jsonEncode(clean);
        if (_fp[i.id] != f) i.updatedAt = now;
        next[i.id] = f;
      }
      final head = l.toJson()
        ..remove('items')
        ..remove('u');
      final f = jsonEncode(head);
      if (_fp[l.id] != f) l.updatedAt = now;
      next[l.id] = f;
    }
    for (final i in data.trash) {
      final clean = i.item.toJson()..remove('u');
      final f = jsonEncode(clean);
      if (_fp[i.item.id] != f) i.item.updatedAt = now;
      next[i.item.id] = f;
    }
    for (final h in data.habits) {
      final clean = h.toJson()..remove('u');
      final f = jsonEncode(clean);
      if (_fp[h.id] != f) h.updatedAt = now;
      next[h.id] = f;
    }
    for (final m in data.milestones) {
      final clean = m.toJson()..remove('u');
      final f = jsonEncode(clean);
      if (_fp[m.id] != f) m.updatedAt = now;
      next[m.id] = f;
    }
    for (final e in data.journal.entries) {
      final id = 'j:${e.key}';
      final clean = e.value.toJson()..remove('u');
      final f = jsonEncode(clean);
      if (_fp[id] != f) e.value.updatedAt = now;
      next[id] = f;
    }
    // 消失的实体记墓碑。
    for (final id in _fp.keys) {
      if (!next.containsKey(id)) tombstones[id] = now;
    }
    _fp
      ..clear()
      ..addAll(next);
  }

  /// 与其他设备的快照按 id 合并：updatedAt 新者胜、墓碑优先。
  /// 返回（合并数据, 合并后的墓碑集）。
  static (AppData, Map<String, int>) mergeAppData({
    required AppData mine,
    required AppData theirs,
    required Map<String, int> myTombs,
    required Map<String, int> theirTombs,
  }) {
    final tombs = <String, int>{};
    myTombs.forEach((k, v) => tombs[k] = v);
    theirTombs.forEach((k, v) {
      final cur = tombs[k];
      tombs[k] = cur == null || v > cur ? v : cur;
    });

    // 墓碑按时间比较：删除时间晚于实体最后修改才算删净；恢复流程把
    // updatedAt 提到删除之后，可以穿透墓碑重新同步（回收站找回）。
    bool dead(String id, [int updatedAt = 0]) {
      final t = tombs[id];
      return t != null && t >= updatedAt;
    }

    int maxU(int? a, int b) => (a ?? 0) > b ? (a ?? 0) : b;

    // 清单回收站按条目 id 取删除时间（双方较晚者）：条目在回收站即视为
    // 已删，列表合并时不再保留；恢复会把 updatedAt 提到删除之后从而胜出。
    final trashAt = <String, int>{};
    for (final t in [...mine.trash, ...theirs.trash]) {
      final cur = trashAt[t.item.id];
      if (cur == null || t.deletedAt > cur) trashAt[t.item.id] = t.deletedAt;
    }
    bool inTrash(String id, int updatedAt) {
      final at = trashAt[id];
      return at != null && at >= updatedAt;
    }

    final theirsAll = <String, int>{};
    for (final t in theirs.tasks) {
      theirsAll[t.id] = t.updatedAt;
    }
    for (final l in theirs.lists) {
      theirsAll[l.id] = l.updatedAt;
      for (final i in l.items) {
        theirsAll[i.id] = i.updatedAt;
      }
    }
    for (final h in theirs.habits) {
      theirsAll[h.id] = h.updatedAt;
    }
    for (final m in theirs.milestones) {
      theirsAll[m.id] = m.updatedAt;
    }
    for (final e in theirs.journal.entries) {
      theirsAll['j:${e.key}'] = e.value.updatedAt;
    }

    // 双方都有：updatedAt 新者胜；双方都未知（0）本地赢。
    T pick<T extends Object>(T a, T b, String id, int Function(T) u) {
      final otherU = theirsAll[id];
      if (otherU == null) return a; // 对方没有该实体。
      final au = u(a);
      final bu = otherU;
      return bu > au ? b : a;
    }

    final out = AppData(
      lists: [],
      tasks: [],
      habits: [],
      journal: {},
      milestones: [],
      trash: [],
    );

    // 任务。
    final myTasks = {for (final t in mine.tasks) t.id: t};
    final seenTasks = <String>{};
    for (final t in theirs.tasks) {
      if (dead(t.id, t.updatedAt)) continue;
      seenTasks.add(t.id);
      final a = myTasks[t.id];
      // 重复任务的 doneDates 需按日期并集，不能整实体 LWW（会丢另一端的完成日）。
      out.tasks.add(a == null ? t : _mergeTaskDoneDates(a, t));
    }
    for (final t in mine.tasks) {
      if (!seenTasks.contains(t.id) && !dead(t.id, t.updatedAt)) {
        out.tasks.add(t);
      }
    }

    // 习惯。
    final myHabits = {for (final h in mine.habits) h.id: h};
    final seenHabits = <String>{};
    for (final h in theirs.habits) {
      if (dead(h.id, h.updatedAt)) continue;
      seenHabits.add(h.id);
      final a = myHabits[h.id];
      // 习惯打卡记录需按日期并集，不能整实体 LWW（会丢另一端的打卡）。
      out.habits.add(a == null ? h : _mergeHabitRecords(a, h));
    }
    for (final h in mine.habits) {
      if (!seenHabits.contains(h.id) && !dead(h.id, h.updatedAt)) {
        out.habits.add(h);
      }
    }

    // 倒数日。
    final myMs = {for (final m in mine.milestones) m.id: m};
    final seenMs = <String>{};
    for (final m in theirs.milestones) {
      if (dead(m.id, m.updatedAt)) continue;
      seenMs.add(m.id);
      final a = myMs[m.id];
      out.milestones.add(a == null
          ? m
          : pick(a, m, m.id, (x) => x.updatedAt) == a ? a : m);
    }
    for (final m in mine.milestones) {
      if (!seenMs.contains(m.id) && !dead(m.id, m.updatedAt)) {
        out.milestones.add(m);
      }
    }

    // 清单：清单头按 updatedAt 合并，条目级同法；回收站里的条目按已删处理。
    final myLists = {for (final l in mine.lists) l.id: l};
    final seenLists = <String>{};
    for (final l in theirs.lists) {
      seenLists.add(l.id);
      if (dead(l.id, l.updatedAt)) continue;
      final a = myLists[l.id];
      if (a == null) {
        out.lists.add(TaskList(
          id: l.id,
          name: l.name,
          color: l.color,
          shared: l.shared,
          coEdit: l.coEdit,
          items: [
            for (final i in l.items)
              if (!dead(i.id, i.updatedAt) && !inTrash(i.id, i.updatedAt)) i,
          ],
        )..updatedAt = l.updatedAt);
        continue;
      }
      final mergedItems = <ListItem>[];
      final aItems = {for (final i in a.items) i.id: i};
      final seenItems = <String>{};
      for (final i in l.items) {
        if (dead(i.id, i.updatedAt) || inTrash(i.id, i.updatedAt)) continue;
        seenItems.add(i.id);
        final ai = aItems[i.id];
        mergedItems.add(ai == null
            ? i
            : pick(ai, i, i.id, (x) => x.updatedAt) == ai ? ai : i);
      }
      for (final i in a.items) {
        if (!seenItems.contains(i.id) &&
            !dead(i.id, i.updatedAt) &&
            !inTrash(i.id, i.updatedAt)) {
          mergedItems.add(i);
        }
      }
      final head = pick(a, l, l.id, (x) => x.updatedAt) == a ? a : l;
      out.lists.add(TaskList(
        id: head.id,
        name: head.name,
        color: head.color,
        shared: head.shared,
        coEdit: head.coEdit,
        items: mergedItems,
      )..updatedAt = head.updatedAt);
    }
    for (final l in mine.lists) {
      if (seenLists.contains(l.id) || dead(l.id, l.updatedAt)) continue;
      out.lists.add(TaskList(
        id: l.id,
        name: l.name,
        color: l.color,
        shared: l.shared,
        coEdit: l.coEdit,
        items: [
          for (final i in l.items)
            if (!dead(i.id, i.updatedAt) && !inTrash(i.id, i.updatedAt)) i,
        ],
      )..updatedAt = l.updatedAt);
    }

    // 日记：按日期键合并，updatedAt 新者胜；墓碑晚于双方最新修改才判删。
    final keys = <String>{...mine.journal.keys, ...theirs.journal.keys};
    for (final k in keys) {
      final id = 'j:$k';
      final a = mine.journal[k];
      final b = theirs.journal[k];
      if (dead(id, maxU(a?.updatedAt, b?.updatedAt ?? 0))) continue;
      if (a == null) {
        out.journal[k] = b!;
      } else if (b == null) {
        out.journal[k] = a;
      } else {
        out.journal[k] = b.updatedAt > a.updatedAt ? b : a;
      }
    }

    // 清单回收站：按 item.id 取并集，同 id 取删除时间较晚者。
    // 已恢复（列表里存活且更新）或已永久删除（墓碑）的条目不回流。
    final aliveAt = <String, int>{};
    for (final l in out.lists) {
      for (final i in l.items) {
        final cur = aliveAt[i.id];
        if (cur == null || i.updatedAt > cur) aliveAt[i.id] = i.updatedAt;
      }
    }
    final trashMap = <String, TrashEntry>{};
    for (final t in [...mine.trash, ...theirs.trash]) {
      // 永久删除会留下墓碑，回收站条目随之消失（不会再被对方拉回）。
      if (dead(t.item.id, t.item.updatedAt)) continue;
      final alive = aliveAt[t.item.id];
      if (alive != null && alive > t.deletedAt) continue; // 已恢复到清单
      final cur = trashMap[t.item.id];
      if (cur == null || t.deletedAt > cur.deletedAt) trashMap[t.item.id] = t;
    }
    out.trash.addAll(trashMap.values);
    _purgeTrashEntries(out.trash);

    // 日记回收站：按存储键并集，删除时间新者胜（上限 15 防快照膨胀）。
    final trMap = <String, JournalTrashItem>{};
    for (final t in [...mine.journalTrash, ...theirs.journalTrash]) {
      final cur = trMap[t.storageKey];
      if (cur == null || t.deletedAt > cur.deletedAt) trMap[t.storageKey] = t;
    }
    final trList = trMap.values.toList()
      ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    out.journalTrash.addAll(trList.take(15));

    // 共同编辑 overlay：条目级 updatedAt 新者胜（多端写同一清单）。
    final seenCo = <String>{};
    for (final e in [...mine.coedits.entries, ...theirs.coedits.entries]) {
      if (seenCo.contains(e.key)) continue;
      seenCo.add(e.key);
      final merged = <String, ListItem>{};
      final mineItems = mine.coedits[e.key] ?? const {};
      final theirItems = theirs.coedits[e.key] ?? const {};
      for (final id in {...mineItems.keys, ...theirItems.keys}) {
        final a = mineItems[id];
        final b = theirItems[id];
        merged[id] = b != null && (a == null || b.updatedAt > a.updatedAt)
            ? b
            : a!;
      }
      if (merged.isNotEmpty) out.coedits[e.key] = merged;
    }

    // 墓碑裁剪：30 天前的丢弃（与保存/加载路径共用同一规则）。
    pruneTombstones(tombs);

    return (out, tombs);
  }

  // ---- 多端合并：实体内部集合字段取并集 ----

  /// 合并两端习惯打卡记录。Habit.records 是实体内部集合，整实体 updatedAt
  /// 新者胜会丢掉另一台设备上的打卡（例如手机勾周一、电脑勾周二）。
  ///
  /// 语义：
  /// - 两端出现过的日期**取并集**，任何一端的打卡都不会因另一端的更新而消失；
  /// - 同一天状态冲突（done/miss）以 updatedAt 较新的一端为准，平手取本地 a；
  /// - 删除语义：records 没有逐条墓碑，"缺键"无法区分"从未记录"和"被清除"，
  ///   因此单端清除某天在合并后可能被另一端旧记录复活（以不丢打卡为优先）。
  ///   要彻底清除某天需两端分别清除；整条习惯的删除仍由 tombstones 决定。
  /// - JSON 格式不变，仅内存合并结果不同。
  static Habit _mergeHabitRecords(Habit a, Habit b) {
    final aWins = a.updatedAt >= b.updatedAt;
    final primary = aWins ? a : b;
    final secondary = aWins ? b : a;
    if (secondary.records.isEmpty) return primary;
    final merged = <String, HabitStatus>{
      ...secondary.records,
      ...primary.records, // 同日冲突：updatedAt 新者（平手本地）覆盖
    };
    if (merged.length == primary.records.length) return primary;
    return Habit(
      id: primary.id,
      updatedAt: primary.updatedAt,
      name: primary.name,
      color: primary.color,
      records: merged,
      sort: primary.sort,
      time: primary.time,
      reminder: primary.reminder,
    );
  }

  /// 合并两端重复任务的 doneDates（完成日期集合）。
  ///
  /// 语义：
  /// - 日期取并集，避免一端勾了周一、另一端勾了周二时丢记录；
  /// - 并集后按与 [setTaskDoneOn] 相同的 400 天规则裁剪，避免另一端把本机已
  ///   自动裁剪掉的旧日期复活（先并集后裁剪）；
  /// - 删除语义同习惯打卡：doneDates 缺键分不清"从未完成"与"被取消勾选"，
  ///   单端取消某天在合并后可能被另一端旧记录复活；整条任务删除仍由墓碑决定；
  /// - 非重复任务不使用 doneDates，直接沿用 updatedAt 新者的整实体结果。
  static PlanTask _mergeTaskDoneDates(PlanTask a, PlanTask b) {
    final aWins = a.updatedAt >= b.updatedAt;
    final primary = aWins ? a : b;
    final secondary = aWins ? b : a;
    if (!primary.isRecurring) return primary;
    final merged = <String>{...secondary.doneDates, ...primary.doneDates};
    final cutoff = dateKey(today().subtract(const Duration(days: 400)));
    merged.removeWhere((k) => k.compareTo(cutoff) < 0);
    final mergedList = merged.toList()..sort();
    if (mergedList.length == primary.doneDates.length &&
        primary.doneDates.every(merged.contains)) {
      return primary;
    }
    return PlanTask(
      id: primary.id,
      title: primary.title,
      updatedAt: primary.updatedAt,
      date: primary.date,
      repeatMode: primary.repeatMode,
      repeatWeekdays: primary.repeatWeekdays,
      start: primary.start,
      end: primary.end,
      done: primary.done,
      doneDates: mergedList,
      note: primary.note,
      starred: primary.starred,
      archived: primary.archived,
      remindBefore: primary.remindBefore,
      sort: primary.sort,
    );
  }

  void _changed() {
    // 每次变更都先修剪回收站：过期条目不能随快照继续上传。
    // 清理是本机维护动作，不记墓碑（否则会误删其他设备上仍存活的同 id 条目；
    // 对方快照里残留的过期条目会在下次合并时再次被丢弃）。
    final purged = _purgeTrashEntries(data.trash);
    for (final t in purged) {
      _fp.remove(t.item.id);
    }
    _diffTouch();
    _persistTombstones();
    notifyListeners();
    _persist();
    unawaited(_cleanupAttachments(
        purged.expand((t) => t.item.attached), _itemAttachDir));
  }

  Future<void> _persistTombstones() async {
    try {
      // 保存路径也裁一次，单设备/长期不合并的账号不会无限增长。
      pruneTombstones(tombstones);
      await _prefs?.setString(
          'goalday-m3:tombstones', jsonEncode(tombstones));
    } catch (_) {}
  }

  void _loadTombstones() {
    try {
      final raw = _prefs?.getString('goalday-m3:tombstones');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        tombstones
          ..clear()
          ..addAll(decoded.map((k, v) => MapEntry(k, (v as num).toInt())));
        pruneTombstones(tombstones);
      }
    } catch (_) {}
  }

  String _genId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      (_rng.nextInt(46656) + 46656).toRadixString(36);

  /// 墓碑有效期：30 天（合并、保存、加载共用同一判定）。
  static const int tombstoneTtlMs = 30 * 86400000;

  static void pruneTombstones(Map<String, int> tombs) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - tombstoneTtlMs;
    tombs.removeWhere((k, v) => v < cutoff);
  }

  static const _journalAttachDir = 'journal_images';
  static const _itemAttachDir = 'item_attachments';

  /// 当前数据里仍被引用的本机附件路径（日记、日记回收站、清单条目、
  /// 清单回收站、共同编辑 overlay）。同一张图被多处引用时不会被误删。
  Set<String> _referencedAttachments() {
    final refs = <String>{};
    for (final e in data.journal.values) {
      refs.addAll(e.images);
    }
    for (final t in data.journalTrash) {
      refs.addAll(t.entry.images);
    }
    for (final l in data.lists) {
      for (final i in l.items) {
        refs.addAll(i.attached);
      }
    }
    for (final t in data.trash) {
      refs.addAll(t.item.attached);
    }
    for (final items in data.coedits.values) {
      for (final i in items.values) {
        refs.addAll(i.attached);
      }
    }
    return refs;
  }

  /// 永久删除成功后调用：候选路径若不再被任何数据引用，才删本机文件。
  /// 只删本机应用目录内的文件，不碰云端；共享路径会被引用集挡掉。
  Future<void> _cleanupAttachments(
      Iterable<String> paths, String subdir) async {
    final candidates = <String>{};
    for (final p in paths) {
      if (p.isNotEmpty) candidates.add(p);
    }
    if (candidates.isEmpty) return;
    final refs = _referencedAttachments();
    for (final p in candidates) {
      if (refs.contains(p)) continue;
      await deleteAttachQuietly(p, subdir);
    }
  }

  /// 供页面调用：移除附件文件前先查全量引用（手动删图、删条目等场景）。
  /// 数据模型已经改过之后调用，此时引用集是准确的。
  Future<void> removeAttachmentsIfUnused(
          Iterable<String> paths, String subdir) =>
      _cleanupAttachments(paths, subdir);

  /// 恢复初始数据后调用：把应用目录里再没有任何引用的附件文件清掉。
  /// 只动本机文件，云端数据此时已被清空。
  Future<void> purgeUnusedAttachments() async {
    final refs = _referencedAttachments();
    try {
      final docs = await getApplicationDocumentsDirectory();
      for (final sub in const ['journal_images', 'item_attachments']) {
        final dir = Directory('${docs.path}${Platform.pathSeparator}$sub');
        if (!await dir.exists()) continue;
        await for (final e in dir.list()) {
          if (e is! File) continue;
          if (refs.contains(e.path)) continue;
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ---------- 任务查询 ----------

  PlanTask? taskById(String id) {
    for (final t in data.tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  static const unfiledListId = kUnfiledListId;
  static const unfiledListName = kUnfiledListName;

  /// 未分类集合，可能不存在。
  TaskList? get unfiled => listById(unfiledListId);

  /// 返回未分类集合，不存在则创建。
  TaskList ensureUnfiled() {
    final existing = listById(unfiledListId);
    if (existing != null) return existing;
    final l = TaskList(
        id: unfiledListId, name: unfiledListName, color: '8A8A8A');
    data.lists.insert(0, l);
    _changed();
    return l;
  }

  List<PlanTask> tasksOn(String dayKey) {
    final day = _parseKey(dayKey);
    final list = data.tasks.where((t) => t.occursOn(day) && !t.archived).toList()
      ..sort((a, b) {
        final ad = a.isDoneOn(day);
        final bd = b.isDoneOn(day);
        if (ad != bd) return ad ? 1 : -1; // 未完成在前
        final manual = compareManualSort(a.sort, b.sort);
        if (manual != null) return manual; // 手动排序优先于星标/时间
        if (a.starred != b.starred) return a.starred ? -1 : 1;
        return timeSortKey(a.start).compareTo(timeSortKey(b.start));
      });
    return list;
  }

  /// 本周内完成的无日期任务。
  List<PlanTask> weekTasks() => data.tasks
      .where((t) => !t.hasDate && !t.isRecurring && !t.archived)
      .toList()
    ..sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      final manual = compareManualSort(a.sort, b.sort);
      if (manual != null) return manual;
      if (a.starred != b.starred) return a.starred ? -1 : 1;
      return a.title.compareTo(b.title);
    });

  /// 手动排序比较；都未排序返回 null。
  static int? compareManualSort(int a, int b) {
    if (a != 0 && b != 0) return a.compareTo(b);
    if (a != 0) return -1;
    if (b != 0) return 1;
    return null;
  }

  static void _renumber(List<dynamic> items) {
    for (var i = 0; i < items.length; i++) {
      items[i].sort = 10 * (i + 1);
    }
  }

  (int, int) weekStat(DateTime weekStart) {
    var done = 0;
    var total = 0;
    for (var i = 0; i < 7; i++) {
      final d = weekStart.add(Duration(days: i));
      for (final t in data.tasks) {
        if (!t.archived && t.occursOn(d)) {
          total++;
          if (t.isDoneOn(d)) done++;
        }
      }
    }
    for (final t in weekTasks()) {
      total++;
      if (t.done) done++;
    }
    return (done, total);
  }

  // ---------- 任务操作 ----------

  PlanTask addTask({
    required String title,
    String date = '',
    TaskRepeatMode repeatMode = TaskRepeatMode.none,
    List<int> repeatWeekdays = const [],
    String start = '',
    String end = '',
    int remindBefore = 0,
  }) {
    final t = PlanTask(
      id: _genId(),
      title: title,
      date: date,
      repeatMode: repeatMode,
      repeatWeekdays: List<int>.from(repeatWeekdays)..sort(),
      start: start,
      end: end,
      remindBefore: remindBefore,
    );
    data.tasks.insert(0, t);
    // 新条目插到未完成组最前的排序值。
    final weekScope = !t.hasDate && !t.isRecurring;
    final anchor = weekScope ? today() : (t.hasDate ? _parseKey(t.date) : today());
    t.sort = _frontSort(
        _siblingUndoneOn(anchor, weekScope: weekScope));
    _changed();
    return t;
  }

  /// 新建条目排序值：组内最小值-1，全未排序返回 0；
  /// 最小值为 1 时兄弟重排为 20/40/60，新条目取 10。
  static int _frontSort(List<dynamic> siblings) {
    final set = siblings.map((x) => x.sort as int).where((v) => v != 0).toList();
    if (set.isEmpty) return 0;
    final minS = set.reduce((a, b) => a < b ? a : b);
    if (minS - 1 == 0) {
      for (var i = 0; i < siblings.length; i++) {
        siblings[i].sort = 20 * (i + 1);
      }
      return 10;
    }
    return minS - 1;
  }

  List<PlanTask> _siblingUndoneOn(DateTime day, {bool weekScope = false}) {
    if (weekScope) return weekTasks().where((x) => !x.done).toList();
    return data.tasks
        .where((x) => x.occursOn(day) && !x.archived && !x.isDoneOn(day))
        .toList()
      ..sort((a, b) {
        final m = compareManualSort(a.sort, b.sort);
        if (m != null) return m;
        if (a.starred != b.starred) return a.starred ? -1 : 1;
        return timeSortKey(a.start).compareTo(timeSortKey(b.start));
      });
  }

  void updateTask(
    String id, {
    String? title,
    String? date,
    TaskRepeatMode? repeatMode,
    List<int>? repeatWeekdays,
    String? start,
    String? end,
    bool? starred,
    String? note,
    int? remindBefore,
  }) {
    final t = taskById(id);
    if (t == null) return;
    if (title != null) t.title = title;
    if (date != null) t.date = date;
    if (repeatMode != null) t.repeatMode = repeatMode;
    if (repeatWeekdays != null) {
      t.repeatWeekdays = List<int>.from(repeatWeekdays)..sort();
    }
    if (start != null) t.start = start;
    if (end != null) t.end = end;
    if (starred != null && starred != t.starred) {
      // 与滑动星标相同的 reorder。
      t.starred = starred;
      if (starred) {
        _bringTaskToFront(t);
      } else {
        final g = _siblingUndone(t)..remove(t);
        g.add(t);
        _renumber(g);
      }
    }
    if (note != null) t.note = note;
    if (remindBefore != null) t.remindBefore = remindBefore;
    _changed();
  }

  /// 切换某天完成状态，重复任务按日期记录；剪枝 400 天前的勾选记录。
  void setTaskDoneOn(PlanTask t, DateTime day, bool value) {
    t.setDoneOn(day, value);
    final cutoff = dateKey(today().subtract(const Duration(days: 400)));
    t.doneDates.removeWhere((k) => k.compareTo(cutoff) < 0);
    _changed();
  }

  void moveTask(String id, String date) {
    final t = taskById(id);
    if (t == null) return;
    t.date = date;
    _changed();
  }

  void restoreTask(String id) {
    final t = taskById(id);
    if (t == null) return;
    t.archived = false;
    _changed();
  }

  void archiveTask(String id, bool archived) {
    final t = taskById(id);
    if (t == null) return;
    t.archived = archived;
    _changed();
  }

  void setTaskStarred(String id, bool starred) {
    final t = taskById(id);
    if (t == null) return;
    t.starred = starred;
    if (starred) {
      _bringTaskToFront(t);
    } else {
      // 取消置顶：移到未完成组末尾。
      final g = _siblingUndone(t)..remove(t);
      g.add(t);
      _renumber(g);
    }
    _changed();
  }

  /// 任务所在未完成组的显示序列表。
  List<PlanTask> _siblingUndone(PlanTask t) {
    if (!t.isRecurring && !t.hasDate) {
      return weekTasks().where((x) => !x.done).toList();
    }
    final day = t.hasDate ? _parseKey(t.date) : today();
    return data.tasks
        .where((x) => x.occursOn(day) && !x.archived && !x.isDoneOn(day))
        .toList()
      ..sort((a, b) {
        final m = compareManualSort(a.sort, b.sort);
        if (m != null) return m;
        if (a.starred != b.starred) return a.starred ? -1 : 1;
        return timeSortKey(a.start).compareTo(timeSortKey(b.start));
      });
  }

  /// 把任务提到未完成组最前并重排序号。
  void _bringTaskToFront(PlanTask t) {
    List<PlanTask> undone;
    if (!t.isRecurring && !t.hasDate) {
      undone = weekTasks().where((x) => !x.done).toList();
    } else {
      final day = t.hasDate ? _parseKey(t.date) : today();
      undone = data.tasks
          .where((x) => x.occursOn(day) && !x.archived && !x.isDoneOn(day))
          .toList()
        ..sort((a, b) {
          final m = compareManualSort(a.sort, b.sort);
          if (m != null) return m;
          if (a.starred != b.starred) return a.starred ? -1 : 1;
          return timeSortKey(a.start).compareTo(timeSortKey(b.start));
        });
    }
    undone.remove(t);
    undone.insert(0, t);
    _renumber(undone);
  }

  // ---------- 手动排序 ----------

  /// 日视图：未完成任务从 from 移到 to。
  void reorderTaskOn(String dayKey, int from, int to) {
    final undone = _undoneOn(dayKey);
    if (from < 0 || to < 0 || from >= undone.length || to >= undone.length) {
      return;
    }
    final t = undone.removeAt(from);
    undone.insert(to, t);
    _renumber(undone);
    _changed();
  }

  /// 日视图：相邻任务换位。
  void moveTaskUpDown(String dayKey, String taskId, int delta) {
    final undone = _undoneOn(dayKey);
    if (undone.isEmpty) return;
    final from = undone.indexWhere((t) => t.id == taskId);
    final to = (from + delta).clamp(0, undone.length - 1);
    if (from < 0 || to == from) return;
    final t = undone.removeAt(from);
    undone.insert(to, t);
    _renumber(undone);
    _changed();
  }

  List<PlanTask> _undoneOn(String dayKey) {
    final day = _parseKey(dayKey);
    return data.tasks
        .where((t) => t.occursOn(day) && !t.archived && !t.isDoneOn(day))
        .toList()
      ..sort((a, b) {
        final m = compareManualSort(a.sort, b.sort);
        if (m != null) return m;
        if (a.starred != b.starred) return a.starred ? -1 : 1;
        return timeSortKey(a.start).compareTo(timeSortKey(b.start));
      });
  }

  /// 周视图：无日期任务未完成组内换位。
  void reorderWeekTask(int from, int to) => _reorderIn(_weekUndone, from, to);

  void moveWeekTaskUpDown(String taskId, int delta) =>
      _moveIn(_weekUndone, taskId, delta);

  List<PlanTask> get _weekUndone =>
      weekTasks().where((t) => !t.done).toList();

  /// 清单：未完成条目组内换位。
  void reorderListItem(String listId, int from, int to) =>
      _reorderIn(_listUndone(listId), from, to);

  void moveListItemUpDown(String listId, String itemId, int delta) =>
      _moveIn(_listUndone(listId), itemId, delta);

  List<dynamic> _listUndone(String listId) => undoneOf(listById(listId));

  /// 清单的未完成条目，按当前显示序（手动序优先，未排序按插入序），
  /// 与详情页及拖动排序使用同一顺序。
  List<ListItem> undoneOf(TaskList? list) {
    if (list == null) return const [];
    final pairs = <(int, ListItem)>[
      for (var i = 0; i < list.items.length; i++)
        if (!list.items[i].done) (i, list.items[i]),
    ]..sort((a, b) {
      final m = compareManualSort(a.$2.sort, b.$2.sort);
      if (m != null) return m;
      final da = a.$2.date;
      final db = b.$2.date;
      if (da.isNotEmpty || db.isNotEmpty) {
        // 有日期的按日期升序排前，无日期的按插入序垫后。
        if (da.isEmpty != db.isEmpty) return da.isEmpty ? 1 : -1;
        if (da.isNotEmpty && da != db) return da.compareTo(db);
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in pairs) e.$2];
  }

  /// 习惯显示序：手动拖过的优先，其余有时间的按时间升序排前。
  List<Habit> habitsDisplay() {
    final pairs = <(int, Habit)>[
      for (var i = 0; i < data.habits.length; i++) (i, data.habits[i]),
    ]..sort((a, b) {
      final m = compareManualSort(a.$2.sort, b.$2.sort);
      if (m != null) return m;
      final ta = a.$2.time;
      final tb = b.$2.time;
      if (ta.isNotEmpty || tb.isNotEmpty) {
        if (ta.isEmpty != tb.isEmpty) return ta.isEmpty ? 1 : -1;
        if (ta.isNotEmpty && ta != tb) return ta.compareTo(tb);
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in pairs) e.$2];
  }

  /// 习惯卡换位：在显示序上换位后按新序重编号，原始列表同步对齐
  /// （拖动索引来自 habitsDisplay 投影，直接改 raw 会拖错条目）。
  void reorderHabit(int from, int to) {
    final display = habitsDisplay();
    if (from < 0 ||
        to < 0 ||
        from >= display.length ||
        to >= display.length ||
        from == to) {
      return;
    }
    final moved = display.removeAt(from);
    display.insert(to, moved);
    for (var i = 0; i < display.length; i++) {
      display[i].sort = 10 * (i + 1);
    }
    data.habits
      ..clear()
      ..addAll(display);
    _changed();
  }

  void moveHabitUpDown(String habitId, int delta) {
    final display = habitsDisplay();
    final from = display.indexWhere((h) => h.id == habitId);
    if (from < 0) return;
    reorderHabit(from, from + delta);
  }

  void _reorderIn(List<dynamic> items, int from, int to) {
    if (from < 0 || to < 0 || from >= items.length || to >= items.length) {
      return;
    }
    final t = items.removeAt(from);
    items.insert(to, t);
    _renumber(items);
    _changed();
  }

  void _moveIn(List<dynamic> items, String id, int delta) {
    final from = items.indexWhere((e) => e.id == id);
    if (from < 0) return;
    final to = (from + delta).clamp(0, items.length - 1);
    if (to == from) return;
    final t = items.removeAt(from);
    items.insert(to, t);
    _renumber(items);
    _changed();
  }

  void deleteTask(String id) {
    data.tasks.removeWhere((t) => t.id == id);
    _changed();
  }

  bool allTodayDone() {
    final list = tasksOn(dateKey(today()));
    return list.isNotEmpty && list.every((t) => t.isDoneOn(today()));
  }

  void moveTasksToToday(List<PlanTask> tasks, {required DateTime from}) {
    final target = dateKey(today());
    final fromKey = dateKey(from);
    for (final t in tasks) {
      if (t.isRecurring) {
        t.doneDates.remove(fromKey);
      } else if (t.date == fromKey) {
        t.date = target;
      }
    }
    _changed();
  }

  // ---------- 清单 ----------

  TaskList? listById(String id) {
    for (final l in data.lists) {
      if (l.id == id) return l;
    }
    return null;
  }

  TaskList? addList(String name, String color) {
    final n = name.trim();
    if (n.isEmpty) return null;
    if (data.lists.any((l) => l.name == n)) return null;
    final l = TaskList(id: _genId(), name: n, color: color);
    data.lists.add(l);
    _changed();
    return l;
  }

  bool addListWithItems(ListTemplate template, String color) {
    if (data.lists.any((l) => l.name == template.name)) return false;
    final l = TaskList(
      id: _genId(),
      name: template.name,
      color: color,
      items: template.items
          .map((title) => ListItem(id: _genId(), title: title))
          .toList(),
    );
    data.lists.add(l);
    _changed();
    return true;
  }

  /// 设置清单是否共享给伴侣（未分类同样可共享）。
  void setListShared(String id, bool shared) {
    final l = listById(id);
    if (l == null) return;
    l.shared = shared;
    if (!shared) l.coEdit = false;
    _changed();
  }

  /// 设置清单是否允许伴侣共同编辑（仅共享中的清单有意义）。
  void setListCoEdit(String id, bool coEdit) {
    final l = listById(id);
    if (l == null) return;
    l.coEdit = coEdit;
    if (coEdit) l.shared = true;
    _changed();
  }

  // ---- 共同编辑：TA 端写 overlay，所有者端合并回流 ----

  /// TA 勾选/取消共同编辑清单条目：克隆副本翻转 done 存入 overlay。
  void coEditToggleItem(String listId, ListItem original) {
    final copy = ListItem(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      id: original.id,
      title: original.title,
      done: !original.done,
      sort: original.sort,
      note: original.note,
      attached: List<String>.from(original.attached),
      date: original.date,
    );
    (data.coedits[listId] ??= {})[original.id] = copy;
    _changed();
  }

  /// TA 在共同编辑清单添加条目：新条目直接进 overlay。
  void coEditAddItem(String listId, String title) {
    final t = title.trim();
    if (t.isEmpty) return;
    final item = ListItem(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      id: _genId(),
      title: t,
    );
    (data.coedits[listId] ??= {})[item.id] = item;
    _changed();
  }

  /// TA 界面的清单条目生效视图：overlay 覆盖快照，TA 新增置顶。
  /// 快照里不存在且超过 48 小时的 overlay 条目不再显示（对方已删）。
  List<ListItem> coEditEffectiveItems(TaskList partnerList) {
    final overlay = data.coedits[partnerList.id];
    if (overlay == null || overlay.isEmpty) return partnerList.items;
    final known = partnerList.items.map((e) => e.id).toSet();
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      ...overlay.values.where((i) =>
          !known.contains(i.id) &&
          now - i.updatedAt <= 48 * 3600 * 1000),
      for (final i in partnerList.items) overlay[i.id] ?? i,
    ];
  }

  /// 所有者应用伴侣的共同编辑改动，返回是否有变更。
  /// 只接受 coEdit=true 的清单；条目级 updatedAt 新者胜，新条目置顶。
  bool applyCoEdits(Map<String, Map<String, ListItem>> incoming) {
    var changed = false;
    incoming.forEach((listId, items) {
      final l = listById(listId);
      if (l == null || !l.coEdit) return;
      items.forEach((itemId, remote) {
        final idx = l.items.indexWhere((i) => i.id == itemId);
        if (idx < 0) {
          // 所有者已删除的条目（墓碑在案）不回流复活。
          if (tombstones.containsKey(itemId)) return;
          final copy = ListItem(
            updatedAt: remote.updatedAt,
            id: remote.id,
            title: remote.title,
            done: remote.done,
            sort: _frontSort(l.items.where((e) => !e.done).toList()),
            note: remote.note,
            attached: List<String>.from(remote.attached),
            date: remote.date,
          );
          l.items.insert(0, copy);
          changed = true;
        } else if (remote.updatedAt > l.items[idx].updatedAt) {
          l.items[idx] = remote;
          changed = true;
        }
      });
    });
    if (changed) _changed();
    return changed;
  }

  /// TA 收到伴侣新快照后修剪已回流的 overlay 条目。
  /// 快照里找不到的条目（对方已删除）给 48 小时回流窗口，过期淘汰。
  void pruneCoEdits(AppData partnerData) {
    if (data.coedits.isEmpty) return;
    var changed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final keep = <String, Map<String, ListItem>>{};
    data.coedits.forEach((listId, items) {
      TaskList? remoteList;
      for (final l in partnerData.lists) {
        if (l.id == listId) remoteList = l;
      }
      // 清单没了或关闭共同编辑，整单丢弃。
      if (remoteList == null || !remoteList.coEdit) {
        changed = true;
        return;
      }
      final kept = <String, ListItem>{};
      items.forEach((itemId, item) {
        ListItem? remote;
        for (final i in remoteList!.items) {
          if (i.id == itemId) remote = i;
        }
        // 远端已是同版本或更新 = 已回流，丢弃。
        if (remote != null && remote.updatedAt >= item.updatedAt) {
          changed = true;
        } else if (remote == null &&
            now - item.updatedAt > 48 * 3600 * 1000) {
          // 对方列表里一直没有：多半已被删除，长期滞留只会
          // 显示幽灵条目并反复上传。
          changed = true;
        } else {
          kept[itemId] = item;
        }
      });
      if (kept.isNotEmpty) keep[listId] = kept;
    });
    if (changed) {
      data.coedits
        ..clear()
        ..addAll(keep);
      _changed();
    }
  }

  void updateList(String id, {String? name, String? color}) {
    final l = listById(id);
    if (l == null) return;
    final n = name?.trim() ?? '';
    if (n.isNotEmpty && data.lists.any((x) => x.id != id && x.name == n)) {
      return; // 重名拒绝
    }
    if (n.isNotEmpty) l.name = n;
    if (color != null) l.color = color;
    _changed();
  }

  void deleteList(String id) {
    if (id == unfiledListId) return; // 未分类集合不可删除
    final removed = data.lists.where((l) => l.id == id).toList();
    data.lists.removeWhere((l) => l.id == id);
    _changed();
    if (removed.isNotEmpty) {
      unawaited(_cleanupAttachments(
          removed.expand((l) => l.items).expand((i) => i.attached),
          _itemAttachDir));
    }
  }

  void addListItem(String listId, String title) {
    final l = listById(listId);
    if (l == null) return;
    final t = title.trim();
    if (t.isEmpty) return;
    final item = ListItem(id: _genId(), title: t);
    // 新条目取顶部排序值。
    final siblings = l.items.where((e) => !e.done).toList();
    item.sort = AppStore._frontSort(siblings);
    l.items.insert(0, item);
    _changed();
  }

  void setListItemNote(String listId, String itemId, String note) {
    for (final i in listById(listId)?.items ?? const <ListItem>[]) {
      if (i.id == itemId) i.note = note.trim();
    }
    _changed();
  }

  void setListItemAttached(String listId, String itemId, List<String> paths) {
    for (final i in listById(listId)?.items ?? const <ListItem>[]) {
      if (i.id == itemId) {
        i.attached = List<String>.from(paths);
      }
    }
    _changed();
  }

  /// 设置清单条目目标日期；空串清除。
  void setListItemDate(String listId, String itemId, String dateKey) {
    final list = listById(listId);
    if (list == null) return;
    for (final i in list.items) {
      if (i.id == itemId) {
        i.date = dateKey;
        _changed();
        return;
      }
    }
  }

  void setListItemDone(String listId, String itemId, bool done) {
    final l = listById(listId);
    if (l == null) return;
    for (final i in l.items) {
      if (i.id == itemId) i.done = done;
    }
    _changed();
  }

  /// 删除任意清单的条目：移入回收站并记录原清单与删除时间，可撤销/找回。
  void deleteListItem(String listId, String itemId) {
    final list = listById(listId);
    if (list == null) return;
    final idx = list.items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return;
    final item = list.items.removeAt(idx);
    // 同一条目重复移入（如撤销后再删）只保留最新一份，避免回收站出现重复。
    final replaced = data.trash.where((t) => t.item.id == itemId).toList();
    data.trash.removeWhere((t) => t.item.id == itemId);
    data.trash.insert(
      0,
      TrashEntry(
        listId: list.id,
        item: item,
        deletedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _changed();
    if (replaced.isNotEmpty) {
      unawaited(_cleanupAttachments(
          replaced.expand((t) => t.item.attached), _itemAttachDir));
    }
  }

  /// 回收站上限：最多保留 30 条。
  static const int trashLimit = 30;

  /// 回收站有效期：30 天（deletedAt==0 的旧快照数据不按天过期）。
  static const int trashTtlMs = 30 * 86400000;

  /// 修剪回收站：过期条目移除、超限按删除时间从旧到新丢弃。
  /// 返回被丢弃条目（调用方据此清墓碑指纹与附件）。
  static List<TrashEntry> _purgeTrashEntries(List<TrashEntry> trash) {
    final removed = <TrashEntry>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    trash.removeWhere((t) {
      final expired = t.deletedAt > 0 && now - t.deletedAt > trashTtlMs;
      if (expired) removed.add(t);
      return expired;
    });
    if (trash.length > 1) {
      trash.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    }
    if (trash.length > trashLimit) {
      for (var i = trashLimit; i < trash.length; i++) {
        removed.add(trash[i]);
      }
      trash.removeRange(trashLimit, trash.length);
    }
    return removed;
  }

  /// 手动清理回收站（加载后与每次变更后已自动调用）。
  void purgeTrash() {
    final removed = _purgeTrashEntries(data.trash);
    if (removed.isEmpty) return;
    for (final t in removed) {
      _fp.remove(t.item.id);
    }
    _changed();
    unawaited(_cleanupAttachments(
        removed.expand((t) => t.item.attached), _itemAttachDir));
  }

  /// 从回收站恢复条目：回到删除前所在的清单；清单已不存在时回退未分类。
  /// 保留标题/日期/备注/附件，重置未完成并置顶（规则同新增条目）。
  bool restoreTrashEntry(String itemId) {
    final idx = data.trash.indexWhere((t) => t.item.id == itemId);
    if (idx < 0) return false;
    final entry = data.trash[idx];
    // 先确保目标清单存在：ensureUnfiled 会触发一次变更，此条目仍在回收站里，
    // 不会因「实体消失」被误记删除墓碑。
    final target = listById(entry.listId) ?? ensureUnfiled();
    data.trash.removeWhere((t) => t.item.id == itemId);
    final item = entry.item;
    // 另一台设备已恢复过同一条目时不重复插入（以回收站副本为准）。
    target.items.removeWhere((i) => i.id == item.id);
    item.done = false;
    // 提到删除之后的修改时间，合并时可穿透对方的删除墓碑。
    item.updatedAt = DateTime.now().millisecondsSinceEpoch;
    item.sort = _frontSort(target.items.where((e) => !e.done).toList());
    target.items.insert(0, item);
    _changed();
    return true;
  }

  /// 永久删除回收站条目；墓碑会让其他设备也丢弃它。
  bool permanentlyDeleteTrash(String itemId) {
    final before = data.trash.length;
    final removed = data.trash.where((t) => t.item.id == itemId).toList();
    data.trash.removeWhere((t) => t.item.id == itemId);
    if (data.trash.length == before) return false;
    _changed();
    unawaited(_cleanupAttachments(
        removed.expand((t) => t.item.attached), _itemAttachDir));
    return true;
  }

  /// 清空回收站（逐条留墓碑，避免其他设备把条目再同步回来）。
  void clearTrash() {
    if (data.trash.isEmpty) return;
    final removed = List<TrashEntry>.from(data.trash);
    data.trash.clear();
    _changed();
    unawaited(_cleanupAttachments(
        removed.expand((t) => t.item.attached), _itemAttachDir));
  }

  /// 兼容旧调用：恢复任意回收站条目（未分类删除的仍回未分类）。
  bool restoreUnfiledItem(String itemId) => restoreTrashEntry(itemId);

  // ---------- 习惯 ----------

  Habit? habitById(String id) {
    for (final h in data.habits) {
      if (h.id == id) return h;
    }
    return null;
  }

  void addHabit(String name, String color,
      {String time = '', bool reminder = false}) {
    final n = name.trim();
    if (n.isEmpty) return;
    final h = Habit(
        id: _genId(), name: n, color: color, records: {}, time: time,
        reminder: reminder);
    h.sort = AppStore._frontSort(data.habits);
    data.habits.insert(0, h);
    _changed();
  }

  void updateHabit(String id,
      {String? name, String? color, String? time, bool? reminder}) {
    final h = habitById(id);
    if (h == null) return;
    final n = name?.trim() ?? '';
    if (n.isNotEmpty && data.habits.any((x) => x.id != id && x.name == n)) {
      return; // 重名拒绝
    }
    if (n.isNotEmpty) h.name = n;
    if (color != null) h.color = color;
    if (time != null) h.time = time;
    if (reminder != null) h.reminder = reminder;
    _changed();
  }

  void deleteHabit(String id) {
    data.habits.removeWhere((h) => h.id == id);
    _changed();
  }

  /// 直接设置某日打卡状态；status 传 null 移除记录。
  void setHabitRecord(String habitId, String dayKey, HabitStatus? status) {
    final h = habitById(habitId);
    if (h == null) return;
    if (status == null) {
      h.records.remove(dayKey);
    } else {
      h.records[dayKey] = status;
    }
    _changed();
  }

  void cycleHabitRecord(String habitId, String dayKey) {
    final h = habitById(habitId);
    if (h == null) return;
    final current = h.records[dayKey];
    switch (current) {
      case null:
        h.records[dayKey] = HabitStatus.done;
      case HabitStatus.done:
        h.records[dayKey] = HabitStatus.miss;
      case HabitStatus.miss:
        h.records.remove(dayKey);
    }
    _changed();
  }

  // ---------- 倒数本 ----------

  Milestone? milestoneById(String id) {
    for (final m in data.milestones) {
      if (m.id == id) return m;
    }
    return null;
  }

  Milestone addMilestone({
    required String title,
    required String date,
    bool yearly = false,
    bool pinned = false,
    String color = 'B0623C',
    String icon = 'favorite',
    List<int> reminds = const [0],
    bool lunar = false,
    int lunarMonth = 0,
    int lunarDay = 0,
    bool lunarLeap = false,
    bool featured = true,
    bool plusOne = false,
    bool highlight = false,
  }) {
    final m = Milestone(
      id: _genId(),
      title: title.trim(),
      date: date,
      yearly: yearly,
      pinned: pinned,
      color: color,
      icon: icon,
      reminds: reminds,
      plusOne: plusOne,
      highlight: highlight,
      lunar: lunar,
      lunarMonth: lunarMonth,
      lunarDay: lunarDay,
      lunarLeap: lunarLeap,
      featured: featured,
    );
    data.milestones.add(m);
    _changed();
    return m;
  }

  void replaceMilestone(Milestone updated) {
    final i = data.milestones.indexWhere((m) => m.id == updated.id);
    if (i < 0) return;
    data.milestones[i] = updated;
    _changed();
  }

  void deleteMilestone(String id) {
    data.milestones.removeWhere((m) => m.id == id);
    _changed();
  }

  // ---------- 日记 ----------

  /// 保存某天日记；标题、文字、心情均空且无图片时移除该条。
  void saveJournal(String dayKey, String title, String text, Mood? mood,
      {String? weather}) {
    final images = data.journal[dayKey]?.images ?? const <String>[];
    if (title.trim().isEmpty &&
        text.trim().isEmpty &&
        mood == null &&
        images.isEmpty) {
      data.journal.remove(dayKey);
    } else {
      final existing = data.journal[dayKey];
      if (existing != null) {
        existing.title = title;
        existing.text = text;
        existing.mood = mood;
        if (weather != null) existing.weather = weather;
      } else {
        data.journal[dayKey] = JournalEntry(
          date: dayKey,
          title: title,
          text: text,
          mood: mood,
          weather: weather ?? '',
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }
    _changed();
  }

  void setJournalShared(String dayKey, bool shared) {
    final entry = data.journal[dayKey];
    if (entry == null) return;
    entry.shared = shared;
    _changed();
  }

  /// 按条目 id 定位（含旧数据无 id 时按主键日期兜底）。
  JournalEntry? journalEntryById(String id) {
    for (final e in data.journal.values) {
      if (e.id == id || (e.id.isEmpty && e.date == id)) return e;
    }
    return null;
  }

  /// 当天全部日记条目（主条目在前，追加篇章按存储序）。
  List<JournalEntry> journalEntriesOn(String dayKey) {
    final main = data.journal[dayKey];
    final extra = data.journal.entries
        .where((e) => e.key.startsWith('$dayKey#'))
        .map((e) => e.value)
        .toList();
    return [?main, ...extra];
  }

  /// 追加一篇当日日记；entry.id 必须非空（键为 日期#id）。
  void addJournalEntry(JournalEntry entry) {
    if (entry.id.isEmpty) return;
    entry.updatedAt = entry.updatedAt > 0
        ? entry.updatedAt
        : DateTime.now().millisecondsSinceEpoch;
    data.journal[journalKeyOf(entry)] = entry;
    _changed();
  }

  /// 按 id 更新一篇日记的正文内容（编辑器防抖保存用）。
  /// 追加篇章全空且无图时自动删除，避免误点「再写一篇」留下空条目。
  void updateJournalEntry(String id, String title, String text, Mood? mood,
      {String? weather, required bool shared}) {
    final e = journalEntryById(id);
    if (e == null) return;
    e.title = title;
    e.text = text;
    e.mood = mood;
    if (weather != null) e.weather = weather;
    e.shared = shared;
    if (e.id.isNotEmpty &&
        e.images.isEmpty &&
        e.title.trim().isEmpty &&
        e.text.trim().isEmpty &&
        e.mood == null) {
      data.journal.removeWhere((k, v) => identical(v, e));
      _changed();
      return;
    }
    e.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _changed();
  }

  /// 按 id 删除一篇日记：先进回收站（FIFO 15）支持找回，再移除本体。
  /// 返回其存储键（撤销/找回用）；图片文件保留，恢复时一并回来。
  String? deleteJournalEntry(String id) {
    for (final k in data.journal.keys.toList()) {
      final e = data.journal[k];
      if (e != null && (e.id == id || (e.id.isEmpty && e.date == id))) {
        final dropped = _trashJournal(k, e);
        data.journal.remove(k);
        _changed();
        unawaited(_cleanupAttachments(dropped, _journalAttachDir));
        return k;
      }
    }
    return null;
  }

  /// 移入日记回收站；被替换的旧副本、超出 15 篇被挤出的条目
  /// 都返回给调用方清图片（最终是否删除由引用集决定）。
  List<String> _trashJournal(String key, JournalEntry e) {
    final dropped = <String>[
      for (final old in data.journalTrash)
        if (old.storageKey == key) ...old.entry.images,
    ];
    data.journalTrash
        .removeWhere((t) => t.storageKey == key);
    data.journalTrash.insert(
      0,
      JournalTrashItem(
        storageKey: key,
        entry: e,
        deletedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    while (data.journalTrash.length > 15) {
      final old = data.journalTrash.removeLast();
      dropped.addAll(old.entry.images);
    }
    return dropped;
  }

  /// 从回收站恢复一篇日记到原位。同键已有新内容时不覆盖（返回 false）。
  /// 恢复会把 updatedAt 提到现在并清除本机墓碑——墓碑合并已改为按时间
  /// 比较，删除之后重新写入的条目可以穿透墓碑同步到其他设备。
  bool restoreJournalTrash(String storageKey) {
    final i =
        data.journalTrash.indexWhere((t) => t.storageKey == storageKey);
    if (i < 0) return false;
    final t = data.journalTrash.removeAt(i);
    if (data.journal.containsKey(t.storageKey)) {
      data.journalTrash.insert(i, t);
      return false;
    }
    tombstones.remove('j:${t.storageKey}');
    t.entry.updatedAt = DateTime.now().millisecondsSinceEpoch;
    data.journal[t.storageKey] = t.entry;
    _changed();
    return true;
  }

  /// 设置某篇日记的共享状态（按 id）。
  void setJournalSharedById(String id, bool shared) {
    final e = journalEntryById(id);
    if (e == null) return;
    e.shared = shared;
    _changed();
  }

  /// 日记图片路径整体替换，条目不存在且有图片时补建。
  /// 键为篇章键（日期#id）时按篇章补建，date 字段保持纯日期。
  void setJournalImages(String key, List<String> paths) {
    final existing = data.journal[key];
    if (existing == null) {
      if (paths.isEmpty) return;
      final hashPos = key.indexOf('#');
      if (hashPos > 0) {
        final day = key.substring(0, hashPos);
        final id = key.substring(hashPos + 1);
        data.journal[key] = JournalEntry(
            date: day, id: id, images: List<String>.from(paths));
      } else {
        data.journal[key] =
            JournalEntry(date: key, images: List<String>.from(paths));
      }
    } else {
      existing.images = List<String>.from(paths);
    }
    _changed();
  }

  DateTime _parseKey(String key) {
    final p = key.split('-');
    if (p.length != 3) return DateTime(1970);
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return DateTime(1970);
    return DateTime(y, m, d);
  }
}
