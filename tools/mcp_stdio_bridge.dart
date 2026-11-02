// 之计 MCP 的 stdio 桥：给只支持 stdio 的客户端用（如 Claude Desktop）。
// 用法：
//   dart run tools/mcp_stdio_bridge.dart --url http://127.0.0.1:8787/mcp --token <TOKEN>
// 也支持环境变量 ZHIZI_MCP_URL / ZHIZI_MCP_TOKEN。
//
// 逐行读 stdin 的 JSON-RPC，POST 给应用内的 MCP 服务，把返回写到 stdout。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> argv) async {
  var url = Platform.environment['ZHIZI_MCP_URL'] ?? 'http://127.0.0.1:8787/mcp';
  var token = Platform.environment['ZHIZI_MCP_TOKEN'] ?? '';
  for (var i = 0; i < argv.length - 1; i++) {
    if (argv[i] == '--url') url = argv[i + 1];
    if (argv[i] == '--token') token = argv[i + 1];
  }
  if (token.isEmpty) {
    stderr.writeln('缺少 token：--token <TOKEN> 或 ZHIZI_MCP_TOKEN');
    exitCode = 2;
    return;
  }

  final client = HttpClient();
  final queue = StreamController<String>();

  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        final body = line.trim();
        if (body.isEmpty) return;
        queue.add(body);
      }, onDone: () {
        queue.close();
      });

  await for (final body in queue.stream) {
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.headers.set('Authorization', 'Bearer $token');
      req.write(body);
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      if (text.trim().isEmpty) continue; // 通知类消息没有响应
      stdout.writeln(text.trim());
    } catch (e) {
      stderr.writeln('转发失败：$e');
    }
  }
  client.close(force: true);
}
