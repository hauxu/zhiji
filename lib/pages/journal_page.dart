import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../ui/breakpoints.dart';
import '../widgets/responsive.dart';

import 'package:image_picker/image_picker.dart';
import 'package:lunar/lunar.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/colors.dart';
import '../data/milestone_icons.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/celebration.dart';
import '../util/attachments.dart';
import '../util/dates.dart';
import '../sync/sync_service.dart';
import '../weather/weather_service.dart';
import '../widgets/m3_dialog.dart';
import '../widgets/magnet_reorder.dart' show MagnetAction, showActionsPill;
import '../widgets/milestone_book.dart';
import 'milestone_book_page.dart';
import 'journal_share_page.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 日记页：记录、月历、搜索、导出。
class JournalPage extends StatefulWidget {
  const JournalPage({super.key});

  @override
  State<JournalPage> createState() => _JournalPageState();
}

enum _SaveState { idle, pending, saved }

class _JournalPageState extends State<JournalPage> with WidgetsBindingObserver {
  late final AppStore _store;
  DateTime _date = today();

  /// 上次看到的「今天」；跨天后仍停在今天就跟到新的一天。
  DateTime _todayRef = today();

  /// 当前编辑条目的存储键：默认=日期（主条目），追加篇章为 日期#id。
  String _entryKey = dateKey(today());
  final _titleCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  final _titleFocus = FocusNode();
  final _textFocus = FocusNode();
  Timer? _debounce;
  String? _liveWeather; // 今天实抓天气
  _SaveState _saveState = _SaveState.idle;
  DateTime? _savedAt;
  List<String> _images = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = context.read<AppStore>();
    _store.addListener(_onStoreChanged);
    _entryKey = dateKey(_date);
    _loadEntry();
    _fetchWeather();
  }

  /// 恢复备份/解锁日记会整体替换 store；非编辑中时重载当日条目，
  /// 防止旧控制器内容在下一次保存时覆盖刚恢复的数据。
  void _onStoreChanged() {
    if (!mounted) return;
    if (_debounce?.isActive ?? false) return; // 有待保存内容：用户正在编辑
    if (_titleFocus.hasFocus || _textFocus.hasFocus) {
      return; // 焦点在输入框：用户正在编辑
    }
    final entry = _store.data.journal[_entryKey];
    final title = entry?.title ?? '';
    final text = entry?.text ?? '';
    final images = List<String>.from(entry?.images ?? const []);
    if (_titleCtrl.text != title ||
        _textCtrl.text != text ||
        !_listEquals(_images, images)) {
      setState(() => _loadEntry());
    }
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _fetchWeather() async {
    final w = await WeatherService.getTodayWeather();
    if (w == null || !mounted) return;
    setState(() => _liveWeather = w);
    // 仅今天的日记写入实抓天气。
    final key = dateKey(today());
    final entry = _store.data.journal[key];
    // 仅对有实际内容的条目回写天气，空条目不回填。
    if (entry != null &&
        entry.weather.isEmpty &&
        (entry.title.isNotEmpty ||
            entry.text.isNotEmpty ||
            entry.mood != null)) {
      final mood = entry.mood;
      _store.saveJournal(key, entry.title, entry.text, mood, weather: w);
    }
  }

  void _loadEntry() {
    final entry = _store.data.journal[_entryKey];
    _titleCtrl.text = entry?.title ?? '';
    _textCtrl.text = entry?.text ?? '';
    _images = List<String>.from(entry?.images ?? const []);
    _saveState = _SaveState.idle;
    _savedAt = null;
  }

  /// 当前编辑条目（可能为 null=当天还没有日记）。
  JournalEntry? get _currentEntry => _store.data.journal[_entryKey];

  /// 当前条目的保存参数（旧数据无 id 用日期键定位主条目）。
  String get _currentId {
    final e = _currentEntry;
    return (e == null || e.id.isEmpty) ? dateKey(_date) : e.id;
  }

  void _saveCurrent({
    String? weather,
    Mood? moodOverride,
    bool applyMood = false,
  }) {
    final entry = _currentEntry;
    if (_entryKey.contains('#')) {
      if (entry == null) {
        // 追加篇章被「清空自动删篇」移除后仍在输入：按原 id 重建，不能回写主篇。
        final id = _entryKey.substring(_entryKey.indexOf('#') + 1);
        if (id.isNotEmpty &&
            (_titleCtrl.text.trim().isNotEmpty ||
                _textCtrl.text.trim().isNotEmpty ||
                _images.isNotEmpty ||
                moodOverride != null)) {
          _store.addJournalEntry(
            JournalEntry(
              id: id,
              date: dateKey(_date),
              title: _titleCtrl.text,
              text: _textCtrl.text,
              mood: moodOverride,
              weather: weather ?? '',
              images: List<String>.from(_images),
            ),
          );
        }
        return;
      }
      // 追加篇章：按 id 更新。
      _store.updateJournalEntry(
        _currentId,
        _titleCtrl.text,
        _textCtrl.text,
        applyMood ? moodOverride : entry.mood,
        weather: weather,
        shared: entry.shared,
      );
    } else {
      _store.saveJournal(
        dateKey(_date),
        _titleCtrl.text,
        _textCtrl.text,
        applyMood ? moodOverride : entry?.mood,
        weather: weather,
      );
    }
  }

  /// 退出前立即落盘待保存内容。
  void _flushSave() {
    final pending = _debounce?.isActive ?? false;
    _debounce?.cancel();
    if (!pending) return;
    _saveCurrent();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      _saveCurrent();
    }
    _store.removeListener(_onStoreChanged);
    _titleFocus.dispose();
    _textFocus.dispose();
    _titleCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final now = today();
    if (dateKey(_date) == dateKey(_todayRef) &&
        dateKey(now) != dateKey(_todayRef)) {
      // 先把旧的一天保存好，再切到新的一天，避免输入内容丢。
      _flushSave();
      _dropEmptyDraft();
      setState(() {
        _date = now;
        _entryKey = dateKey(now);
      });
      _loadEntry();
    }
    _todayRef = now;
  }

  void _goTo(DateTime d) {
    _flushSave();
    _dropEmptyDraft();
    setState(() {
      _date = d;
      _entryKey = dateKey(d);
    });
    _loadEntry();
  }

  /// 打开指定存储键的条目（历史列表点击自己的日记）。
  void _openEntryKey(String key) {
    _flushSave();
    final e = _store.data.journal[key];
    if (e == null) return;
    setState(() {
      _date = DateTime(
        int.parse(e.date.substring(0, 4)),
        int.parse(e.date.substring(5, 7)),
        int.parse(e.date.substring(8, 10)),
      );
      _entryKey = key;
    });
    _loadEntry();
  }

  /// 删除当前编辑的这篇（编辑器「删除此篇」入口）。
  Future<void> _confirmDeleteEntry() async {
    final entry = _currentEntry;
    if (entry == null) return;
    await _deleteEntryWithUndo(entry);
  }

  /// 删除指定一篇日记（主条目或追加篇章均可）：确认后进回收站，
  /// 顶部横幅 3.4 秒内可撤销；图片文件保留，恢复时一并回来。
  Future<void> _deleteEntryWithUndo(JournalEntry entry) async {
    final ok = await showM3Dialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这篇日记？'),
        content: const Text('可从「最近删除」找回'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final wasCurrent = journalKeyOf(entry) == _entryKey;
    final dayKey = entry.date;
    final remaining = _store
        .journalEntriesOn(dayKey)
        .where((e) => journalKeyOf(e) != journalKeyOf(entry))
        .toList();
    final key = _store.deleteJournalEntry(
      entry.id.isEmpty ? entry.date : entry.id,
    );
    if (key == null) return;
    if (wasCurrent) {
      setState(() {
        if (remaining.isNotEmpty) {
          final prev = remaining.last;
          _entryKey = journalKeyOf(prev);
          _date = DateTime(
            int.parse(prev.date.substring(0, 4)),
            int.parse(prev.date.substring(5, 7)),
            int.parse(prev.date.substring(8, 10)),
          );
        } else {
          _date = DateTime(
            int.parse(dayKey.substring(0, 4)),
            int.parse(dayKey.substring(5, 7)),
            int.parse(dayKey.substring(8, 10)),
          );
          _entryKey = dayKey;
        }
        _loadEntry();
      });
    }
    showTopToast(
      '已删除，可在「最近删除」找回',
      actionLabel: '撤销',
      onAction: () => _store.restoreJournalTrash(key),
    );
  }

  /// 丢弃当前「再写一篇」留下且还没输入的空篇章。
  void _dropEmptyDraft() {
    if (!_entryKey.contains('#')) return;
    final e = _store.data.journal[_entryKey];
    if (e == null) return;
    if (e.title.trim().isEmpty &&
        e.text.trim().isEmpty &&
        e.mood == null &&
        e.images.isEmpty) {
      _store.deleteJournalEntry(e.id.isEmpty ? e.date : e.id);
    }
  }

  /// 追加一篇当日日记并切入编辑。
  void _addNewEntry() {
    _flushSave();
    _dropEmptyDraft();
    final dayKey = dateKey(_date);
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final entry = JournalEntry(
      date: dayKey,
      id: id,
      title: '',
      text: '',
      weather: _liveWeather ?? '',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _store.addJournalEntry(entry);
    setState(() => _entryKey = journalKeyOf(entry));
    _loadEntry();
    _textFocus.requestFocus();
  }

  void _onChanged() {
    _debounce?.cancel();
    if (_saveState != _SaveState.pending) {
      setState(() => _saveState = _SaveState.pending);
    }
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _saveCurrent();
      if (mounted) {
        setState(() {
          _saveState = _SaveState.saved;
          _savedAt = DateTime.now();
        });
      }
    });
  }

  void _setMood(Mood? mood) {
    m3HapticSelect();
    _saveCurrent(moodOverride: mood, applyMood: true);
    setState(() {
      _saveState = _SaveState.saved;
      _savedAt = DateTime.now();
    });
  }

  /// 导入文本文件，追加到正文。
  Future<void> _importTextFile() async {
    final entryKey = _entryKey; // await 期间可能切日/切篇，写回捕获的键
    final dayKey = dateKey(_date);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: '文本文件',
            extensions: ['txt', 'md', 'csv', 'log', 'json'],
          ),
        ],
      );
      if (file == null) return;
      String content;
      try {
        content = await file.readAsString();
      } catch (_) {
        final bytes = await file.readAsBytes();
        content = String.fromCharCodes(bytes);
      }
      content = content.trim();
      if (content.isEmpty) return;
      if (!mounted) return;
      // 等待期间已切换日期：直接写回发起时的条目，不污染当前编辑。
      if (dateKey(_date) != dayKey || _entryKey != entryKey) {
        final entry = _store.data.journal[entryKey];
        final prev = entry?.text ?? '';
        final merged = prev.isEmpty ? content : '$prev\n\n$content';
        if (entry != null && entryKey.contains('#')) {
          _store.updateJournalEntry(
            entry.id,
            entry.title,
            merged,
            entry.mood,
            weather: entry.weather,
            shared: entry.shared,
          );
        } else {
          _store.saveJournal(dayKey, entry?.title ?? '', merged, entry?.mood);
        }
        return;
      }
      final current = _textCtrl.text.trim();
      _textCtrl.text = current.isEmpty ? content : '$current\n\n$content';
      _onChanged();
    } catch (_) {
      if (mounted) {
        showTopToast('导入失败，请换一个文本文件试试');
      }
    }
  }

  /// 添加日记图片并复制到文档目录。
  Future<void> _addImages() async {
    final entryKey = _entryKey; // await 期间可能切日/切篇，写回捕获的键
    List<XFile> pics;
    try {
      pics = await ImagePicker().pickMultiImage(
        imageQuality: 82,
        limit: 9 - _images.length,
      );
      if (pics.isEmpty) return;
    } catch (_) {
      if (mounted) {
        showTopToast('打开相册失败，请重试');
      }
      return;
    }
    for (final p in pics) {
      final saved = await copyIntoAppDir(p.path, 'journal_images');
      if (saved == null) continue;
      if (!mounted) {
        // 页面已关：刚复制的文件没人引用，顺手清掉。
        unawaited(deleteAttachQuietly(saved, 'journal_images'));
        return;
      }
      if (!_images.contains(saved)) _images.add(saved);
    }
    if (!mounted) return;
    _persistImages(entryKey);
    setState(() {});
  }

  void _removeImage(int index) {
    final removed = _images.removeAt(index);
    _persistImages();
    // 数据先落，再按全量引用决定删不删这个文件。
    unawaited(_store.removeAttachmentsIfUnused([removed], 'journal_images'));
  }

  void _persistImages([String? key]) {
    final k = key ?? _entryKey;
    // 条目不存在时先补建。
    if (_store.data.journal[k] == null) {
      _store.saveJournal(
        k.contains('#') ? k.substring(0, k.indexOf('#')) : k,
        _titleCtrl.text,
        _textCtrl.text,
        null,
      );
    }
    _store.setJournalImages(k, _images);
    setState(() {
      _saveState = _SaveState.saved;
      _savedAt = DateTime.now();
    });
  }

  /// 打开倒数本子页面（日期与胶囊的共同入口）。
  void _openMilestones() {
    final sync = context.read<SyncService>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MilestoneBookPage(
          merged: sync.mergedMilestones(today()),
          partnerName: sync.partnerName,
        ),
      ),
    );
  }

  void _showMoodSheet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entry = _currentEntry;
    showM3Sheet<void>(
      context: context,
      // 十二宫格心情在小屏超过半屏上限，放开高度并用滚动兜底。
      isScrollControlled: true,
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isToday ? '今天的心情' : '这天的心情',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.85,
              children: [
                for (final mood in Mood.values)
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      _setMood(entry?.mood == mood ? null : mood);
                      Navigator.of(sheetContext).pop();
                    },
                    child: AnimatedContainer(
                      duration: m3Small,
                      curve: m3CurveIn,
                      decoration: BoxDecoration(
                        color: entry?.mood == mood
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: entry?.mood == mood
                              ? scheme.primary
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            moodIcon(mood),
                            size: 26,
                            color: entry?.mood == mood
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            moodLabel(mood),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: entry?.mood == mood
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 当日多篇的篇目切换条（追加入口在编辑器底部操作行）。
  Widget _buildEntryTabs(AppStore store, ColorScheme scheme) {
    final dayKey = dateKey(_date);
    final entries = store.journalEntriesOn(dayKey);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < entries.length; i++)
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openEntryKey(journalKeyOf(entries[i])),
              child: AnimatedContainer(
                duration: m3Small,
                curve: m3CurveIn,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: journalKeyOf(entries[i]) == _entryKey
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: journalKeyOf(entries[i]) == _entryKey
                        ? scheme.primary
                        : scheme.outlineVariant,
                  ),
                ),
                child: Text(
                  i == 0 ? '第 1 篇' : '第 ${i + 1} 篇',
                  style: TextStyle(
                    fontSize: 11,
                    color: journalKeyOf(entries[i]) == _entryKey
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String get _saveLabel => switch (_saveState) {
    _SaveState.pending => '保存中…',
    _SaveState.saved =>
      '已保存 ${_savedAt!.hour.toString().padLeft(2, '0')}:${_savedAt!.minute.toString().padLeft(2, '0')}',
    _SaveState.idle => '自动保存',
  };

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final key = dateKey(_date);
    final entry = store.data.journal[_entryKey];
    final isToday = key == dateKey(today());
    final sync = context.watch<SyncService>();
    final isBound = sync.isBound;
    final mergedAll = sync.mergedMilestones(today());
    (Milestone, bool)? nearestMilestone;
    if (isToday) {
      final upcoming =
          mergedAll
              .where((r) => r.$1.featured && !r.$1.isPast(today()))
              .toList()
            ..sort(
              (a, b) =>
                  a.$1.daysUntil(today()).compareTo(b.$1.daysUntil(today())),
            );
      if (upcoming.isNotEmpty) nearestMilestone = upcoming.first;
    }

    // 天气优先用日记存档值。
    final shownWeather = (entry?.weather ?? '').isNotEmpty
        ? entry!.weather
        : (isToday ? _liveWeather : null);

    final editorCard = Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 当日多篇：篇目切换条 + 再写一篇。
            _buildEntryTabs(store, scheme),
            Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _showMoodSheet(context),
                  key: const ValueKey('mood-pill'),
                  child: AnimatedContainer(
                    duration: m3Small,
                    curve: m3CurveIn,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: entry?.mood != null
                          ? moodColor(entry!.mood).withValues(alpha: 0.14)
                          : scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: entry?.mood != null
                            ? moodColor(entry!.mood).withValues(alpha: 0.4)
                            : scheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          moodIcon(entry?.mood),
                          size: 16,
                          color: entry?.mood != null
                              ? moodColor(entry!.mood)
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          entry?.mood != null ? moodLabel(entry?.mood) : '记录心情',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            color: entry?.mood != null
                                ? moodColor(entry!.mood)
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                if (isBound && entry != null) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      m3HapticSelect();
                      store.setJournalSharedById(_currentId, !entry.shared);
                    },
                    child: AnimatedContainer(
                      duration: m3Small,
                      curve: m3CurveIn,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: entry.shared
                            ? scheme.tertiaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: entry.shared
                              ? scheme.tertiary
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            entry.shared
                                ? Icons.favorite_rounded
                                : Icons.visibility_outlined,
                            size: 13,
                            color: entry.shared
                                ? scheme.tertiary
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            entry.shared ? '对方可见' : '给对方看',
                            style: TextStyle(
                              fontSize: 12,
                              color: entry.shared
                                  ? scheme.tertiary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (shownWeather != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _weatherIcon(shownWeather),
                        size: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        shownWeather,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _titleCtrl,
              focusNode: _titleFocus,
              maxLength: 30,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _textFocus.requestFocus(),
              scrollPadding: const EdgeInsets.only(bottom: 120),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                labelText: '标题',
                counterText: '',
              ),
              onChanged: (_) => _onChanged(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _textCtrl,
              focusNode: _textFocus,
              maxLines: null,
              minLines: 6,
              scrollPadding: const EdgeInsets.only(bottom: 120),
              onChanged: (_) => _onChanged(),
              decoration: const InputDecoration(labelText: '写点什么'),
            ),
            if (_images.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 96,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var i = 0; i < _images.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(
                                File(_images[i]),
                                width: 96,
                                height: 96,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  width: 96,
                                  height: 96,
                                  color: scheme.surfaceContainerHigh,
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: InkWell(
                                borderRadius: const BorderRadius.only(
                                  topRight: Radius.circular(10),
                                  bottomLeft: Radius.circular(10),
                                ),
                                onTap: () => _removeImage(i),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  color: scheme.scrim.withValues(alpha: 0.55),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 13,
                                    color: scheme.onSurface,
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
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  _saveLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_textCtrl.text.length} 字',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '再写一篇',
                  visualDensity: VisualDensity.compact,
                  onPressed: _addNewEntry,
                  icon: Icon(
                    Icons.post_add_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (_currentEntry != null)
                  IconButton(
                    tooltip: '删除此篇',
                    visualDensity: VisualDensity.compact,
                    onPressed: _confirmDeleteEntry,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                IconButton(
                  tooltip: '写完了',
                  visualDensity: VisualDensity.compact,
                  onPressed: _saveState == _SaveState.pending
                      ? null
                      : () {
                          _flushSave();
                          Celebration.complete(context);
                        },
                  icon: Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  tooltip: _images.isEmpty
                      ? '添加图片（保存在本机）'
                      : '添加图片（${_images.length}/9，保存在本机）',
                  visualDensity: VisualDensity.compact,
                  onPressed: _images.length >= 9 ? null : _addImages,
                  icon: Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '生成图片分享',
                  visualDensity: VisualDensity.compact,
                  onPressed: entry == null || entry.isEmpty
                      ? null
                      : () {
                          _flushSave();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => JournalSharePage(
                                date: _date,
                                title: entry.title,
                                text: entry.text,
                                mood: entry.mood,
                                weather: shownWeather,
                              ),
                            ),
                          );
                        },
                  icon: Icon(
                    Icons.ios_share_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final bookCard = MilestoneBookCard(
      merged: mergedAll,
      partnerName: sync.partnerName,
    );
    final historyCard = _HistoryCard(
      currentKey: key,
      currentEntryKey: _entryKey,
      onJump: (d) => _goTo(d),
      onOpenEntries: (list, initialIndex) => _showJournalReader(
        context,
        list,
        initialIndex,
        isMine: true,
        ownerName: '我',
        partnerKeys: isBound
            ? (sync.partner?.data.journal.keys.toSet() ?? const <String>{})
            : const <String>{},
        onEdit: (e) {
          Navigator.of(context).pop();
          _openEntryKey(journalKeyOf(e));
        },
        onDelete: (e) {
          Navigator.of(context).pop();
          _deleteEntryWithUndo(e);
        },
      ),
      onOpenPartnerEntries: (list, initialIndex) => _showJournalReader(
        context,
        list,
        initialIndex,
        isMine: false,
        ownerName: sync.partnerName,
      ),
      onEditEntry: (e) => _openEntryKey(journalKeyOf(e)),
      onDeleteEntry: (e) => _deleteEntryWithUndo(e),
      partnerEntries: isBound ? sync.partner?.data.journal : null,
      partnerName: sync.partnerName,
    );
    final monthCard = _MonthCard(
      entries: store.data.journal,
      milestones: [
        ...store.data.milestones.where((m) => m.featured),
        ...?sync.partner?.data.milestones.where((m) => m.featured),
      ],
      selectedKey: key,
      onJump: (d) => _goTo(d),
    );
    final dateHeader = Row(
      children: [
        IconButton.filledTonal(
          tooltip: '前一天',
          onPressed: () => _goTo(_date.subtract(const Duration(days: 1))),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _openMilestones,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        isToday ? '今天' : monthDay(_date),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                      if (nearestMilestone != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: colorFromHex(nearestMilestone.$1.color)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  milestoneIcon(nearestMilestone.$1.icon),
                                  size: 12,
                                  color: colorFromHex(
                                    nearestMilestone.$1.color,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    '${nearestMilestone.$1.title}'
                                    ' · ${nearestMilestone.$1.daysLabel(today())}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: colorFromHex(
                                        nearestMilestone.$1.color,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _lunarLine,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButton.filledTonal(
          tooltip: isToday ? '已是今天' : '后一天',
          onPressed: isToday
              ? null
              : () => _goTo(_date.add(const Duration(days: 1))),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('日子'),
        actions: [
          IconButton(
            tooltip: '导入文本文件',
            onPressed: _importTextFile,
            icon: const Icon(Icons.upload_file_rounded),
          ),
        ],
      ),
      body: context.isExpanded
          ? Row(
              children: [
                SizedBox(
                  width: 380,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      bookCard,
                      const SizedBox(height: 12),
                      monthCard,
                      const SizedBox(height: 12),
                      historyCard,
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      dateHeader,
                      if (!isToday)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ActionChip(
                            avatar: const Icon(Icons.today_rounded, size: 16),
                            label: const Text('回今天'),
                            onPressed: () => _goTo(today()),
                          ),
                        ),
                      editorCard,
                    ],
                  ),
                ),
              ],
            )
          : ResponsiveContent(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  dateHeader,
                  if (!isToday)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ActionChip(
                        avatar: const Icon(Icons.today_rounded, size: 16),
                        label: const Text('回今天'),
                        onPressed: () => _goTo(today()),
                      ),
                    ),
                  AnimatedSwitcher(
                    duration: m3Medium,
                    switchInCurve: m3CurveIn,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.02),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Column(
                      key: ValueKey(key),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 固定排布：日记编辑在上、倒数本在下（设置页已去掉排序开关）。
                        editorCard,
                        const SizedBox(height: 12),
                        bookCard,
                        const SizedBox(height: 12),
                        monthCard,
                        const SizedBox(height: 12),
                        historyCard,
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// 农历 + 星期小字，如「丙午年 · 农历八月十八 · 星期五」。
  String get _lunarLine {
    final lu = Lunar.fromDate(_date);
    final leap = lu.getMonth().isNegative;
    final month = leap ? -lu.getMonth() : lu.getMonth();
    final gz = lu.getYearInGanZhi();
    final leapTag = leap ? '闰' : '';
    return '$gz年 · 农历$leapTag$month月${lu.getDayInChinese()}'
        ' · ${weekdayCn(_date)}';
  }

  bool get isToday => dateKey(_date) == dateKey(today());
}

IconData _weatherIcon(String weather) {
  if (weather.contains('雨')) return Icons.umbrella_rounded;
  if (weather.contains('雪')) return Icons.ac_unit_rounded;
  if (weather.contains('云') || weather.contains('阴')) {
    return Icons.cloud_rounded;
  }
  if (weather.contains('雾') || weather.contains('霾')) {
    return Icons.blur_on_rounded;
  }
  if (weather.contains('雷')) return Icons.thunderstorm_rounded;
  return Icons.wb_sunny_rounded;
}

Color moodColor(Mood? mood) => switch (mood) {
  Mood.good => const Color(0xFFF9AB00),
  Mood.excited => const Color(0xFFEA6C5B),
  Mood.calm => const Color(0xFF5B8DEF),
  Mood.plain => const Color(0xFF9AA0A6),
  Mood.tired => const Color(0xFF6FA8A0),
  Mood.low => const Color(0xFF7986CB),
  Mood.anxious => const Color(0xFFA36BC0),
  Mood.grateful => const Color(0xFFE86FA4),
  Mood.energetic => const Color(0xFF66BB6A),
  Mood.focused => const Color(0xFF29B6F6),
  Mood.moved => const Color(0xFFFF8A65),
  Mood.gloomy => const Color(0xFF8D6E63),
  null => const Color(0xFF9AA0A6),
};

/// 当月月历：心情色点 + 点按跳转 + 本月统计。
class _MonthCard extends StatefulWidget {
  const _MonthCard({
    required this.entries,
    required this.milestones,
    required this.selectedKey,
    required this.onJump,
  });

  final Map<String, JournalEntry> entries;

  /// 双方倒数本合并，发生日的格子加色点。
  final List<Milestone> milestones;
  final String selectedKey;
  final void Function(DateTime date) onJump;

  @override
  State<_MonthCard> createState() => _MonthCardState();
}

class _MonthCardState extends State<_MonthCard> {
  late DateTime _month = DateTime(
    _parseKey(widget.selectedKey).year,
    _parseKey(widget.selectedKey).month,
  );
  late final PageController _pageCtrl = PageController(
    initialPage: _indexFor(_month),
  );

  static int _indexFor(DateTime m) => m.year * 12 + m.month - 1;
  static DateTime _monthFor(int idx) => DateTime(idx ~/ 12, idx % 12 + 1);

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MonthCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅当所选日期真正变化（且跨月）时月历跟随跳页；
    // 用户自行翻看其他月份时，重建（自动保存/同步等）不得拽回。
    if (oldWidget.selectedKey == widget.selectedKey) return;
    final sel = _parseKey(widget.selectedKey);
    final idx = _indexFor(DateTime(sel.year, sel.month));
    if (_pageCtrl.hasClients && _pageCtrl.page?.round() != idx) {
      _pageCtrl.jumpToPage(idx);
    }
    final selMonth = DateTime(sel.year, sel.month);
    if (_month != selMonth) setState(() => _month = selMonth);
  }

  static DateTime _parseKey(String key) {
    final p = key.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  void _goMonth(int delta) {
    final page =
        (_pageCtrl.hasClients ? _pageCtrl.page?.round() : null) ??
        _indexFor(_month);
    _pageCtrl.animateToPage(
      page + delta,
      duration: const Duration(milliseconds: 280),
      curve: m3CurveIn,
    );
  }

  Future<void> _pickMonth() async {
    final now = today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _month.isAfter(now) ? now : _month,
      firstDate: now.subtract(const Duration(days: 365 * 5)),
      lastDate: now,
    );
    if (!mounted || !_pageCtrl.hasClients) return;
    if (picked != null) {
      _pageCtrl.jumpToPage(_indexFor(DateTime(picked.year, picked.month)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = today();
    final monthEnd = DateTime(_month.year, _month.month + 1);
    final todayKey = dateKey(now);

    var monthCount = 0;
    for (
      var d = DateTime(_month.year, _month.month);
      d.isBefore(monthEnd);
      d = d.add(const Duration(days: 1))
    ) {
      // 当日存在任意条目（主条目或追加篇章）都计入。
      if (widget.entries.containsKey(dateKey(d)) ||
          widget.entries.keys.any((k) => k.startsWith('${dateKey(d)}#'))) {
        monthCount++;
      }
    }
    // 连续记录：从今天往回数。
    bool hasAnyEntry(DateTime d) =>
        widget.entries.containsKey(dateKey(d)) ||
        widget.entries.keys.any((k) => k.startsWith('${dateKey(d)}#'));
    var streak = 0;
    var cursor = hasAnyEntry(now) ? now : now.subtract(const Duration(days: 1));
    while (hasAnyEntry(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '心情月历',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _goMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                ),
                // 点月份名快速切换年月。
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _pickMonth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Text(
                      '${_month.year}年${_month.month}月',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _goMonth(1),
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
                  Expanded(
                    child: Center(
                      child: Text(
                        w,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // 统一 6 行高度：5 行月留白，翻页不跳动；跟手 + 吸附动画。
            SizedBox(
              height: 6 * 46,
              child: PageView.builder(
                controller: _pageCtrl,
                onPageChanged: (idx) => setState(() => _month = _monthFor(idx)),
                itemBuilder: (context, idx) =>
                    _buildGrid(_monthFor(idx), now, todayKey),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '本月 $monthCount 篇 · 连续 $streak 天',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: moodColor(Mood.good),
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  '心情',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFB0623C),
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  '倒数日',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(DateTime month, DateTime now, String todayKey) {
    return Column(
      children: [
        for (var row = 0; row < 6; row++)
          Row(
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(child: _dayCell(row, col, now, todayKey, month)),
            ],
          ),
      ],
    );
  }

  Widget _dayCell(
    int row,
    int col,
    DateTime now,
    String todayKey,
    DateTime month,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final firstWeekday = DateTime(month.year, month.month).weekday;
    final dayNumber = row * 7 + col - (firstWeekday - 1);
    if (dayNumber < 1 ||
        dayNumber > DateTime(month.year, month.month + 1, 0).day) {
      return const SizedBox(height: 42);
    }
    final d = DateTime(month.year, month.month, dayNumber);
    final future = d.isAfter(now);
    final key = dateKey(d);
    // 心情显示主条目优先；该日只有追加篇章时取第一篇有心情的。
    var entry = widget.entries[key];
    if (entry == null || entry.mood == null) {
      for (final e in widget.entries.values) {
        if (e.date == key && e.mood != null) {
          entry ??= e;
          if (identical(entry, e)) break;
        }
      }
    }
    final hasEntry =
        widget.entries.containsKey(key) ||
        widget.entries.keys.any((k) => k.startsWith('$key#'));
    final isToday = key == todayKey;
    final isSelected = key == widget.selectedKey;

    Milestone? dayMilestone;
    for (final m in widget.milestones) {
      if (m.occursOnDate(d)) {
        dayMilestone = m;
        break;
      }
    }

    final cell = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '$dayNumber',
          style: TextStyle(
            fontSize: 12,
            fontWeight: isToday || isSelected
                ? FontWeight.bold
                : hasEntry || dayMilestone != null
                ? FontWeight.w600
                : FontWeight.w400,
            color: future
                ? scheme.outlineVariant
                : isSelected
                ? scheme.onPrimary
                : scheme.onSurface,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: !hasEntry
                    ? Colors.transparent
                    : entry?.mood != null
                    ? moodColor(entry?.mood)
                    : scheme.outlineVariant,
              ),
            ),
            if (dayMilestone != null) ...[
              const SizedBox(width: 4),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorFromHex(dayMilestone.color),
                ),
              ),
            ],
          ],
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(1),
      child: SizedBox(
        height: 42,
        child: future
            ? cell
            : InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  m3HapticSelect();
                  widget.onJump(d);
                },
                child: AnimatedContainer(
                  duration: m3Small,
                  curve: m3CurveIn,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: isSelected ? scheme.primary : Colors.transparent,
                    border: isToday && !isSelected
                        ? Border.all(color: scheme.primary, width: 1.5)
                        : null,
                  ),
                  child: cell,
                ),
              ),
      ),
    );
  }
}

IconData moodIcon(Mood? mood) => switch (mood) {
  Mood.good => Icons.wb_sunny_rounded,
  Mood.calm => Icons.self_improvement_rounded,
  Mood.tired => Icons.battery_2_bar_rounded,
  Mood.low => Icons.cloud_rounded,
  Mood.anxious => Icons.psychology_rounded,
  Mood.excited => Icons.celebration_rounded,
  Mood.grateful => Icons.favorite_rounded,
  Mood.plain => Icons.water_drop_rounded,
  Mood.energetic => Icons.center_focus_strong_rounded,
  Mood.focused => Icons.volunteer_activism_rounded,
  Mood.moved => Icons.lunch_dining_rounded,
  Mood.gloomy => Icons.thunderstorm_rounded,
  null => Icons.edit_note_rounded,
};

/// 心情标准式样：圆形底 moodColor@14% + 图标同色。
/// 没选心情时不渲染任何图标（历史上此处误用编辑占位图标，看着像个心情）。
Widget moodBadge(Mood? mood, {double size = 34, double iconSize = 18}) {
  if (mood == null) return const SizedBox.shrink();
  final c = moodColor(mood);
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: c.withValues(alpha: 0.14),
    ),
    child: Icon(moodIcon(mood), size: iconSize, color: c),
  );
}

String moodLabel(Mood? mood) => switch (mood) {
  Mood.good => '元气满满',
  Mood.calm => '平静安稳',
  Mood.tired => '有点累',
  Mood.low => '有点低落',
  Mood.anxious => '焦虑不安',
  Mood.excited => '充满期待',
  Mood.grateful => '喜欢',
  Mood.plain => '平淡如水',
  Mood.energetic => '十分专注',
  Mood.focused => '感恩的心',
  Mood.moved => '馋馋馋',
  Mood.gloomy => '小发雷霆',
  null => '',
};

/// 只读查看一篇日记（自己的与 TA 分享的都可以，多篇时分栏查看）。
/// 自己的篇目底部带「编辑 / 删除」操作，回调由页面注入。
Future<void> _showJournalReader(
  BuildContext context,
  List<JournalEntry> entries,
  int initialIndex, {
  required bool isMine,
  required String ownerName,
  Set<String> partnerKeys = const {},
  void Function(JournalEntry e)? onEdit,
  void Function(JournalEntry e)? onDelete,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final titles = [
    for (var i = 0; i < entries.length; i++)
      entries.length == 1 ? '日记' : '第 ${i + 1} 篇',
  ];
  await showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DefaultTabController(
      length: entries.length,
      initialIndex: initialIndex.clamp(0, entries.length - 1),
      child: DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            if (entries.length > 1)
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                labelColor: scheme.primary,
                unselectedLabelColor: scheme.onSurfaceVariant,
                indicatorSize: TabBarIndicatorSize.tab,
                tabs: [for (final t in titles) Tab(text: t)],
              ),
            Expanded(
              child: TabBarView(
                children: [
                  for (final e in entries)
                    ListView(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                      children: [
                        Row(
                          children: [
                            moodBadge(e.mood, size: 34, iconSize: 18),
                            if (e.mood != null) const SizedBox(width: 8),
                            Text(
                              '${(isMine && !partnerKeys.contains(journalKeyOf(e))) ? '我的日记' : '$ownerName 的日记'} · ${e.date}',
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (e.title.trim().isNotEmpty)
                          Text(
                            e.title.trim(),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        if (e.title.trim().isNotEmpty)
                          const SizedBox(height: 10),
                        if (e.weather.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.cloud_outlined,
                                  size: 15,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  e.weather,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        SelectableText(
                          e.text.trim(),
                          style: const TextStyle(fontSize: 15, height: 1.7),
                        ),
                        const SizedBox(height: 24),
                        if ((isMine &&
                                !partnerKeys.contains(journalKeyOf(e))) &&
                            (onEdit != null || onDelete != null))
                          Row(
                            children: [
                              if (onEdit != null)
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: () => onEdit(e),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 17,
                                    ),
                                    label: const Text('编辑'),
                                  ),
                                ),
                              if (onEdit != null && onDelete != null)
                                const SizedBox(width: 10),
                              if (onDelete != null)
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: () => onDelete(e),
                                    icon: Icon(
                                      Icons.delete_outline_rounded,
                                      size: 17,
                                      color: scheme.error,
                                    ),
                                    label: Text(
                                      '删除',
                                      style: TextStyle(color: scheme.error),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        if ((isMine &&
                                !partnerKeys.contains(journalKeyOf(e))) &&
                            (onEdit != null || onDelete != null))
                          const SizedBox(height: 14),
                        Text(
                          (isMine && !partnerKeys.contains(journalKeyOf(e)))
                              ? '我的日记 · 在上方编辑器中可继续编辑'
                              : '来自 $ownerName 的分享 · 只读',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 「最近删除」：已删日记的回收站，可单条恢复到原位。
Future<void> _showJournalTrashSheet(
  BuildContext context,
  AppStore store,
) async {
  await showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _JournalTrashSheet(store: store),
  );
}

class _JournalTrashSheet extends StatefulWidget {
  const _JournalTrashSheet({required this.store});

  final AppStore store;

  @override
  State<_JournalTrashSheet> createState() => _JournalTrashSheetState();
}

class _JournalTrashSheetState extends State<_JournalTrashSheet> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final trash = widget.store.data.journalTrash;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    '最近删除',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    trash.isEmpty ? '' : '${trash.length} 篇 · 最多保留 15 篇',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (trash.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Text(
                    '没有已删除的日记',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final t in trash)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: t.entry.mood != null
                              ? moodBadge(t.entry.mood, size: 30, iconSize: 16)
                              : CircleAvatar(
                                  radius: 15,
                                  backgroundColor: scheme.surfaceContainerHigh,
                                ),
                          title: Text(
                            t.entry.title.trim().isNotEmpty
                                ? t.entry.title.trim()
                                : (t.entry.text.trim().isNotEmpty
                                      ? t.entry.text.trim()
                                      : '（无文字）'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${t.entry.date} · ${_trashTime(t.deletedAt)} 删除',
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: TextButton(
                            onPressed: () {
                              final ok = widget.store.restoreJournalTrash(
                                t.storageKey,
                              );
                              if (!ok) {
                                showTopToast('当天已有新内容，无法覆盖恢复');
                              }
                            },
                            child: const Text('恢复'),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _trashTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${monthDay(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class _HistoryCard extends StatefulWidget {
  const _HistoryCard({
    required this.currentKey,
    required this.currentEntryKey,
    required this.onJump,
    required this.onOpenEntries,
    required this.onOpenPartnerEntries,
    required this.onEditEntry,
    required this.onDeleteEntry,
    this.partnerEntries,
    this.partnerName,
  });

  final String currentKey;

  /// 当前编辑条目的存储键：历史列表据此精确标「正在看」。
  final String currentEntryKey;
  final void Function(DateTime date) onJump;

  /// 弹只读阅读窗：按当日全部篇目分栏，[initialIndex] 定位点击的篇。
  final void Function(List<JournalEntry> entries, int initialIndex)
  onOpenEntries;

  /// 同上，但内容为 TA 分享的篇目。
  final void Function(List<JournalEntry> entries, int initialIndex)
  onOpenPartnerEntries;

  /// 列表长按/阅读窗「编辑」：把该篇载入上方编辑器。
  final void Function(JournalEntry e) onEditEntry;

  /// 列表长按/阅读窗「删除」：确认后进回收站，可撤销。
  final void Function(JournalEntry e) onDeleteEntry;

  /// TA 分享的日记，只读混入列表。
  final Map<String, JournalEntry>? partnerEntries;
  final String? partnerName;

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    var entries = store.data.journal.values.toList();
    // 混入 TA 分享的日记（只读）。同日键冲突也保留——多篇章键唯一后
    // TA 与自己同日共存是常态，用对象身份区分来源。
    final taEntries = <JournalEntry>{};
    widget.partnerEntries?.forEach((k, v) {
      if (!taEntries.contains(v)) {
        taEntries.add(v);
        entries.add(v);
      }
    });
    entries.sort((a, b) => b.date.compareTo(a.date));

    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      entries = entries
          .where(
            (e) =>
                e.title.toLowerCase().contains(q) ||
                e.text.toLowerCase().contains(q) ||
                e.date.contains(q),
          )
          .toList();
    }

    final months = <String, List<JournalEntry>>{};
    for (final e in entries) {
      // date 字段来自对端数据，长度不足直接跳过（畸形防御）。
      if (e.date.length < 7) continue;
      months.putIfAbsent(e.date.substring(0, 7), () => []).add(e);
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '全部日记',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Tooltip(
                  message: '最近删除',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _showJournalTrashSheet(context, store),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.delete_outline_rounded,
                        size: 19,
                        color: store.data.journalTrash.isEmpty
                            ? scheme.onSurfaceVariant
                            : scheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // 搜索框恒显示：可搜自己的与 TA 分享的全部条目。
            const SizedBox(height: 10),
            TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索日记内容或日期（如 2026-09）',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
            if (entries.isEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _query.trim().isEmpty
                      ? '日记按月保存，点一下可回看'
                      : '没有匹配「${_query.trim()}」的日记',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ] else ...[
              for (final month in months.keys) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 2),
                  child: Text(
                    '${month.substring(0, 4)}年${int.parse(month.substring(5, 7))}月',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
                for (final e in months[month]!)
                  _historyRow(
                    context,
                    scheme,
                    e,
                    isTa: taEntries.contains(e),
                    allEntries: entries,
                  ),
              ],
            ],
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  String _dayTitle(String key) {
    final d = _parseKey(key);
    final todayKey = dateKey(today());
    if (key == todayKey) return '今天 · ${monthDay(d)} ${weekdayCn(d)}';
    if (key == dateKey(today().subtract(const Duration(days: 1)))) {
      return '昨天 · ${monthDay(d)} ${weekdayCn(d)}';
    }
    return '${monthDay(d)} ${weekdayCn(d)}';
  }

  /// 历史列表一行：自己的篇目支持长按操作胶囊（编辑/删除），
  /// TA 分享的只读无操作。[allEntries] 为自己的+TA 的合并列表（当日分栏用）。
  Widget _historyRow(
    BuildContext context,
    ColorScheme scheme,
    JournalEntry e, {
    required bool isTa,
    required List<JournalEntry> allEntries,
  }) {
    final row = ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: e.mood != null
          ? moodBadge(e.mood, size: 30, iconSize: 16)
          : CircleAvatar(
              radius: 15,
              backgroundColor: scheme.surfaceContainerHigh,
            ),
      title: Text(_dayTitle(e.date), style: const TextStyle(fontSize: 13)),
      subtitle: e.title.trim().isNotEmpty || e.text.trim().isNotEmpty
          ? Text(
              e.title.trim().isNotEmpty ? e.title.trim() : e.text.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            )
          : null,
      trailing: journalKeyOf(e) == widget.currentEntryKey
          ? Text('正在看', style: TextStyle(fontSize: 11, color: scheme.primary))
          : (isTa || e.shared
                ? Icon(
                    Icons.visibility_rounded,
                    size: 14,
                    color: scheme.tertiary,
                  )
                : null),
      onTap: () {
        m3HapticSelect();
        // 当日全部篇目一起弹窗分栏查看，定位到点击的这篇。
        final dayEntries = allEntries.where((x) => x.date == e.date).toList();
        final idx = dayEntries.indexOf(e);
        if (isTa) {
          widget.onOpenPartnerEntries(dayEntries, idx < 0 ? 0 : idx);
        } else {
          widget.onOpenEntries(dayEntries, idx < 0 ? 0 : idx);
        }
      },
    );
    if (isTa) return row;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPressStart: (d) => _showRowActions(context, d.globalPosition, e),
      child: row,
    );
  }

  void _showRowActions(BuildContext context, Offset pos, JournalEntry e) {
    final scheme = Theme.of(context).colorScheme;
    m3HapticSelect();
    showActionsPill(context, pos, [
      MagnetAction(
        icon: Icons.edit_outlined,
        label: '编辑',
        onTap: () => widget.onEditEntry(e),
      ),
      MagnetAction(
        icon: Icons.delete_outline_rounded,
        label: '删除',
        color: scheme.error,
        onTap: () => widget.onDeleteEntry(e),
      ),
    ]);
  }

  static DateTime _parseKey(String key) {
    final p = key.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }
}
