import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' hide Hmac;
import 'package:cryptography/cryptography.dart';

/// 日记 AES-256-GCM 加密；密钥由恢复码 PBKDF2 派生，仅存本机。
class JournalCrypto {
  JournalCrypto._();

  static final AesGcm _algo = AesGcm.with256bits();
  static final Random _random = Random.secure();

  static const int recoveryGroupCount = 16;
  static const int recoveryGroupDigits = 4;
  static const String _kdfSalt = 'zhiji-journal-v1'; // 改动会使已发放的恢复码全部失效

  static List<String> generateRecoveryCodes() => List.generate(
        recoveryGroupCount,
        (_) => List.generate(
            recoveryGroupDigits, (_) => _random.nextInt(10)).join(),
      );

  static String normalizeRecoveryInput(String input) =>
      input.replaceAll(RegExp(r'\D'), '');

  static bool looksLikeRecoveryCodes(String input) =>
      normalizeRecoveryInput(input).length ==
      recoveryGroupCount * recoveryGroupDigits;

  static Future<SecretKey> deriveKeyFromRecovery(String input) async {
    final digits = normalizeRecoveryInput(input);
    if (digits.length != recoveryGroupCount * recoveryGroupDigits) {
      throw ArgumentError('恢复码需要 ${recoveryGroupCount * recoveryGroupDigits} 位数字');
    }
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(digits)),
      nonce: utf8.encode(_kdfSalt),
    );
  }

  static SecretKey keyFromBase64(String base64Key) =>
      SecretKey(base64Decode(base64Key));

  /// 通用口令派生密钥（PBKDF2-HMAC-SHA256）。
  static Future<SecretKey> deriveKeyFromSecret(
      String secret, String salt, int iterations) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(secret)),
      nonce: utf8.encode(salt),
    );
  }

  static Future<String> keyToBase64(SecretKey key) async =>
      base64Encode(await key.extractBytes());

  // ---- 情侣密钥协商（X25519）：新配对双方均上报公钥时启用 ----

  /// 生成协商密钥对，返回 (privateKeyBase64, publicKeyBase64)。
  static Future<(String, String)> generateCoupleKeyPair() async {
    final algo = X25519();
    final kp = await algo.newKeyPair();
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return (base64Encode(priv), base64Encode(pub.bytes));
  }

  /// 长期身份密钥（Ed25519）。用来给对方上报的 X25519 公钥签名：
  /// 服务端只有公钥、拿不到私钥，就没法伪造「对方换了公钥」。
  static Future<(String, String)> generateIdentityKeyPair() async {
    final algo = Ed25519();
    final kp = await algo.newKeyPair();
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return (base64Encode(priv), base64Encode(pub.bytes));
  }

  /// 从身份私钥推导公钥（换机恢复时只恢复私钥也能补出公钥）。
  static Future<String> identityPublicFromPrivate(String privB64) async {
    final algo = Ed25519();
    final kp = await algo.newKeyPairFromSeed(base64Decode(privB64));
    final pub = await kp.extractPublicKey();
    return base64Encode(pub.bytes);
  }

  /// 用身份私钥给一段数据签名（这里是 X25519 公钥的原始字节）。
  static Future<String> signWithIdentity(String privB64, List<int> data) async {
    final algo = Ed25519();
    final kp = await algo.newKeyPairFromSeed(base64Decode(privB64));
    final sig = await algo.sign(data, keyPair: kp);
    return base64Encode(sig.bytes);
  }

  /// 校验对方给的签名。pub 或 sig 格式不对时返回 false，不抛异常。
  static Future<bool> verifyIdentity(
      String pubB64, List<int> data, String sigB64) async {
    try {
      final algo = Ed25519();
      final pub = SimplePublicKey(base64Decode(pubB64),
          type: KeyPairType.ed25519);
      return await algo.verify(data, signature: Signature(base64Decode(sigB64),
          publicKey: pub));
    } catch (_) {
      return false;
    }
  }

  /// 安全码：双方身份公钥排序后哈希，两台设备算出来一样。
  /// 显示成 4-4-4 便于口头核对。
  static String safetyNumber(String identityA, String identityB) {
    if (identityA.isEmpty || identityB.isEmpty) return '';
    final pair = [identityA, identityB]..sort();
    final h = sha256.convert(utf8.encode('zhiji-id:${pair.join('|')}')).bytes;
    final hex = h
        .take(6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '${hex.substring(0, 4)}-${hex.substring(4, 8)}-'
        '${hex.substring(8, 12)}';
  }

  /// 双方各算各的：X25519 共享秘密 → HKDF-SHA256 → 32 字节共享密钥。
  /// 服务端只转发公钥，无法得到该密钥。
  static Future<String> deriveCoupleKeyX25519(
      String myPrivateKeyBase64,
      String partnerPublicKeyBase64,
      List<String> accountIds) async {
    final algo = X25519();
    final mine =
        await algo.newKeyPairFromSeed(base64Decode(myPrivateKeyBase64));
    final shared = await algo.sharedSecretKey(
        keyPair: mine,
        remotePublicKey: SimplePublicKey(
            base64Decode(partnerPublicKeyBase64),
            type: KeyPairType.x25519));
    final ids = [...accountIds]..sort();
    final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
            secretKey: shared,
            nonce: utf8.encode('zhiji-couple-v2:${ids.join(':')}'),
            info: utf8.encode('shared-data'));
    return base64Encode(await derived.extractBytes());
  }

  static Future<String> encryptWithBase64(
          String base64Key, String plain) async =>
      encrypt(plain, keyFromBase64(base64Key));

  static Future<String> decryptWithBase64(
          String base64Key, String data) async =>
      decrypt(data, keyFromBase64(base64Key));

  static Future<String> encrypt(String plainJson, SecretKey key) async {
    final nonce = Uint8List.fromList(
        List<int>.generate(12, (_) => _random.nextInt(256)));
    final secretBox = await _algo.encrypt(
      Uint8List.fromList(utf8.encode(plainJson)),
      secretKey: key,
      nonce: nonce,
    );
    final result = Uint8List(nonce.length + secretBox.cipherText.length + secretBox.mac.bytes.length);
    result.setRange(0, nonce.length, nonce);
    result.setRange(nonce.length, nonce.length + secretBox.cipherText.length, secretBox.cipherText);
    result.setRange(nonce.length + secretBox.cipherText.length,
        nonce.length + secretBox.cipherText.length + secretBox.mac.bytes.length,
        secretBox.mac.bytes);
    return base64Encode(result);
  }

  static Future<String> decrypt(String base64Data, SecretKey key) async {
    final bytes = base64Decode(base64Data);
    const nonceLen = 12;
    const macLen = 16;
    if (bytes.length <= nonceLen + macLen) {
      throw ArgumentError('data too short');
    }
    final nonce = bytes.sublist(0, nonceLen);
    final cipherText = bytes.sublist(nonceLen, bytes.length - macLen);
    final mac = Mac(bytes.sublist(bytes.length - macLen));
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    final clearText = await _algo.decrypt(secretBox, secretKey: key);
    return utf8.decode(clearText);
  }
}
