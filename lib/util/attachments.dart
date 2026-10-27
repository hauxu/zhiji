import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 附件落盘：把用户挑选的文件复制进应用文档目录，返回新路径。
/// 图片/文档统一按 `docs/subdir/时间戳_原文件名` 存放。
Future<String?> copyIntoAppDir(String sourcePath, String subdir) async {
  try {
    final src = File(sourcePath);
    if (!src.existsSync()) return null;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}$subdir');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final name = sourcePath.split(Platform.pathSeparator).last.split('/').last;
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final dest = '${dir.path}${Platform.pathSeparator}${stamp}_$name';
    await src.copy(dest);
    return dest;
  } catch (_) {
    return null;
  }
}

/// 删除应用文档目录 docs/subdir/ 下的附件文件；路径越界或失败时静默跳过。
Future<void> deleteAttachQuietly(String? path, String subdir) async {
  if (path == null || path.isEmpty) return;
  try {
    final docs = await getApplicationDocumentsDirectory();
    final prefix = '${docs.path}${Platform.pathSeparator}$subdir';
    if (!path.startsWith(prefix)) return;
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}
