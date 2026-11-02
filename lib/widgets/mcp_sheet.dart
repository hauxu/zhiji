import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../mcp/mcp_audit.dart';
import '../mcp/mcp_server.dart';
import '../mcp/mcp_settings.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import 'm3_dialog.dart';
import 'top_toast.dart';

Future<void> showMcpSheet(BuildContext context) => showM3Sheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => const _McpSheet(),
);

class _McpSheet extends StatefulWidget {
  const _McpSheet();

  @override
  State<_McpSheet> createState() => _McpSheetState();
}

class _McpSheetState extends State<_McpSheet> {
  bool _loading = true;
  bool _enabled = false;
  bool _allowWrite = false;
  bool _allowPrivate = false;
  int _port = McpSettings.defaultPort;
  String _token = '';
  String? _error;
  final _portCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await McpSettings.enabled();
    final write = await McpSettings.allowWrite();
    final private = await McpSettings.allowPrivate();
    final port = await McpSettings.port();
    final token = await McpSettings.token();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _allowWrite = write;
      _allowPrivate = private;
      _port = port;
      _token = token;
      _portCtrl.text = '$port';
      _error = McpServer.instance.running
          ? null
          : (enabled ? '服务没有在监听，检查端口是否被占用' : null);
      _loading = false;
    });
  }

  Future<void> _apply() async {
    final store = context.read<AppStore>();
    final sync = context.read<SyncService>();
    final info = await PackageInfo.fromPlatform();
    final err = await McpServer.instance.syncWith(store, sync, info.version);
    if (!mounted) return;
    setState(() => _error = err);
    if (err == null) {
      final msg = _enabled
          ? '已开启，地址 127.0.0.1:${_portCtrl.text}'
          : '已关闭';
      showTopToast(msg);
    }
  }

  Future<void> _toggle(bool v) async {
    m3HapticSelect();
    setState(() => _enabled = v);
    await McpSettings.setEnabled(v);
    await _apply();
  }

  Future<void> _savePort() async {
    final v = int.tryParse(_portCtrl.text.trim());
    if (v == null || v < 1024 || v > 65535) {
      setState(() => _error = '端口要填 1024 到 65535 之间的整数');
      return;
    }
    await McpSettings.setPort(v);
    setState(() {
      _port = v;
      _error = null;
    });
    await _apply();
  }

  Future<void> _copyToken() async {
    await Clipboard.setData(ClipboardData(text: _token));
    if (!mounted) return;
    showTopToast('Token 已复制');
  }

  Future<void> _resetToken() async {
    final fresh = await McpSettings.resetToken();
    if (!mounted) return;
    setState(() => _token = fresh);
    showTopToast('已换新 Token，旧的立刻失效');
  }

  String get _configSnippet {
    final url = 'http://127.0.0.1:$_port/mcp';
    return '{\n'
        '  "mcpServers": {\n'
        '    "zhiji": {\n'
        '      "type": "http",\n'
        '      "url": "$url",\n'
        '      "headers": {"Authorization": "Bearer $_token"}\n'
        '    }\n'
        '  }\n'
        '}';
  }

  Future<void> _copyConfig() async {
    await Clipboard.setData(ClipboardData(text: _configSnippet));
    if (!mounted) return;
    showTopToast('配置已复制，粘到智能体的 MCP 设置里');
  }

  String get _maskedToken {
    if (_token.length <= 8) return _token;
    return '${_token.substring(0, 4)}••••${_token.substring(_token.length - 4)}';
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const SafeArea(
        child: SizedBox(
          height: 260,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final logs = McpAudit.snapshot();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '智能体接入',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  McpServer.instance.running ? '运行中' : '未开启',
                  style: TextStyle(
                    fontSize: 12,
                    color: McpServer.instance.running
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Text(
              '让本机的智能体读写之计。只监听 127.0.0.1，Token 泄露等于把数据交出去。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('启用 MCP 服务', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '地址 http://127.0.0.1:$_port/mcp',
              style: const TextStyle(fontSize: 11),
            ),
            value: _enabled,
            onChanged: _toggle,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 11, color: scheme.error),
              ),
            ),
          ListTile(
            dense: true,
            title: const Text('端口', style: TextStyle(fontSize: 14)),
            trailing: SizedBox(
              width: 110,
              child: TextField(
                controller: _portCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _savePort(),
              ),
            ),
            onTap: () {},
          ),
          ListTile(
            dense: true,
            title: const Text('Token', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              _maskedToken,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '复制',
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: _copyToken,
                ),
                IconButton(
                  tooltip: '重置',
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  onPressed: _resetToken,
                ),
              ],
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('允许写入', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '智能体可以新建、修改、完成计划与清单',
              style: TextStyle(fontSize: 11),
            ),
            value: _allowWrite,
            onChanged: (v) async {
              m3HapticSelect();
              setState(() => _allowWrite = v);
              await McpSettings.setAllowWrite(v);
            },
          ),
          SwitchListTile(
            dense: true,
            title: const Text('允许读取日记与留言', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '默认关闭，打开后智能体能读到日记正文和留言',
              style: TextStyle(fontSize: 11),
            ),
            value: _allowPrivate,
            onChanged: (v) async {
              m3HapticSelect();
              setState(() => _allowPrivate = v);
              await McpSettings.setAllowPrivate(v);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _copyConfig,
                    icon: const Icon(Icons.content_copy_rounded, size: 18),
                    label: const Text('复制 MCP 配置'),
                  ),
                ),
              ],
            ),
          ),
          if (!Platform.isWindows)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '手机端只对本机生效，桌面智能体请在 Windows 上连接。',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          if (logs.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '最近调用',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      McpAudit.clear();
                      setState(() {});
                    },
                    child: const Text('清空', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: logs.length,
                itemBuilder: (_, i) {
                  final l = logs[i];
                  final t = l.at;
                  final hh = t.hour.toString().padLeft(2, '0');
                  final mm = t.minute.toString().padLeft(2, '0');
                  final ss = t.second.toString().padLeft(2, '0');
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: Icon(
                      l.ok ? Icons.check_circle_rounded : Icons.error_outline,
                      size: 16,
                      color: l.ok ? scheme.primary : scheme.error,
                    ),
                    title: Text(l.tool, style: const TextStyle(fontSize: 12)),
                    subtitle: l.note.isEmpty
                        ? null
                        : Text(
                            l.note,
                            style: const TextStyle(fontSize: 11),
                          ),
                    trailing: Text(
                      '$hh:$mm:$ss',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
