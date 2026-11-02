import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/data/store.dart';
import 'package:goalday/mcp/mcp_server.dart';
import 'package:goalday/mcp/mcp_settings.dart';
import 'package:goalday/sync/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

late AppStore store;
late SyncService sync;
late int port;

Future<HttpClientResponse> call(
  Map<String, dynamic> body, {
  String? token,
  String path = '/mcp',
}) async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
  req.headers.contentType = ContentType.json;
  if (token != null) req.headers.set('Authorization', 'Bearer $token');
  req.write(jsonEncode(body));
  final res = await req.close();
  return res;
}

Future<Map<String, dynamic>> rpc(
  String method, {
  Map<String, dynamic>? params,
  String? token,
}) async {
  final res = await call({
    'jsonrpc': '2.0',
    'id': 1,
    'method': method,
    'params': ?params,
  }, token: token);
  final text = await utf8.decoder.bind(res).join();
  return jsonDecode(text) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> callTool(
  String name, {
  Map<String, dynamic> args = const {},
}) async {
  final token = await McpSettings.token();
  final r = await rpc(
    'tools/call',
    params: {'name': name, 'arguments': args},
    token: token,
  );
  return r['result'] as Map<String, dynamic>;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore();
    store.replaceData(
      AppData(
        lists: <TaskList>[],
        tasks: <PlanTask>[
          PlanTask(id: 'memo1', title: '买牛奶'),
          PlanTask(id: 'dated1', title: '开会', date: '2026-11-03'),
        ],
        habits: <Habit>[
          Habit(id: 'h1', name: '早起', color: '4C8C6A', records: {}),
        ],
        journal: <String, JournalEntry>{
          '2026-11-02': JournalEntry(date: '2026-11-02', text: '今天很安静'),
        },
      ),
    );
    sync = SyncService(store);
    await McpSettings.setEnabled(true);
    await McpServer.instance.start(0, store: store, sync: sync, version: 'test');
    port = McpServer.instance.port!;
  });

  tearDownAll(() async {
    await McpServer.instance.stop();
  });

  test('没有 token 返回 401', () async {
    final res = await call({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'ping',
    });
    expect(res.statusCode, 401);
  });

  test('initialize 返回协议版本与工具能力', () async {
    final token = await McpSettings.token();
    final r = await rpc('initialize', token: token);
    final result = r['result'] as Map<String, dynamic>;
    expect(result['protocolVersion'], McpServer.protocolVersion);
    expect((result['capabilities'] as Map)['tools'], isNotNull);
    expect((result['serverInfo'] as Map)['name'], 'zhiji');
  });

  test('默认看不到写入工具，开了写入才出现', () async {
    final token = await McpSettings.token();
    var r = await rpc('tools/list', token: token);
    var names = ((r['result'] as Map)['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(names, contains('zhiji_plan_list'));
    expect(names, isNot(contains('zhiji_plan_create')));
    expect(names, isNot(contains('zhiji_journal_list')));

    await McpSettings.setAllowWrite(true);
    await McpSettings.setAllowPrivate(true);
    r = await rpc('tools/list', token: token);
    names = ((r['result'] as Map)['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(names, contains('zhiji_plan_create'));
    expect(names, contains('zhiji_journal_list'));
    await McpSettings.setAllowWrite(false);
    await McpSettings.setAllowPrivate(false);
  });

  test('读计划：备忘录在有日期之后', () async {
    final r = await callTool(
      'zhiji_plan_list',
      args: {'includeMemos': true},
    );
    if (r['isError'] == true) {
      // ignore: avoid_print
      // ignore: avoid_print
      print('ERR: ${((r['content'] as List).first as Map)['text']}');
    }
    expect(r['isError'], false);
    final data = jsonDecode(((r['content'] as List).first as Map)['text'] as String);
    final tasks = (data['tasks'] as List).cast<Map>();
    expect(tasks.first['id'], 'dated1');
    expect(tasks.last['id'], 'memo1');
  });

  test('隐私未授权时读日记被拒', () async {
    final r = await callTool('zhiji_journal_list');
    expect(r['isError'], true);
    expect(((r['content'] as List).first as Map)['text'], contains('允许读取'));
  });

  test('写入未授权时新建计划被拒', () async {
    final r = await callTool(
      'zhiji_plan_create',
      args: {'title': '不该成功'},
    );
    expect(r['isError'], true);
    expect(((r['content'] as List).first as Map)['text'], contains('允许写入'));
  });

  test('开启写入后能新建备忘录并读到', () async {
    await McpSettings.setAllowWrite(true);
    final r = await callTool('zhiji_plan_create', args: {'title': '写周报'});
    expect(r['isError'], false);
    final created =
        jsonDecode(((r['content'] as List).first as Map)['text'] as String)
            as Map<String, dynamic>;
    expect(created['title'], '写周报');
    expect(created['memo'], true);

    final list = await callTool(
      'zhiji_plan_list',
      args: {'includeMemos': true},
    );
    final data = jsonDecode(((list['content'] as List).first as Map)['text'] as String);
    final titles = (data['tasks'] as List).map((t) => t['title']).toList();
    expect(titles, contains('写周报'));
    await McpSettings.setAllowWrite(false);
  });

  test('未知工具返回 isError', () async {
    final r = await callTool('zhiji_nope');
    expect(r['isError'], true);
  });

  test('未知方法返回 -32601', () async {
    final token = await McpSettings.token();
    final r = await rpc('tools/nope', token: token);
    expect((r['error'] as Map)['code'], -32601);
  });

  test('healthz 不需要 token', () async {
    final client = HttpClient();
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/healthz'),
    );
    final res = await req.close();
    expect(res.statusCode, 200);
    client.close();
  });
}
