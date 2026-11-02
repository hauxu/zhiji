import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/store.dart';
import '../sync/sync_service.dart';
import 'mcp_audit.dart';
import 'mcp_protocol.dart';
import 'mcp_settings.dart';
import 'mcp_tools.dart';

/// 应用内 MCP 服务：只监听 127.0.0.1，Bearer token 鉴权。
/// 传输走 MCP 的 Streamable HTTP（无状态，不主动推送）。
class McpServer {
  McpServer._();

  static final McpServer instance = McpServer._();

  static const String protocolVersion = '2025-06-18';
  static const String serverName = 'zhiji';

  HttpServer? _server;
  int? _port;
  String _version = '';
  AppStore? _store;
  SyncService? _sync;

  bool get running => _server != null;
  int? get port => _port;

  /// 按当前设置启动或停止。返回错误文案，成功返回 null。
  Future<String?> syncWith(AppStore store, SyncService sync, String version) async {
    _store = store;
    _sync = sync;
    _version = version;
    final enabled = await McpSettings.enabled();
    final wanted = await McpSettings.port();
    if (!enabled) {
      await stop();
      return null;
    }
    if (_server != null && _port == wanted) return null;
    await stop();
    return start(wanted);
  }

  /// 强制在指定端口启动，失败时返回可读原因。port=0 由系统分配。
  Future<String?> start(
    int port, {
    AppStore? store,
    SyncService? sync,
    String? version,
  }) async {
    if (store != null) _store = store;
    if (sync != null) _sync = sync;
    if (version != null) _version = version;
    await stop();
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      server.autoCompress = false;
      _server = server;
      _port = server.port;
      server.listen(_handle, onError: (Object e) {
        McpAudit.add('server', ok: false, note: '$e');
      });
      McpAudit.add('server', note: 'listen 127.0.0.1:${server.port}');
      return null;
    } on SocketException catch (e) {
      _server = null;
      _port = null;
      return '端口 $port 无法监听：${e.osError?.message ?? e.message}';
    } catch (e) {
      _server = null;
      _port = null;
      return '启动失败：$e';
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    if (s != null) {
      await s.close(force: true);
    }
  }

  int _windowSecond = 0;
  int _windowCount = 0;

  /// 每秒最多 60 次，防止本机脚本狂刷。
  bool _rateOk() {
    final now = DateTime.now().second;
    if (now != _windowSecond) {
      _windowSecond = now;
      _windowCount = 0;
    }
    _windowCount++;
    return _windowCount <= 60;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Cache-Control', 'no-store');
    try {
      if (req.uri.path == '/healthz') {
        res.statusCode = HttpStatus.ok;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': true, 'version': _version}));
        await res.close();
        return;
      }
      if (req.uri.path != '/mcp') {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      if (req.method == 'GET' || req.method == 'DELETE') {
        // 无状态服务，不提供服务端推送流。
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.set('Allow', 'POST');
        await res.close();
        return;
      }
      if (req.method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.set('Allow', 'POST');
        await res.close();
        return;
      }
      if (!await _authorized(req)) {
        res.statusCode = HttpStatus.unauthorized;
        res.headers.set('WWW-Authenticate', 'Bearer');
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(rpcError(null, kInvalidRequest, 'token 不正确')));
        await res.close();
        return;
      }
      if (!_rateOk()) {
        res.statusCode = HttpStatus.tooManyRequests;
        await res.close();
        return;
      }

      final raw = await utf8.decoder.bind(req).join();
      Map<String, dynamic> msg;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('只接受单个 JSON-RPC 对象');
        }
        msg = decoded;
      } catch (e) {
        res.statusCode = HttpStatus.badRequest;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(rpcError(null, kParseError, '请求不是合法 JSON')));
        await res.close();
        return;
      }

      final out = await _dispatch(msg);
      if (out == null) {
        // 通知类消息没有响应体。
        res.statusCode = HttpStatus.accepted;
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(out));
      await res.close();
    } catch (e) {
      McpAudit.add('http', ok: false, note: '$e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(rpcError(null, kInternalError, '服务端出错')));
        await res.close();
      } catch (_) {}
    }
  }

  Future<bool> _authorized(HttpRequest req) async {
    final token = await McpSettings.token();
    final header = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final given = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : (req.headers.value('X-Zhiji-Token') ?? '');
    return _constantTimeEquals(given, token);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<Map<String, dynamic>?> _dispatch(Map<String, dynamic> msg) async {
    final id = msg['id'];
    final method = msg['method'];
    final isNotification = !msg.containsKey('id');
    if (msg['jsonrpc'] != '2.0' || method is! String) {
      return isNotification
          ? null
          : rpcError(id, kInvalidRequest, '不是合法的 JSON-RPC 2.0 请求');
    }

    switch (method) {
      case 'initialize':
        return rpcResult(id, {
          'protocolVersion': protocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': serverName, 'version': _version},
          'instructions':
              '之计的计划、清单、习惯、日记与留言。默认只读，'
              '写入和日记/留言读取要在应用「我的 → 智能体接入」里开启。',
        });
      case 'notifications/initialized':
      case 'notifications/cancelled':
        return null;
      case 'ping':
        return rpcResult(id, const {});
      case 'tools/list':
        return rpcResult(id, await _listTools());
      case 'tools/call':
        return rpcResult(id, await _callTool(msg['params']));
      default:
        return isNotification
            ? null
            : rpcError(id, kMethodNotFound, '不支持的方法 $method');
    }
  }

  Future<Map<String, dynamic>> _listTools() async {
    final allowWrite = await McpSettings.allowWrite();
    final allowPrivate = await McpSettings.allowPrivate();
    final tools = allTools().where((t) {
      if (t.needsPrivate && !allowPrivate) return false;
      if (t.needsWrite && !allowWrite) return false;
      return true;
    });
    return {'tools': tools.map((t) => t.toJson()).toList()};
  }

  Future<Map<String, dynamic>> _callTool(Object? params) async {
    if (params is! Map) {
      return toolError('参数必须是对象');
    }
    final name = params['name'];
    if (name is! String || name.isEmpty) {
      return toolError('缺少工具名');
    }
    final argsRaw = params['arguments'];
    final args = argsRaw is Map
        ? argsRaw.map((k, v) => MapEntry('$k', v))
        : <String, dynamic>{};

    final tool = allTools().where((t) => t.name == name).firstOrNull;
    if (tool == null) {
      McpAudit.add(name, ok: false, note: '未知工具');
      return toolError('没有这个工具：$name');
    }
    if (tool.needsPrivate && !await McpSettings.allowPrivate()) {
      McpAudit.add(name, ok: false, note: '隐私未授权');
      return toolError('要读取日记或留言，请先在应用里打开「允许读取日记与留言」');
    }
    if (tool.needsWrite && !await McpSettings.allowWrite()) {
      McpAudit.add(name, ok: false, note: '写入未授权');
      return toolError('要修改数据，请先在应用里打开「允许写入」');
    }
    final store = _store;
    final sync = _sync;
    if (store == null || sync == null) {
      return toolError('应用数据还没就绪');
    }

    try {
      final data = await tool.run(store, sync, args);
      McpAudit.add(name, note: 'ok');
      return toolText(data);
    } on McpToolException catch (e) {
      McpAudit.add(name, ok: false, note: e.message);
      return toolError(e.message);
    } catch (e) {
      McpAudit.add(name, ok: false, note: '$e');
      return toolError('执行失败：$e');
    }
  }
}
