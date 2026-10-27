import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/crypto/journal_crypto.dart';

// 自愈链路的关键前提：本机能生成 X25519 密钥对、并能用双方私钥/公钥
// 协商出同一把共享密钥。绑定态缺共享密钥时客户端就是靠这两步恢复的。
void main() {
  test('两端各自生成密钥对后能协商出同一把共享密钥', () async {
    final (privA, pubA) = await JournalCrypto.generateCoupleKeyPair();
    final (privB, pubB) = await JournalCrypto.generateCoupleKeyPair();
    expect(pubA, isNotEmpty);
    expect(pubB, isNotEmpty);
    expect(privA, isNot(equals(pubA)));

    const ids = ['acct-a-0001', 'acct-b-0002'];
    final keyAB =
        await JournalCrypto.deriveCoupleKeyX25519(privA, pubB, ids);
    final keyBA =
        await JournalCrypto.deriveCoupleKeyX25519(privB, pubA, ids);
    expect(keyAB, keyBA, reason: '双方协商结果必须一致');
    expect(keyAB, isNotEmpty);
  });

  test('用协商出的共享密钥加密的共享包，对方能解开', () async {
    final (privA, pubA) = await JournalCrypto.generateCoupleKeyPair();
    final (privB, pubB) = await JournalCrypto.generateCoupleKeyPair();
    const ids = ['acct-a-0001', 'acct-b-0002'];
    final keyA = await JournalCrypto.deriveCoupleKeyX25519(privA, pubB, ids);
    final keyB = await JournalCrypto.deriveCoupleKeyX25519(privB, pubA, ids);

    final cipher = await JournalCrypto.encryptWithBase64(keyA, '{"tasks":[]}');
    final plain = await JournalCrypto.decryptWithBase64(keyB, cipher);
    expect(plain, '{"tasks":[]}');
  });

  test('账号 id 顺序不影响结果（双方不必约定谁在前）', () async {
    final (privA, _) = await JournalCrypto.generateCoupleKeyPair();
    final (_, pubB) = await JournalCrypto.generateCoupleKeyPair();
    final k1 =
        await JournalCrypto.deriveCoupleKeyX25519(privA, pubB, ['a', 'b']);
    final k2 =
        await JournalCrypto.deriveCoupleKeyX25519(privA, pubB, ['b', 'a']);
    expect(k1, k2);
  });

  test('换一对账号 id 会得到不同密钥（不会串到别的配对）', () async {
    final (privA, _) = await JournalCrypto.generateCoupleKeyPair();
    final (_, pubB) = await JournalCrypto.generateCoupleKeyPair();
    final k1 =
        await JournalCrypto.deriveCoupleKeyX25519(privA, pubB, ['a', 'b']);
    final k2 =
        await JournalCrypto.deriveCoupleKeyX25519(privA, pubB, ['a', 'c']);
    expect(k1, isNot(equals(k2)));
  });
}
