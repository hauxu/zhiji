import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/crypto/journal_crypto.dart';

/// 长期身份密钥：给 X25519 公钥签名，再用对方身份公钥验签。
/// 这是「服务端替换对方公钥」的最后一道防线。
void main() {
  test('签名能被对方公钥验过', () async {
    final (privA, pubA) = await JournalCrypto.generateIdentityKeyPair();
    final data = utf8.encode('x25519-pub-key-bytes');
    final sig = await JournalCrypto.signWithIdentity(privA, data);
    expect(await JournalCrypto.verifyIdentity(pubA, data, sig), isTrue);
  });

  test('数据被改过验签失败', () async {
    final (privA, pubA) = await JournalCrypto.generateIdentityKeyPair();
    final sig =
        await JournalCrypto.signWithIdentity(privA, utf8.encode('orig'));
    expect(await JournalCrypto.verifyIdentity(pubA, utf8.encode('evil'), sig),
        isFalse);
  });

  test('换成别人的公钥验签失败', () async {
    final (privA, _) = await JournalCrypto.generateIdentityKeyPair();
    final (_, pubB) = await JournalCrypto.generateIdentityKeyPair();
    final data = utf8.encode('payload');
    final sig = await JournalCrypto.signWithIdentity(privA, data);
    expect(await JournalCrypto.verifyIdentity(pubB, data, sig), isFalse);
  });

  test('公钥能从私钥推出来（换机恢复用）', () async {
    final (priv, pub) = await JournalCrypto.generateIdentityKeyPair();
    expect(await JournalCrypto.identityPublicFromPrivate(priv), pub);
  });

  test('安全码两端一致且换人就会变', () {
    final a = base64Encode(List.filled(32, 1));
    final b = base64Encode(List.filled(32, 2));
    final c = base64Encode(List.filled(32, 3));
    expect(JournalCrypto.safetyNumber(a, b),
        JournalCrypto.safetyNumber(b, a));
    expect(JournalCrypto.safetyNumber(a, b) ==
        JournalCrypto.safetyNumber(a, c), isFalse);
    expect(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$')
        .hasMatch(JournalCrypto.safetyNumber(a, b)), isTrue);
  });
}