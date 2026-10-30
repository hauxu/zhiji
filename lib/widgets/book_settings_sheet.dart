import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'm3_dialog.dart';
import '../theme.dart';
import '../ui_prefs.dart';
import '../sync/sync_service.dart';

/// 倒数本设置面板：显示与排序偏好，仅本机生效。
/// [couple] 为 true 时读写情侣倒数本的独立设置（与日子页互不影响）。
Future<void> showBookSettingsSheet(
  BuildContext context, {
  bool couple = false,
  String currentName = '',
}) {
  return showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _BookSettingsSheet(couple: couple, currentName: currentName),
  );
}

class _BookSettingsSheet extends StatelessWidget {
  const _BookSettingsSheet({required this.couple, required this.currentName});

  final bool couple;
  final String currentName;

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<UiPrefs>();
    final lunar = couple ? prefs.cbookLunar : prefs.bookLunar;
    final pastDays = couple ? prefs.cbookPastDays : prefs.bookPastDays;
    final hidePartner = couple ? prefs.cbookHidePartner : prefs.bookHidePartner;
    final collapsed = couple
        ? prefs.cbookCollapsedCount
        : prefs.bookCollapsedCount;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text(
              '倒数本设置',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          SwitchListTile(
            title: const Text('显示农历标注', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '条目日期旁显示农历名，如 农历八月十五',
              style: TextStyle(fontSize: 11),
            ),
            value: lunar,
            onChanged: (v) {
              m3HapticSelect();
              couple
                  ? context.read<UiPrefs>().setCBookLunar(v)
                  : context.read<UiPrefs>().setBookLunar(v);
            },
          ),
          SwitchListTile(
            title: const Text('显示已过天数', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '已过条目显示「已过 N 天」',
              style: TextStyle(fontSize: 11),
            ),
            value: pastDays,
            onChanged: (v) {
              m3HapticSelect();
              couple
                  ? context.read<UiPrefs>().setCBookPastDays(v)
                  : context.read<UiPrefs>().setBookPastDays(v);
            },
          ),
          SwitchListTile(
            title: const Text('隐藏 TA 的条目', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '只显示我自己添加的倒数日',
              style: TextStyle(fontSize: 11),
            ),
            value: hidePartner,
            onChanged: (v) {
              m3HapticSelect();
              couple
                  ? context.read<UiPrefs>().setCBookHidePartner(v)
                  : context.read<UiPrefs>().setBookHidePartner(v);
            },
          ),
          ListTile(
            title: const Text('外显条数', style: TextStyle(fontSize: 14)),
            subtitle: Slider(
              value: collapsed.toDouble(),
              min: 1,
              max: 20,
              divisions: 19,
              label: '$collapsed 条',
              onChanged: (v) {
                couple
                    ? context.read<UiPrefs>().setCBookCollapsedCount(v.round())
                    : context.read<UiPrefs>().setBookCollapsedCount(v.round());
              },
            ),
          ),
          if (couple)
            ListTile(
              title: const Text('倒数本名称', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                currentName.isEmpty ? '倒数本' : currentName,
                style: const TextStyle(fontSize: 11),
              ),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () async {
                final name = await showM3Dialog<String>(
                  context: context,
                  builder: (ctx) => _RenameDialog(initial: currentName),
                );
                if (name != null && name.isNotEmpty && context.mounted) {
                  await context.read<SyncService>().setCoupleBookName(name);
                }
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 倒数本重命名对话框：controller 由自身 State 持有，
/// 随路由卸载释放（外层 dispose 会在退出动画前触发 debug 断言）。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial.isEmpty ? '倒数本' : widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('倒数本名称'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 20,
        decoration: const InputDecoration(hintText: '如：我们的日子'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
