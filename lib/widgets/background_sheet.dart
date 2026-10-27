import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../theme.dart';
import '../ui_prefs.dart';
import 'm3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 全局自定义背景设置弹层：相册选图 + 透明度滑条 + 恢复默认。
Future<void> showBackgroundSheet(BuildContext context) async {
  await showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _BackgroundSheet(),
  );
}

class _BackgroundSheet extends StatefulWidget {
  const _BackgroundSheet();

  @override
  State<_BackgroundSheet> createState() => _BackgroundSheetState();
}

class _BackgroundSheetState extends State<_BackgroundSheet> {
  bool _busy = false;

  /// 选图后拷贝到应用私有目录（相册缓存可能被系统回收）。
  Future<void> _pick() async {
    if (_busy) return;
    m3HapticSelect();
    setState(() => _busy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2160,
      );
      if (picked == null) return;
      if (!mounted) return;
      final ui = context.read<UiPrefs>();
      final dir = await getApplicationDocumentsDirectory();
      final savePath =
          '${dir.path}/bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(picked.path).copy(savePath);
      final old = ui.bgPath;
      await ui.setBgPath(savePath);
      await ui.setBgEnabled(true);
      // 旧背景图只删本地拷贝文件，不影响已生效的新图。
      if (old.isNotEmpty && old != savePath) {
        try {
          File(old).deleteSync();
        } catch (_) {}
      }
    } catch (_) {
      if (mounted) {
        showTopToast('背景选择失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    m3HapticSelect();
    final ui = context.read<UiPrefs>();
    await ui.setBgEnabled(false);
    final old = ui.bgPath;
    await ui.setBgPath('');
    if (old.isNotEmpty) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = context.watch<UiPrefs>();
    final scheme = Theme.of(context).colorScheme;
    final hasBg = ui.bgPath.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '自定义背景',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Switch(
                  value: ui.bgEnabled && hasBg,
                  onChanged: hasBg
                      ? (v) {
                          m3HapticSelect();
                          context.read<UiPrefs>().setBgEnabled(v);
                        }
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              hasBg ? '背景图铺满全局' : '从相册选择背景图',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _pick,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('从相册选择背景图'),
              ),
            ),
            if (hasBg) ...[
              const SizedBox(height: 12),
              Text(
                '图片透明度 ${((1 - ui.bgOpacity) * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 13),
              ),
              Slider(
                // 滑条值 = 图片透明度；存储仍为不透明度（1-值），零迁移。
                value: (1 - ui.bgOpacity).clamp(0.0, 1.0),
                min: 0,
                max: 1,
                divisions: 20,
                label: '${((1 - ui.bgOpacity) * 100).toStringAsFixed(0)}%',
                onChanged: (v) => context.read<UiPrefs>().setBgOpacity(1 - v),
              ),
              Text(
                '0% 完整显示，100% 露出底色',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _clear,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('恢复默认背景'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
