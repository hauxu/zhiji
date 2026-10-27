import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'config.dart';

/// 应用更新：检查新版本 + 断点续传下载安装包到应用私有 updates/ 目录。
/// 已下载完整的包会被复用；校验失败的包立即删除。
class Updater {
  Updater._();

  // 与 SyncApi 相同的严格指纹锁定。
  static final HttpClient _client = HttpClient(context: SecurityContext())
    ..connectionTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = (cert, host, port) => SyncApi.pinMatch(cert);

  /// 置为 true 可中止进行中的下载（.part 文件保留供下次续传）。
  static bool cancelRequested = false;

  /// 检查更新。返回 null＝检查失败；update=false＝已是最新。
  static Future<Map<String, dynamic>?> check(String currentVersion) async {
    if (!SyncConfig.isConfigured) return null;
    final result = await SyncApi.post('checkUpdate', {
      'version': currentVersion,
      'platform': Platform.operatingSystem, // windows 走便携 zip 通道
    });
    if (result is Map) return Map<String, dynamic>.from(result);
    return null;
  }

  static Future<Directory> updatesDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}updates');
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    return dir;
  }

  static String _safeNameOf(String file) {
    final safeName = file.split(Platform.pathSeparator).last.split('/').last;
    // 与服务端白名单一致；拒绝 ..zip 这类会把解包目录指向上级的名字。
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(safeName) ||
        safeName.contains('..') ||
        !(safeName.endsWith('.apk') || safeName.endsWith('.zip'))) {
      throw SyncException('更新包名称异常');
    }
    return safeName;
  }

  static Future<String> _sha256Of(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

  /// 本地已有完整且校验通过的包时直接复用（避免重复下载大文件）。
  static Future<String?> findVerifiedPackage(
      String file, String expectedSha256) async {
    if (expectedSha256.isEmpty) return null;
    try {
      final safeName = _safeNameOf(file);
      final path =
          '${(await updatesDir()).path}${Platform.pathSeparator}$safeName';
      final f = File(path);
      if (!f.existsSync()) return null;
      return await _sha256Of(path) == expectedSha256 ? path : null;
    } on SyncException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 删除 updates/ 里除 [keepName] 与 .part 之外的旧版本包。
  static Future<void> cleanup({String? keepName}) async {
    try {
      final dir = await updatesDir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name == keepName || name.endsWith('.part')) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 断点续传下载到 updates 目录下的 `*.part`，完成后原子改名并校验 sha256。
  /// 服务端不支持 Range（回 200）时自动从头写。
  static Future<String> download(
    String file,
    void Function(int received, int total) onProgress, {
    String? expectedSha256,
  }) async {
    final safeName = _safeNameOf(file);
    final dir = await updatesDir();
    final finalPath = '${dir.path}${Platform.pathSeparator}$safeName';
    final partPath = '$finalPath.part';
    final part = File(partPath);
    var resumeFrom = 0;
    if (part.existsSync()) {
      resumeFrom = part.lengthSync();
    }
    final req = await _client
        .getUrl(Uri.parse(
            'https://${SyncConfig.effectiveHost}:${SyncConfig.port}/apk/$safeName'))
        .timeout(const Duration(seconds: 20));
    if (resumeFrom > 0) {
      req.headers.set('Range', 'bytes=$resumeFrom-');
    }
    final res = await req.close().timeout(const Duration(minutes: 10));
    if (resumeFrom > 0 && res.statusCode == 206) {
      // 续传：保留 .part 继续追加。
    } else if (res.statusCode == 200) {
      // 服务端忽略 Range 或包已变化：从头写。
      resumeFrom = 0;
    } else {
      throw SyncException('下载失败（${res.statusCode}）');
    }
    final total = res.contentLength > 0
        ? res.contentLength + resumeFrom
        : -1;
    IOSink? sink;
    var received = resumeFrom;
    var cancelled = false;
    try {
      sink = part.openWrite(mode: FileMode.append);
      // 任意 30 秒没有新数据即视为连接停滞，避免弱网下无限挂起。
      await for (final chunk in res.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        sink.add(chunk);
        onProgress(received, total > 0 ? total : received);
        if (cancelRequested) {
          cancelled = true;
          break;
        }
      }
      if (!cancelled) await sink.flush();
    } on TimeoutException {
      throw SyncException('下载超时，网络停滞（进度已保存，可继续续传）');
    } on SyncException {
      rethrow;
    } catch (e) {
      throw SyncException('下载中断：$e');
    } finally {
      await sink?.close();
      try {
        await res.listen(null).cancel();
      } catch (_) {}
    }
    if (cancelled) {
      throw SyncException('下载已取消（进度已保存）');
    }
    if (total > 0 && received != total) {
      throw SyncException('下载不完整（进度已保存，可继续续传）');
    }
    // 服务端自 v5.7.0 起恒返回 sha256；缺失时拒绝安装而非跳过校验。
    if (expectedSha256 == null || expectedSha256.isEmpty) {
      throw SyncException('更新包缺少校验信息，已放弃安装');
    }
    final digest = await _sha256Of(partPath);
    if (digest != expectedSha256) {
      // 校验失败立即删包（.part 与成品都删），不给安装流程机会。
      try { part.deleteSync(); } catch (_) {}
      try { File(finalPath).deleteSync(); } catch (_) {}
      throw SyncException('更新包校验失败，已放弃安装');
    }
    final target = File(finalPath);
    if (target.existsSync()) {
      try { target.deleteSync(); } catch (_) {}
    }
    await part.rename(finalPath);
    return finalPath;
  }
}
