/// MCP 调用日志：只在内存里留最近 100 条，设置页可看可清空。
class McpCall {
  McpCall({
    required this.at,
    required this.tool,
    required this.ok,
    this.note = '',
  });

  final DateTime at;
  final String tool;
  final bool ok;
  final String note;
}

class McpAudit {
  McpAudit._();

  static const int _cap = 100;
  static final List<McpCall> _log = <McpCall>[];

  static void add(String tool, {bool ok = true, String note = ''}) {
    _log.insert(
      0,
      McpCall(at: DateTime.now(), tool: tool, ok: ok, note: note),
    );
    if (_log.length > _cap) _log.removeRange(_cap, _log.length);
  }

  static List<McpCall> snapshot() => List<McpCall>.unmodifiable(_log);

  static void clear() => _log.clear();
}
