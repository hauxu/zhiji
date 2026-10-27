import 'dart:io';

import 'package:open_filex/open_filex.dart';

/// 用系统默认方式打开文件/文件夹。
/// Windows 走 explorer，其余平台走 OpenFilex。
Future<void> openExternally(String path) async {
  if (Platform.isWindows) {
    try {
      await Process.run('explorer.exe', [path]);
      return;
    } catch (_) {
      return;
    }
  }
  await OpenFilex.open(path);
}
