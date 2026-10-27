import 'package:flutter/material.dart';

import '../widgets/responsive.dart';

import 'package:provider/provider.dart';

import '../sync/api.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import '../widgets/m3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 设置入口：显示已登录设备数，点开进入设备管理页。
class DevicesTile extends StatefulWidget {
  const DevicesTile({super.key});

  @override
  State<DevicesTile> createState() => _DevicesTileState();
}

class _DevicesTileState extends State<DevicesTile> {
  String? _accountId;
  bool _wasLoggedIn = false;
  int? _count;
  bool _loading = false;
  bool _loaded = false;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sync = context.watch<SyncService>();
    if (sync.accountId != _accountId) {
      // 换账号或退出后重新登录：计数不能沿用上一个账号。
      _accountId = sync.accountId;
      _count = null;
      _loaded = false;
      _failed = false;
    }
    if (sync.loggedIn != _wasLoggedIn) {
      _wasLoggedIn = sync.loggedIn;
      if (sync.loggedIn) {
        _count = null;
        _loaded = false;
        _failed = false;
      }
    }
    if (sync.loggedIn && !_loaded && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loaded && !_loading) _load();
      });
    }
  }

  Future<void> _load() async {
    final sync = context.read<SyncService>();
    if (!sync.loggedIn) return;
    final token = sync.token;
    if (token == null || token.isEmpty) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final list = await SyncApi.listDevices(token: token, device: sync.deviceId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loaded = true;
      _count = list?.length;
      _failed = list == null;
    });
  }

  Future<void> _open() async {
    m3HapticSelect();
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const DevicesPage()));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    if (!sync.loggedIn) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final trailing = (!_loaded || _loading) && _count == null
        ? '…'
        : _failed
        ? '—'
        : '${_count ?? 0} 台';
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.devices_rounded,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      title: const Text('登录的设备', style: TextStyle(fontSize: 14)),
      subtitle: const Text('查看并移除同账号的其它设备', style: TextStyle(fontSize: 11)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            trailing,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
      onTap: _open,
    );
  }
}

/// 已登录设备管理：列出同账号设备，可移除其它设备（当前设备不可移除）。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<Map<String, dynamic>>? _devices;
  bool _loading = true;
  bool _failed = false;
  bool _renaming = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    final sync = context.read<SyncService>();
    final token = sync.token;
    if (!sync.loggedIn || token == null || token.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _error = '请先登录账号';
      });
      return;
    }
    setState(() {
      if (!silent) _loading = true;
      _failed = false;
      _error = null;
    });
    final list = await SyncApi.listDevices(token: token, device: sync.deviceId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (list == null) {
        // 静默刷新失败时保留已显示的列表，不整页变成错误页。
        if (!silent) {
          _failed = true;
          _error = '加载失败，请检查网络后重试';
        }
      } else {
        _failed = false;
        _error = null;
        _devices = list;
      }
    });
  }

  String _label(Map<String, dynamic> d) {
    final name = (d['name'] as String?)?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final id = (d['device'] as String?) ?? '';
    if (id.isEmpty) return '未知设备';
    return id.length > 8 ? id.substring(0, 8) : id;
  }

  String _ago(Object? raw) {
    final ms = raw is num ? raw.toInt() : 0;
    if (ms <= 0) return '时间未知';
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return '${diff ~/ 60000} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ 3600000} 小时前';
    return '${diff ~/ 86400000} 天前';
  }

  Future<void> _drop(Map<String, dynamic> d) async {
    if (d['current'] == true) {
      // 当前设备移除会把自己踢下线，这里直接拦住。
      showTopToast('当前设备不能移除，请先退出登录');
      return;
    }
    final label = _label(d);
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('移除「$label」？'),
        content: const Text('移除后需重新登录才能同步'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: errorFilledButtonStyle(Theme.of(context)),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final sync = context.read<SyncService>();
    final token = sync.token;
    final id = (d['device'] as String?) ?? '';
    if (token == null || id.isEmpty) return;
    final ok = await SyncApi.dropDevice(token: token, device: id);
    if (!mounted) return;
    if (!ok) {
      showTopToast('移除失败，请稍后再试');
      return;
    }
    // 保守起见先本地移除该行，再静默刷新一次，避免整页闪成 loading。
    final index = _devices?.indexWhere((x) => x['device'] == id) ?? -1;
    if (index >= 0) setState(() => _devices!.removeAt(index));
    await _load(silent: true);
  }

  Future<void> _rename(Map<String, dynamic> d) async {
    if (_renaming) return;
    final id = (d['device'] as String?) ?? '';
    if (id.isEmpty) return;
    final currentName = (d['name'] as String?) ?? '';
    final name = await showM3Dialog<String>(
      context: context,
      builder: (_) => _RenameDeviceDialog(initial: currentName),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    if (trimmed == currentName.trim()) return;
    final sync = context.read<SyncService>();
    final token = sync.token;
    if (token == null || token.isEmpty) return;
    setState(() => _renaming = true);
    final ok = await SyncApi.renameDevice(
      token: token,
      device: id,
      name: trimmed,
    );
    if (!mounted) return;
    setState(() => _renaming = false);
    if (!ok) {
      showTopToast('改名失败，请稍后再试');
      return;
    }
    final index = _devices?.indexWhere((x) => x['device'] == id) ?? -1;
    if (index >= 0) {
      final updated = Map<String, dynamic>.from(_devices![index])
        ..['name'] = trimmed;
      setState(() => _devices![index] = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('登录的设备')),
      body: ResponsiveContent(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cloud_off_rounded,
                        size: 44,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _error ?? '加载失败，请检查网络后重试',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            : (_devices == null || _devices!.isEmpty)
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.devices_other_rounded,
                        size: 44,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '还没有登录的设备记录',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '在另一台设备登录同一账号后，这里会显示它',
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
            : RefreshIndicator(
                onRefresh: () => _load(silent: true),
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _devices!.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, index) {
                    final d = _devices![index];
                    final current = d['current'] == true;
                    return ListTile(
                      leading: Icon(
                        current
                            ? Icons.phone_android_rounded
                            : Icons.devices_rounded,
                        size: 22,
                        color: current
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              _label(d),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          if (current) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '这台',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(width: 4),
                          Icon(
                            Icons.edit_rounded,
                            size: 14,
                            color: scheme.outline,
                          ),
                        ],
                      ),
                      subtitle: Text(
                        _ago(d['updatedAt']),
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: _renaming ? null : () => _rename(d),
                      trailing: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: current
                              ? scheme.onSurfaceVariant
                              : scheme.error,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => _drop(d),
                        child: const Text('移除'),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

/// 改名弹窗：上限 40 字，空名不允许保存。
class _RenameDeviceDialog extends StatefulWidget {
  const _RenameDeviceDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  bool get _canSave => _ctrl.text.trim().isNotEmpty;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设备名称'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 40,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _canSave ? _submit() : null,
        decoration: const InputDecoration(
          hintText: '给这台设备起个名字',
          counterText: '',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSave ? _submit : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
