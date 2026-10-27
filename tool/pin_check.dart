// ignore_for_file: avoid_print
// 严格证书锁定连通性自检：与 lib/sync/api.dart 相同的
// 空 SecurityContext + badCertificateCallback 指纹比对机制。
// 用法: dart run tool/pin_check.dart <host> <port> <appKey> <certSha256>
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  final host = args[0];
  final port = args[1];
  final appKey = args[2];
  final fp = args[3];
  final client = HttpClient(context: SecurityContext())
    ..connectionTimeout = const Duration(seconds: 10)
    ..badCertificateCallback = (cert, h, p) {
      final digest = sha256.convert(cert.der).toString();
      print('peer fp: $digest');
      return digest == fp;
    };
  try {
    final req = await client.postUrl(Uri.parse('https://$host:$port/api'));
    req.headers.contentType = ContentType.json;
    final body = utf8.encode(jsonEncode({
      'appKey': appKey,
      'action': 'checkUpdate',
      'version': '1.0.0',
    }));
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    print('status: ${res.statusCode}');
    print(await res.transform(utf8.decoder).join());
  } finally {
    client.close();
  }
}
