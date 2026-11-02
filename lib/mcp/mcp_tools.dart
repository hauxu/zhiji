import 'dart:io';

import '../data/models.dart';
import '../data/store.dart';
import '../sync/sync_service.dart';
import '../util/dates.dart';

/// 一个 MCP 工具的声明与实现。
class McpTool {
  McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.run,
    this.readOnly = true,
    this.destructive = false,
    this.needsWrite = false,
    this.needsPrivate = false,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<Object?> Function(
    AppStore store,
    SyncService sync,
    Map<String, dynamic> args,
  )
  run;

  /// 只读工具：annotations.readOnlyHint。
  final bool readOnly;

  /// 破坏性操作：annotations.destructiveHint。
  final bool destructive;

  /// 需要「允许写入」开关。
  final bool needsWrite;

  /// 需要「允许读取日记与留言」开关。
  final bool needsPrivate;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': {
      'title': description,
      'readOnlyHint': readOnly,
      'destructiveHint': destructive,
      'openWorldHint': false,
    },
  };
}

Map<String, dynamic> _schema(
  Map<String, dynamic> props, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': props,
  if (required.isNotEmpty) 'required': required,
  'additionalProperties': false,
};

Map<String, dynamic> _str(String desc) => {'type': 'string', 'description': desc};
Map<String, dynamic> _bool(String desc) => {'type': 'boolean', 'description': desc};
Map<String, dynamic> _int(String desc) => {'type': 'integer', 'description': desc};

String _s(Object? v) => v is String ? v : '';

/// 把任务转成给智能体看的扁平结构。
Map<String, dynamic> taskJson(PlanTask t) => {
  'id': t.id,
  'title': t.title,
  'date': t.date,
  'memo': !t.hasDate && !t.isRecurring,
  'start': t.start,
  'end': t.end,
  'done': t.done,
  'doneDates': t.doneDates,
  'recurring': t.isRecurring,
  'repeat': t.repeatMode.name,
  'note': t.note,
  'starred': t.starred,
  'archived': t.archived,
  'remindBefore': t.remindBefore,
  'updatedAt': t.updatedAt,
};

Map<String, dynamic> _listJson(TaskList l) => {
  'id': l.id,
  'name': l.name,
  'color': l.color,
  'shared': l.shared,
  'coEdit': l.coEdit,
  'itemCount': l.items.length,
  'updatedAt': l.updatedAt,
};

Map<String, dynamic> _itemJson(ListItem i) => {
  'id': i.id,
  'title': i.title,
  'done': i.done,
  'note': i.note,
  'date': i.date,
  'updatedAt': i.updatedAt,
};

Map<String, dynamic> _habitJson(Habit h) => {
  'id': h.id,
  'name': h.name,
  'color': h.color,
  'time': h.time,
  'reminder': h.reminder,
  'records': {
    for (final e in h.records.entries) e.key: e.value.name,
  },
};

Map<String, dynamic> _milestoneJson(Milestone m) => {
  'id': m.id,
  'title': m.title,
  'date': m.date,
  'yearly': m.yearly,
  'pinned': m.pinned,
  'lunar': m.lunar,
};

PlanTask? _findTask(AppStore store, String id) =>
    store.data.tasks.where((t) => t.id == id).firstOrNull;

