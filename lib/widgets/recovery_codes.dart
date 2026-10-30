import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../sync/sync_service.dart';
import 'm3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 恢复码全宽展示：纵行列出 16 组，支持复制与下载为 txt。
Future<void> showRecoveryCodesSheet(
  BuildContext context,
  List<String> codes,
) async {
  final scheme = Theme.of(context).colorScheme;
  await showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '备份恢复码',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '恢复码是找回云端备份的唯一方式，'
              '换机后在解锁框按顺序输入。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < codes.length; i++)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 30,
                              child: Text(
                                '${i + 1}'.padLeft(2, '0'),
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                codes[i],
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 18,
                                  letterSpacing: 2,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: codes.join(' ')),
                      );
                      showTopToast('已复制');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('复制'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                    onPressed: () => _downloadCodes(context, codes),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('下载'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('完成'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _downloadCodes(BuildContext context, List<String> codes) async {
  File? file;
  try {
    final dir = await getTemporaryDirectory();
    file = File('${dir.path}/judging_recovery_codes.txt');
    final buf = StringBuffer()
      ..writeln('之计 · 备份恢复码（共 ${codes.length} 组，请妥善保管）')
      ..writeln();
    for (var i = 0; i < codes.length; i++) {
      buf.writeln('${i + 1}. ${codes[i]}');
    }
    await file.writeAsString(buf.toString(), flush: true);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/plain')],
      subject: '之计 · 备份恢复码',
      text: '之计 · 备份恢复码',
    );
  } catch (e) {
    showTopToast('下载失败：$e');
  } finally {
    // 恢复码等于备份主钥匙，分享完立即删掉临时文件，别留在 %TEMP%。
    try {
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }
}

Future<void> showRecoverySetupFlow(BuildContext context) async {
  final sync = context.read<SyncService>();
  final scheme = Theme.of(context).colorScheme;
  final has = sync.hasRecoveryCodes;

  final action = await showM3Dialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('生成并保存恢复码'),
      content: Text(
        has
            ? '恢复码只在生成时显示一次，App 不保存明文；'
                  '没保存可点「重新生成」（旧码失效）。'
            : '开启备份加密需要一个 16 组的数字恢复码：\n\n'
                  '· 备份内容以 AES-256-GCM 加密，密钥由恢复码派生，不经过服务器\n'
                  '· 恢复码是换机或卸载后找回云端备份的唯一方式\n'
                  '· 生成后请立即下载保存',
        style: const TextStyle(fontSize: 13, height: 1.5),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(has ? '稍后' : '跳过'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop('go'),
          child: Text(has ? '重新生成' : '生成恢复码'),
        ),
      ],
    ),
  );
  if (action == null || action.isEmpty) return;

  if (has) {
    if (!context.mounted) return;
    final ok = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新生成恢复码？'),
        content: const Text(
          '旧恢复码立即失效；本机保留上一把密钥用于迁移，'
          '其它设备需用新恢复码解锁',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重新生成'),
          ),
        ],
      ),
    );
    if (ok != true) return;
  }
  if (!context.mounted) return;

  // 生成：PBKDF2 派生 + 旧数据迁移推送，可能需要数秒。
  if (!context.mounted) return;
  final rootNavigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator(color: scheme.primary)),
    ),
  );
  List<String>? codes;
  Object? error;
  try {
    codes = await sync.generateRecoveryCodes();
  } catch (e) {
    error = e;
  } finally {
    // 进度框必须关掉，否则界面卡在不可返回的弹窗上。
    if (rootNavigator.mounted && rootNavigator.canPop()) {
      rootNavigator.pop();
    }
  }
  if (!context.mounted) return;
  if (codes == null) {
    showTopToast('生成失败：$error');
    return;
  }
  await showRecoveryCodesSheet(context, codes);
}
