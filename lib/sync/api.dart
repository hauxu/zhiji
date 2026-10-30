import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'config.dart';

enum SyncErrorKind { auth, network, parameter, server, other }

class SyncException implements Exception {
  SyncException(this.message, {this.transient = false, this.kind = SyncErrorKind.other});
  final String message;

  /// 网络类失败：可退避重试，客户端按瞬时故障处理。
  final bool transient;

  /// 失败大类，供设备管理等调用方区分登录失效/网络/参数/服务端异常。
  final SyncErrorKind kind;

  @override
  String toString() => message;
}

class SyncApi {
  SyncApi._();

  /// 最近一次设备操作的错误；页面可在返回 null/false 后读取。
  static SyncException? lastError;

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
      throw SyncException('尚未配置同步服务器', kind: SyncErrorKind.parameter);
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
        throw SyncException('服务器地址不可用',
            kind: SyncErrorKind.parameter);
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
        throw SyncException('服务返回异常',
            transient: false, kind: SyncErrorKind.server);
      }
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(reqTimeout + const Duration(seconds: 8));
      if (res.statusCode != 200) {
        // 服务端业务错误信息透传给用户。
        String fallback = '服务暂时不可用（${res.statusCode}）';
        var transient = res.statusCode >= 500;
        var kind = res.statusCode >= 500
            ? SyncErrorKind.server
            : res.statusCode == 401 || res.statusCode == 403
                ? SyncErrorKind.auth
                : SyncErrorKind.parameter;
        if (text.isNotEmpty && text.length < 300) {
          try {
            final decoded = jsonDecode(text);
            if (decoded is Map &&
                decoded['error'] is String &&
                (decoded['error'] as String).isNotEmpty) {
              fallback = decoded['error'] as String;
              transient = false;
              if (fallback.contains('登录已失效') ||
                  fallback.contains('登录已过期')) {
                kind = SyncErrorKind.auth;
              }
            }
          } catch (_) {}
        }
        throw SyncException(fallback, transient: transient, kind: kind);
      }
      final Object decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw SyncException('服务返回异常', kind: SyncErrorKind.server);
      }
      if (decoded is! Map<String, dynamic>) {
        throw SyncException('服务返回异常',
            transient: true, kind: SyncErrorKind.server);
      }
      if (decoded['ok'] == true) return decoded['result'];
      final err = decoded['error'];
      final message = err is String ? err : '请求失败';
      throw SyncException(message,
          kind: message.contains('登录已失效') || message.contains('登录已过期')
              ? SyncErrorKind.auth
              : SyncErrorKind.parameter);
    } on TimeoutException {
      throw SyncException('连接超时',
          transient: true, kind: SyncErrorKind.network);
    } on SocketException {
      throw SyncException('网络不可用',
          transient: true, kind: SyncErrorKind.network);
    } on HandshakeException {
      throw SyncException('安全连接失败',
          transient: true, kind: SyncErrorKind.network);
    } on HttpException {
      throw SyncException('连接被中断',
          transient: true, kind: SyncErrorKind.network);
    }
  }

  /// 已登录设备列表。失败返回 null，同时通过 [SyncApi.lastError] 或
  /// [onError] 暴露错误大类（登录失效/网络/参数/服务端）。
  static Future<List<Map<String, dynamic>>?> listDevices({
    required String token,
    required String device,
    void Function(SyncException error)? onError,
  }) async {
    lastError = null;
    if (token.isEmpty) {
      _reportDeviceError('listDevices',
          SyncException('登录已失效，请重新登录', kind: SyncErrorKind.auth), onError);
      return null;
    }
    try {
      final result = await post('listDevices', {
        'token': token,
        'device': device,
      });
      if (result is! Map) {
        throw SyncException('设备列表格式异常', kind: SyncErrorKind.server);
      }
      final raw = result['devices'];
      if (raw is! List) {
        throw SyncException('设备列表格式异常', kind: SyncErrorKind.server);
      }
      return [
        for (final e in raw)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    } on SyncException catch (e) {
      _reportDeviceError('listDevices', e, onError);
      return null;
    } catch (e) {
      _reportDeviceError('listDevices',
          SyncException('设备列表加载失败：$e', transient: true,
              kind: SyncErrorKind.network), onError);
      return null;
    }
  }

  /// 移除一台登录设备；失败返回 false，同时暴露错误大类。
  static Future<bool> dropDevice({
    required String token,
    required String device,
    void Function(SyncException error)? onError,
  }) async {
    lastError = null;
    if (token.isEmpty) {
      _reportDeviceError('dropDevice',
          SyncException('登录已失效，请重新登录', kind: SyncErrorKind.auth), onError);
      return false;
    }
    try {
      await post('dropDevice', {'token': token, 'device': device});
      return true;
    } on SyncException catch (e) {
      _reportDeviceError('dropDevice', e, onError);
      return false;
    } catch (e) {
      _reportDeviceError('dropDevice',
          SyncException('移除设备失败：$e', transient: true,
              kind: SyncErrorKind.network), onError);
      return false;
    }
  }

  /// 给设备改名；失败返回 false，同时暴露错误大类。
  static Future<bool> renameDevice({
    required String token,
    required String device,
    required String name,
    void Function(SyncException error)? onError,
  }) async {
    lastError = null;
    if (token.isEmpty) {
      _reportDeviceError('renameDevice',
          SyncException('登录已失效，请重新登录', kind: SyncErrorKind.auth), onError);
      return false;
    }
    try {
      await post('renameDevice', {
        'token': token,
        'device': device,
        'name': name,
      });
      return true;
    } on SyncException catch (e) {
      _reportDeviceError('renameDevice', e, onError);
      return false;
    } catch (e) {
      _reportDeviceError('renameDevice',
          SyncException('设备改名失败：$e', transient: true,
              kind: SyncErrorKind.network), onError);
      return false;
    }
  }

  static void _reportDeviceError(String op, SyncException error,
      void Function(SyncException error)? onError) {
    lastError = error;
    debugPrint('SyncApi.$op failed[${error.kind.name}]: ${error.message}');
    onError?.call(error);
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
    return _constantTimeEquals(digest, SyncConfig.certSha256);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