/// 全部工具。调用方按权限过滤。
List<McpTool> allTools() => [
  McpTool(
    name: 'zhiji_app_info',
    description: '应用版本、平台、登录与情侣绑定状态、上次同步时间',
    inputSchema: _schema(const {}),
    run: (store, sync, args) async => {
      'app': '之计',
      'platform': Platform.isWindows ? 'Windows' : 'Android',
      'loggedIn': sync.loggedIn,
      'bound': sync.isBound,
      'partner': sync.isBound ? sync.partnerName : '',
      'lastSyncAt': sync.lastSyncAt,
      'pendingTasks': store.memoTasks().where((t) => !t.done).length,
    },
  ),
  McpTool(
    name: 'zhiji_plan_list',
    description:
        '列出计划。可按日期或区间筛选；includeMemos=true 时带上没有日期的备忘录',
    inputSchema: _schema({
      'date': _str('单日 YYYY-MM-DD'),
      'from': _str('区间开始 YYYY-MM-DD'),
      'to': _str('区间结束 YYYY-MM-DD'),
      'includeMemos': _bool('是否包含没有日期的备忘录，默认 false'),
      'includeDone': _bool('是否包含已完成的，默认 true'),
      'includeArchived': _bool('是否包含已归档的，默认 false'),
    }),
    run: (store, sync, args) async {
      final date = _s(args['date']);
      final from = _s(args['from']);
      final to = _s(args['to']);
      final withMemos = args['includeMemos'] == true;
      final withDone = args['includeDone'] != false;
      final withArchived = args['includeArchived'] == true;

      final rows = <Map<String, dynamic>>[];
      for (final t in store.data.tasks) {
        if (!withArchived && t.archived) continue;
        if (!withDone && t.done) continue;
        var match = false;
        if (date.isNotEmpty && t.hasDate && t.date == date) match = true;
        if (from.isNotEmpty &&
            to.isNotEmpty &&
            t.hasDate &&
            t.date.compareTo(from) >= 0 &&
            t.date.compareTo(to) <= 0) {
          match = true;
        }
        if (!t.hasDate && !t.isRecurring && withMemos) match = true;
        if (date.isEmpty && from.isEmpty && to.isEmpty) match = true;
        if (match) rows.add(taskJson(t));
      }
      rows.sort((a, b) {
        final ad = (a['date'] as String).isEmpty ? 1 : 0;
        final bd = (b['date'] as String).isEmpty ? 1 : 0;
        if (ad != bd) return ad - bd; // 有日期的在前，备忘录在后
        final c = (a['date'] as String).compareTo(b['date'] as String);
        if (c != 0) return c;
        return (a['title'] as String).compareTo(b['title'] as String);
      });
      return {'count': rows.length, 'tasks': rows};
    },
  ),
  McpTool(
    name: 'zhiji_plan_get',
    description: '按 id 取一条计划的详情',
    inputSchema: _schema({'id': _str('计划 id')}, ['id']),
    run: (store, sync, args) async {
      final t = _findTask(store, _s(args['id']));
      if (t == null) throw McpToolException('没有这条计划');
      return taskJson(t);
    },
  ),
  McpTool(
    name: 'zhiji_plan_stats',
    description: '指定日期的完成情况，以及本周完成数',
    inputSchema: _schema({'date': _str('YYYY-MM-DD，默认今天')}),
    run: (store, sync, args) async {
      final day = _s(args['date']).isEmpty ? today() : _parseDate(_s(args['date']));
      final key = dateKey(day);
      final onDay = store.tasksOn(key);
      final done = onDay.where((t) => t.isDoneOn(day)).length;
      final weekStart = day.subtract(Duration(days: day.weekday - 1));
      final stat = store.weekStat(weekStart);
      return {
        'date': key,
        'dayTotal': onDay.length,
        'dayDone': done,
        'memoTotal': store.memoTasks().length,
        'memoDone': store.memoTasks().where((t) => t.done).length,
        'weekStart': dateKey(weekStart),
        'weekDone': stat.$1,
        'weekTotal': stat.$2,
      };
    },
  ),
  McpTool(
    name: 'zhiji_list_list',
    description: '列出全部清单（不含条目）',
    inputSchema: _schema(const {}),
    run: (store, sync, args) async => {
      'count': store.data.lists.length,
      'lists': store.data.lists.map(_listJson).toList(),
    },
  ),
  McpTool(
    name: 'zhiji_list_get',
    description: '按 id 取清单及其条目',
    inputSchema: _schema({'id': _str('清单 id')}, ['id']),
    run: (store, sync, args) async {
      final id = _s(args['id']);
      final l = store.data.lists.where((x) => x.id == id).firstOrNull;
      if (l == null) throw McpToolException('没有这个清单');
      return {
        ..._listJson(l),
        'items': l.items.map(_itemJson).toList(),
      };
    },
  ),
  McpTool(
    name: 'zhiji_habit_list',
    description: '列出习惯与打卡记录',
    inputSchema: _schema({'days': _int('只回最近 N 天的记录，默认 30')}),
    run: (store, sync, args) async {
      final days = (args['days'] is int) ? args['days'] as int : 30;
      final from = dateKey(today().subtract(Duration(days: days)));
      return {
        'count': store.data.habits.length,
        'habits': store.data.habits.map((h) {
          final json = _habitJson(h);
          final records = json['records'] as Map<String, dynamic>;
          records.removeWhere((k, v) => k.compareTo(from) < 0);
          return json;
        }).toList(),
      };
    },
  ),
  McpTool(
    name: 'zhiji_habit_history',
    description: '单个习惯在指定区间的打卡记录',
    inputSchema: _schema({
      'habitId': _str('习惯 id'),
      'from': _str('YYYY-MM-DD'),
      'to': _str('YYYY-MM-DD'),
    }, ['habitId']),
    run: (store, sync, args) async {
      final h = store.habitById(_s(args['habitId']));
      if (h == null) throw McpToolException('没有这个习惯');
      final from = _s(args['from']);
      final to = _s(args['to']);
      final rows = h.records.entries
          .where((e) => from.isEmpty || e.key.compareTo(from) >= 0)
          .where((e) => to.isEmpty || e.key.compareTo(to) <= 0)
          .map((e) => {'date': e.key, 'status': e.value.name})
          .toList()
        ..sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
      return {'habit': h.name, 'records': rows};
    },
  ),
  McpTool(
    name: 'zhiji_countdown_list',
    description: '倒数本条目与剩余天数',
    inputSchema: _schema(const {}),
    run: (store, sync, args) async {
      final now = today();
      return {
        'count': store.data.milestones.length,
        'items': store.data.milestones.map((m) {
          final d = _parseDate(m.date);
          return {..._milestoneJson(m), 'daysLeft': d.difference(now).inDays};
        }).toList(),
      };
    },
  ),
  McpTool(
    name: 'zhiji_journal_list',
    description: '日记条目列表（日期、标题、心情）；需要开启隐私读取',
    inputSchema: _schema({'limit': _int('最多返回多少条，默认 30')}),
    needsPrivate: true,
    run: (store, sync, args) async {
      final limit = (args['limit'] is int) ? args['limit'] as int : 30;
      final entries = store.data.journal.values.toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      return {
        'count': entries.length,
        'entries': entries.take(limit).map((e) => {
          'date': e.date,
          'id': e.id,
          'title': e.title,
          'mood': e.mood?.name ?? '',
          'weather': e.weather,
        }).toList(),
      };
    },
  ),
  McpTool(
    name: 'zhiji_journal_get',
    description: '按日期读一篇日记全文；需要开启隐私读取',
    inputSchema: _schema({'date': _str('YYYY-MM-DD')}, ['date']),
    needsPrivate: true,
    run: (store, sync, args) async {
      final key = _s(args['date']);
      final entry = store.data.journal[key];
      if (entry == null) throw McpToolException('这一天没有日记');
      return {
        'date': entry.date,
        'title': entry.title,
        'text': entry.text,
        'mood': entry.mood?.name ?? '',
        'weather': entry.weather,
        'shared': entry.shared,
        'images': entry.images.length,
      };
    },
  ),
  McpTool(
    name: 'zhiji_couple_messages',
    description: '留言板最近消息；需要开启隐私读取',
    inputSchema: _schema({'limit': _int('最多返回多少条，默认 20')}),
    needsPrivate: true,
    run: (store, sync, args) async {
      final limit = (args['limit'] is int) ? args['limit'] as int : 20;
      final rows = sync.messages.take(limit).map((m) => {
        'id': m.id,
        'kind': m.kind,
        'text': m.text,
        'createdAt': m.createdAt,
      }).toList();
      return {'count': rows.length, 'messages': rows};
    },
  ),

  // ---------- 写入（需要「允许写入」） ----------
  McpTool(
    name: 'zhiji_plan_create',
    description: '新建一条计划。date 留空即备忘录，会一直留在计划页',
    inputSchema: _schema({
      'title': _str('标题'),
      'date': _str('YYYY-MM-DD，留空=备忘录'),
      'start': _str('开始时间 HH:mm'),
      'end': _str('结束时间 HH:mm'),
      'note': _str('备注'),
      'remindBefore': _int('提前多少分钟提醒'),
    }, ['title']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final title = _s(args['title']).trim();
      if (title.isEmpty) throw McpToolException('标题不能为空');
      final t = store.addTask(
        title: title,
        date: _s(args['date']),
        start: _s(args['start']),
        end: _s(args['end']),
        remindBefore:
            (args['remindBefore'] is int) ? args['remindBefore'] as int : 0,
      );
      final note = _s(args['note']);
      if (note.isNotEmpty) store.updateTask(t.id, note: note);
      return taskJson(t);
    },
  ),
  McpTool(
    name: 'zhiji_plan_update',
    description: '修改一条计划的标题、日期、时间或备注',
    inputSchema: _schema({
      'id': _str('计划 id'),
      'title': _str('新标题'),
      'date': _str('新日期，传空串就变成备忘录'),
      'start': _str('开始时间 HH:mm'),
      'end': _str('结束时间 HH:mm'),
      'note': _str('备注'),
      'starred': _bool('是否星标'),
    }, ['id']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final id = _s(args['id']);
      if (_findTask(store, id) == null) throw McpToolException('没有这条计划');
      store.updateTask(
        id,
        title: args.containsKey('title') ? _s(args['title']) : null,
        date: args.containsKey('date') ? _s(args['date']) : null,
        start: args.containsKey('start') ? _s(args['start']) : null,
        end: args.containsKey('end') ? _s(args['end']) : null,
        note: args.containsKey('note') ? _s(args['note']) : null,
        starred: args['starred'] is bool ? args['starred'] as bool : null,
      );
      return taskJson(_findTask(store, id)!);
    },
  ),
  McpTool(
    name: 'zhiji_plan_complete',
    description: '把计划标记为完成或未完成',
    inputSchema: _schema({
      'id': _str('计划 id'),
      'done': _bool('true=完成，默认 true'),
      'date': _str('重复任务算哪一天，默认今天'),
    }, ['id']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final t = _findTask(store, _s(args['id']));
      if (t == null) throw McpToolException('没有这条计划');
      final day =
          _s(args['date']).isEmpty ? today() : _parseDate(_s(args['date']));
      store.setTaskDoneOn(t, day, args['done'] != false);
      return taskJson(t);
    },
  ),
  McpTool(
    name: 'zhiji_plan_archive',
    description: '归档或取消归档一条计划',
    inputSchema: _schema({
      'id': _str('计划 id'),
      'archived': _bool('true=归档，默认 true'),
    }, ['id']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final t = _findTask(store, _s(args['id']));
      if (t == null) throw McpToolException('没有这条计划');
      store.archiveTask(t.id, args['archived'] != false);
      return taskJson(t);
    },
  ),
  McpTool(
    name: 'zhiji_list_create',
    description: '新建一个清单',
    inputSchema: _schema({
      'name': _str('清单名'),
      'color': _str('颜色十六进制，如 4C8C6A'),
    }, ['name']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final name = _s(args['name']).trim();
      if (name.isEmpty) throw McpToolException('清单名不能为空');
      final l = store.addList(
        name,
        _s(args['color']).isEmpty ? '4C8C6A' : _s(args['color']),
      );
      if (l == null) throw McpToolException('已经有同名清单');
      return _listJson(l);
    },
  ),
  McpTool(
    name: 'zhiji_list_add_item',
    description: '往清单里加一条',
    inputSchema: _schema({
      'listId': _str('清单 id'),
      'title': _str('条目内容'),
    }, ['listId', 'title']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final listId = _s(args['listId']);
      final title = _s(args['title']).trim();
      if (title.isEmpty) throw McpToolException('条目不能为空');
      final l = store.data.lists.where((x) => x.id == listId).firstOrNull;
      if (l == null) throw McpToolException('没有这个清单');
      store.addListItem(listId, title);
      return _itemJson(l.items.last);
    },
  ),
  McpTool(
    name: 'zhiji_list_check_item',
    description: '勾选或取消勾选清单里的一条',
    inputSchema: _schema({
      'listId': _str('清单 id'),
      'itemId': _str('条目 id'),
      'done': _bool('true=勾选，默认 true'),
    }, ['listId', 'itemId']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final listId = _s(args['listId']);
      final itemId = _s(args['itemId']);
      final l = store.data.lists.where((x) => x.id == listId).firstOrNull;
      if (l == null) throw McpToolException('没有这个清单');
      final item = l.items.where((x) => x.id == itemId).firstOrNull;
      if (item == null) throw McpToolException('没有这个条目');
      store.setListItemDone(listId, itemId, args['done'] != false);
      return _itemJson(item);
    },
  ),
  McpTool(
    name: 'zhiji_habit_check',
    description: '给习惯打卡或取消打卡',
    inputSchema: _schema({
      'habitId': _str('习惯 id'),
      'date': _str('YYYY-MM-DD，默认今天'),
      'done': _bool('true=打卡，默认 true'),
    }, ['habitId']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final h = store.habitById(_s(args['habitId']));
      if (h == null) throw McpToolException('没有这个习惯');
      final key = _s(args['date']).isEmpty ? dateKey(today()) : _s(args['date']);
      store.setHabitRecord(
        h.id,
        key,
        args['done'] != false ? HabitStatus.done : null,
      );
      return {'id': h.id, 'date': key, 'done': args['done'] != false};
    },
  ),
  McpTool(
    name: 'zhiji_countdown_create',
    description: '新建一条倒数日',
    inputSchema: _schema({
      'title': _str('名称'),
      'date': _str('目标日期 YYYY-MM-DD'),
      'yearly': _bool('是否每年重复'),
    }, ['title', 'date']),
    readOnly: false,
    needsWrite: true,
    run: (store, sync, args) async {
      final title = _s(args['title']).trim();
      final date = _s(args['date']);
      if (title.isEmpty || date.isEmpty) throw McpToolException('名称和日期都要填');
      final m = store.addMilestone(
        title: title,
        date: date,
        yearly: args['yearly'] == true,
      );
      return _milestoneJson(m);
    },
  ),
];

/// 工具执行失败时抛这个，服务端转成 isError 的工具结果。
class McpToolException implements Exception {
  McpToolException(this.message);

  final String message;

  @override
  String toString() => message;
}

DateTime _parseDate(String s) {
  final parts = s.split('-');
  if (parts.length != 3) return today();
  return DateTime(
    int.tryParse(parts[0]) ?? 1970,
    int.tryParse(parts[1]) ?? 1,
    int.tryParse(parts[2]) ?? 1,
  );
}
