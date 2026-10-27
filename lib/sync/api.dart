import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'config.dart';

class SyncException implements Exception {
  SyncException(this.message, {this.transient = false});
  final String message;

  /// 网络类失败：可退避重试，客户端按瞬时故障处理。
  final bool transient;

  @override
  String toString() => message;
}

class SyncApi {
  SyncApi._();

  // 空 SecurityContext（无任何系统根证书）使所有证书链都进入
  // badCertificateCallback，指纹比对成为唯一放行条件；
  // 否则持受信 CA 证书的中间人可绕过锁定。
  static final HttpClient _client = HttpClient(context: SecurityContext())
    ..connectionTimeout = const Duration(seconds: 10)
    ..badCertificateCallback = (cert, host, port) => pinMatch(cert);

  /// POST {action, ...payload}，返回 result；带证书指纹锁定。
  /// [timeoutOverride] 供长轮询等慢请求放宽超时。
  static Future<dynamic> post(
    String action,
    Map<String, dynamic> payload, {
    Duration? timeoutOverride,
  }) async {
    final body = jsonEncode({
      'appKey': SyncConfig.appKey,
      'action': action,
      ...payload,
    });
    if (!SyncConfig.isConfigured) {
      throw SyncException('尚未配置同步服务器');
    }
    try {
      final host = SyncConfig.effectiveHost;
      // 连接前校验 host：仅允许配置的固定服务器，拒绝本地/私有/保留地址。
      final normalized = host.trim().toLowerCase();
      final forbidden =
          normalized.isEmpty ||
          normalized == 'localhost' ||
          normalized.endsWith('.localhost') ||
          normalized.startsWith('127.') ||
          normalized.startsWith('10.') ||
          normalized.startsWith('192.168.') ||
          RegExp(r'^169\.254\.').hasMatch(normalized) ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(normalized) ||
          normalized == '::1' ||
          normalized.startsWith('fc') ||
          normalized.startsWith('fd') ||
          normalized.startsWith('fe80');
      if (forbidden && !SyncConfig.allowLocal) {
        throw SyncException('服务器地址不可用');
      }
      final reqTimeout = timeoutOverride ?? const Duration(seconds: 12);
      final req = await _client
          .postUrl(Uri.parse('https://$host:${SyncConfig.port}/api'))
          .timeout(reqTimeout);
      req.headers.contentType = ContentType.json;
      final bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(reqTimeout);
      // 响应上限：一次 full sync 会带回本机槽 + 对方槽 + 最多 7 个其它设备槽，
      // 再加上房间里的留言与评价，重数据账号能到十几 MB。这里放宽到 48MB，
      // 只兜住明显异常的响应；真正的大小治理交给服务端裁剪。
      if (res.contentLength > 48 * 1024 * 1024) {
        throw SyncException('服务返回异常', transient: false);
      }
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(reqTimeout + const Duration(seconds: 8));
      if (res.statusCode != 200) {
        // 服务端业务错误信息透传给用户。
        String fallback = '服务暂时不可用（${res.statusCode}）';
        var transient = res.statusCode >= 500;
        if (text.isNotEmpty && text.length < 300) {
          try {
            final decoded = jsonDecode(text);
            if (decoded is Map &&
                decoded['error'] is String &&
                (decoded['error'] as String).isNotEmpty) {
              fallback = decoded['error'] as String;
              transient = false;
            }
          } catch (_) {}
        }
        throw SyncException(fallback, transient: transient);
      }
      final Object decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw SyncException('服务返回异常');
      }
      if (decoded is! Map<String, dynamic>) {
        throw SyncException('服务返回异常', transient: true);
      }
      if (decoded['ok'] == true) return decoded['result'];
      final err = decoded['error'];
      throw SyncException(err is String ? err : '请求失败');
    } on TimeoutException {
      throw SyncException('连接超时', transient: true);
    } on SocketException {
      throw SyncException('网络不可用', transient: true);
    } on HandshakeException {
      throw SyncException('安全连接失败', transient: true);
    } on HttpException {
      throw SyncException('连接被中断', transient: true);
    }
  }

  /// 已登录设备列表。失败（网络/服务端契约不符）统一返回 null，
  /// 不把异常抛给 UI。
  static Future<List<Map<String, dynamic>>?> listDevices({
    required String token,
    required String device,
  }) async {
    try {
      final result = await post('listDevices', {
        'token': token,
        'device': device,
      });
      if (result is! Map) return null;
      final raw = result['devices'];
      if (raw is! List) return null;
      return [
        for (final e in raw)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    } catch (_) {
      return null;
    }
  }

  /// 移除一台登录设备；失败（网络/设备不存在）返回 false。
  static Future<bool> dropDevice({
    required String token,
    required String device,
  }) async {
    try {
      await post('dropDevice', {'token': token, 'device': device});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 给设备改名；失败（网络/服务端 400）返回 false。
  static Future<bool> renameDevice({
    required String token,
    required String device,
    required String name,
  }) async {
    try {
      await post('renameDevice', {
        'token': token,
        'device': device,
        'name': name,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 仅凭错误文案判定是否网络类失败（lastError 只存了字符串）。
  static bool isTransientMessage(String m) {
    if (m.startsWith('服务暂时不可用')) return true;
    const t = {'网络不可用', '连接超时', '安全连接失败', '连接被中断', '服务返回异常'};
    return t.contains(m);
  }

  /// 校验证书 SHA-256 指纹（自签名 HTTPS）。
  static bool pinMatch(X509Certificate cert) {
    final digest = sha256.convert(cert.der).toString();
    return digest == SyncConfig.certSha256;
  }
}
