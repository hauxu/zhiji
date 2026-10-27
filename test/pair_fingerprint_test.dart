import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

/// 配对指纹的算法：双方公钥排序后哈希，两台设备必须算出同一个值，
/// 顺序（谁先生成绑定码）不能影响结果。
String fingerprint(String a, String b) {
  final pair = [a, b]..sort();
  final d = sha256.convert(utf8.encode('zhiji-pair:${pair.join('|')}')).bytes;
  final hex = d
      .take(4)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return '${hex.substring(0, 4)}-${hex.substring(4)}';
}

void main() {
  const pubA = 'BpxZ1uJc0e+eWq1k3rGmSJb0m0A9j0VQ0nFk5m8wO2E=';
  const pubB = 'ObU7MCichpJ6iVC6BdNC+kL4cQ2wZ0mS8k1nJ3pQ5rA=';

  test('两台设备算出的指纹一致', () {
    expect(fingerprint(pubA, pubB), fingerprint(pubB, pubA));
  });

  test('格式是 XXXX-XXXX', () {
    expect(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}$')
        .hasMatch(fingerprint(pubA, pubB)), isTrue);
  });

  test('公钥变了指纹就变', () {
    const other = 'FkdHVGFx+YcU8Tj6Am/4dQ+t5rZ1qL0m8nJ2kP4sX6c=';
    expect(fingerprint(pubA, pubB) == fingerprint(pubA, other), isFalse);
  });
}