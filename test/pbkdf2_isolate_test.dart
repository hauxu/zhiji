import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/crypto/journal_crypto.dart';
import 'package:goalday/sync/sync_service.dart';

/// PBKDF2 移到后台 isolate：
/// - 结果必须与主线程（JournalCrypto）逐字节一致，KDF 参数/salt 未改变，
///   否则老恢复码/历史云端数据会解不开；
/// - 210k 迭代期间主 isolate 的定时器必须照常触发（UI 不被卡死）。
void main() {
  test('PBKDF2 isolate 派生与主线程结果一致（小迭代）', () async {
    const secret = 'unit-test-secret';
    const salt = 'zhiji-couple-v1:acc-a:acc-b';
    final direct = await JournalCrypto.keyToBase64(
        await JournalCrypto.deriveKeyFromSecret(secret, salt, 2000));
    final isolated = await pbkdf2Base64InIsolate(secret, salt, 2000);
    expect(isolated, direct);
  });

  test('恢复码 isolate 派生与 JournalCrypto 一致（100k，参数未变）', () async {
    final codes = JournalCrypto.generateRecoveryCodes().join();
    final direct = await JournalCrypto.keyToBase64(
        await JournalCrypto.deriveKeyFromRecovery(codes));
    final sw = Stopwatch()..start();
    final isolated = await recoveryKeyBase64InIsolate(codes);
    sw.stop();
    expect(isolated, direct);
    // ignore: avoid_print
    print('[pbkdf2] recovery 100k isolate: ${sw.elapsedMilliseconds}ms');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('210k 派生在 isolate 执行时主 isolate 定时器仍在跑（不阻塞 UI）', () async {
    var ticks = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 25), (_) => ticks++);
    final sw = Stopwatch()..start();
    final out = await pbkdf2Base64InIsolate(
        'bindcode-7K2M9X', 'zhiji-couple-v1:acc-1:acc-2', 210000);
    sw.stop();
    timer.cancel();
    expect(out.isNotEmpty, isTrue);
    // ignore: avoid_print
    print('[pbkdf2] couple 210k isolate: ${sw.elapsedMilliseconds}ms, '
        'main-isolate ticks=$ticks');
    expect(ticks, greaterThan(5),
        reason: 'PBKDF2 若仍在主 isolate 上执行，定时器将几乎不触发');
  }, timeout: const Timeout(Duration(minutes: 2)));
}