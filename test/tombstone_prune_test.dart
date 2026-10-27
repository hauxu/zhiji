import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/store.dart';

void main() {
  test('pruneTombstones：只保留 30 天内的墓碑（保存/加载/合并同一规则）', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    const ttl = AppStore.tombstoneTtlMs;
    final tombs = <String, int>{
      'expired': now - ttl - 1000,
      'kept': now - ttl + 60 * 1000,
      'fresh': now,
    };
    AppStore.pruneTombstones(tombs);
    expect(tombs.containsKey('expired'), isFalse);
    expect(tombs.containsKey('kept'), isTrue);
    expect(tombs.containsKey('fresh'), isTrue);
  });
}