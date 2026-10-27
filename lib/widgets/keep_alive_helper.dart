import 'package:flutter/material.dart';

import '../sync/notify.dart';
import '../theme.dart';
import '../util/native_share.dart';
import 'm3_dialog.dart';

/// 各厂商「自启动/后台运行」设置页组件名（社区通用表，按序尝试）。
const _vendorAutostartComponents = <String, List<(String, String)>>{
  'xiaomi': [
    (
      'com.miui.securitycenter',
      'com.miui.permcenter.autostart.AutoStartManagementActivity',
    ),
  ],
  'redmi': [
    (
      'com.miui.securitycenter',
      'com.miui.permcenter.autostart.AutoStartManagementActivity',
    ),
  ],
  'oppo': [
    (
      'com.coloros.safecenter',
      'com.coloros.safecenter.permission.startup.StartupAppListActivity',
    ),
    (
      'com.oplus.safecenter',
      'com.oplus.safecenter.permission.startup.StartupAppListActivity',
    ),
  ],
  'oneplus': [
    (
      'com.oneplus.security',
      'com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity',
    ),
  ],
  'realme': [
    (
      'com.coloros.safecenter',
      'com.coloros.safecenter.permission.startup.StartupAppListActivity',
    ),
  ],
  'vivo': [
    (
      'com.vivo.permissionmanager',
      'com.vivo.permissionmanager.activity.BgStartUpManagerActivity',
    ),
  ],
  'iqoo': [
    (
      'com.vivo.permissionmanager',
      'com.vivo.permissionmanager.activity.BgStartUpManagerActivity',
    ),
  ],
  'huawei': [
    (
      'com.huawei.systemmanager',
      'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
    ),
  ],
  'honor': [
    (
      'com.hihonor.systemmanager',
      'com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
    ),
  ],
};

/// 按厂商给出「自启动/后台」设置页的引导文案；无深链的厂商返回 null。
String? vendorAutostartHint(String brand) {
  final b = brand.toLowerCase();
  if (_vendorAutostartHints.containsKey(b)) return _vendorAutostartHints[b];
  for (final key in _vendorAutostartHints.keys) {
    if (b.contains(key)) return _vendorAutostartHints[key];
  }
  return null;
}

const _vendorAutostartHints = <String, String>{
  'xiaomi':
      '请在 系统设置 → 应用设置 → 应用管理 → 之计 中开启「自启动」，'
      '并在省电策略里选择「无限制」',
  'redmi':
      '请在 系统设置 → 应用设置 → 应用管理 → 之计 中开启「自启动」，'
      '并在省电策略里选择「无限制」',
  'oppo': '请允许之计「自启动」和「关联启动」，并在电池设置里关闭深度睡眠',
  'oneplus': '请允许之计「自启动」和「关联启动」，并在电池设置里关闭智能休眠',
  'realme': '请允许之计「自启动」，并在电池设置里允许后台运行',
  'vivo':
      '请在 设置 → 电池 → 后台耗电管理 中允许之计后台高耗电，'
      '并在权限管理里允许自启动',
  'iqoo':
      '请在 设置 → 电池 → 后台耗电管理 中允许之计后台高耗电，'
      '并在权限管理里允许自启动',
  'huawei':
      '请在 设置 → 电池 → 启动管理 中把之计改为「手动管理」，'
      '并允许全部三项（自启动/关联启动/后台活动）',
  'honor':
      '请在 设置 → 电池 → 启动管理 中把之计改为「手动管理」，'
      '并允许全部三项（自启动/关联启动/后台活动）',
};

/// 「后台运行设置」入口：按厂商依次尝试深链，全部失败回退应用详情页。
Future<void> openVendorBackgroundSettings(
  BuildContext context,
  String brand,
) async {
  final b = brand.toLowerCase();
  final components =
      _vendorAutostartComponents[b] ??
      _vendorAutostartComponents.entries
          .firstWhere(
            (e) => b.contains(e.key),
            orElse: () => const MapEntry('', []),
          )
          .value;
  for (final (pkg, cls) in components) {
    final opened = await NativeShare.openComponent('$pkg/$cls');
    if (opened) return;
  }
  await NativeShare.openNotificationSettings();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: kSnackBarDuration,
        content: Text('已打开应用信息页，请在「电池」与「通知」中允许后台运行'),
      ),
    );
  }
}

/// 「后台与提醒适配」设置弹层：按品牌给保活引导，附自启动深链入口。
Future<void> showKeepAliveGuideSheet(BuildContext context, String brand) async {
  final hint = vendorAutostartHint(brand) ?? '本机无需额外设置，通知与保活按原生行为工作';
  final scheme = Theme.of(context).colorScheme;
  await showM3Sheet<void>(
    context: context,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '后台与提醒适配',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hint,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.tune_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              title: const Text(
                '打开本机的自启动 / 后台设置',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () => openVendorBackgroundSettings(context, brand),
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.notifications_active_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              title: const Text('发送测试提醒', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '5 秒后弹一条测试通知，验证横幅/锁屏效果',
                style: TextStyle(fontSize: 11),
              ),
              onTap: () async {
                await Notify.instance.requestPermission();
                await Future.delayed(const Duration(seconds: 5));
                await Notify.instance.showTestReminder();
              },
            ),
          ],
        ),
      ),
    ),
  );
}
