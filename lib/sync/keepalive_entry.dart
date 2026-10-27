import 'package:flutter/widgets.dart';

import '../data/store.dart';
import 'keep_alive.dart';
import 'notify.dart';
import 'sync_service.dart';

/// 后台保活服务专属的 Dart 入口（运行在服务自己的 Flutter 引擎里）。
///
/// 界面被划掉后主引擎会销毁，这里另起一条长轮询，新留言/评价照常弹
/// 系统通知——不接厂商推送时，这是「划掉也能收到」的关键一环。
///
/// 与主引擎靠 `gd2_main_beat` 心跳协调：主引擎活着时它让位休眠，
/// 避免两边同时轮询、重复弹通知。
@pragma('vm:entry-point')
Future<void> keepAliveEntry() async {
  WidgetsFlutterBinding.ensureInitialized();
  SyncService.headless = true;
  await Notify.instance.init();
  await KeepAliveBridge.load();
  final store = AppStore();
  await store.load();
  final sync = SyncService(store);
  // 主引擎也在监听同一批事件：两边都可能弹，走统一入口按事件去重。
  sync.onEvent = (event) {
    sync.notifyCoupleEventOnce(event);
  };
  await sync.init();
  // 主引擎每 15 秒写一次心跳；45 秒没更新说明它已经不在了。
  while (true) {
    if (await SyncService.mainEngineAlive()) {
      await Future<void>.delayed(const Duration(seconds: 10));
      continue;
    }
    try {
      await sync.alarmTick();
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}
