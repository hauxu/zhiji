import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/sync/sync_service.dart';

/// 共享密钥 id：两边各自算出同一把密钥时，id 必须一致，
/// 否则「按对方的 id 对齐密钥」那套逻辑就失效了。
void main() {
  test('同一把密钥算出的 id 稳定', () {
    const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
    expect(SyncService.coupleKid(key), SyncService.coupleKid(key));
    expect(SyncService.coupleKid(key).length, 12);
  });

  test('不同密钥的 id 不同', () {
    const a = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
    const b = 'Hh8eHRwbGhkYFxYVFBMSERAPDg0MCwoJCAcGBQQDAgE=';
    expect(SyncService.coupleKid(a) == SyncService.coupleKid(b), isFalse);
  });

  test('id 只含十六进制字符', () {
    final kid = SyncService.coupleKid('任意字符串都能算');
    expect(RegExp(r'^[0-9a-f]{12}$').hasMatch(kid), isTrue);
  });
}