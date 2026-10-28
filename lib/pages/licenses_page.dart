import 'package:flutter/material.dart';

import '../widgets/responsive.dart';

/// 开源许可条目：[许可类型, 包名, 在本应用中的用途, 作者/维护方]。
const List<(String, String, String, String)> _kLicenses = [
  // Apache-2.0
  (
    'Apache-2.0',
    'dynamic_color',
    'Material You 莫奈动态取色（仅 Android 生效）',
    'Google',
  ),
  ('Apache-2.0', 'cryptography', '日记 AES-GCM 加密', 'Gohilla'),
  // BSD
  ('BSD', 'Flutter 框架', '应用运行时与组件库', 'Google'),
  ('BSD', 'flutter_localizations', '中文本地化', 'Google'),
  ('BSD', 'image_picker', '头像选择（相册/相机）', 'Flutter 团队'),
  ('BSD', 'shared_preferences', '本地键值存储', 'Flutter 团队'),
  ('BSD', 'path_provider', '系统目录访问', 'Flutter 团队'),
  ('BSD', 'intl', '日期与文本本地化', 'Dart 团队'),
  ('BSD', 'crypto', '哈希与摘要', 'Dart 团队'),
  ('BSD', 'flutter_local_notifications', '系统通知与定时提醒', 'Michael Bui'),
  ('BSD', 'timezone', '时区数据库（含 IANA 数据）', 'timezone 贡献者'),
  ('BSD', 'open_filex', '打开下载的更新包', 'open_filex 贡献者'),
  ('BSD', 'package_info_plus', '应用版本信息', 'fluttercommunity'),
  ('BSD', 'device_info_plus', '设备信息（版本详情页）', 'fluttercommunity'),
  ('BSD', 'share_plus', '系统分享面板', 'fluttercommunity'),
  ('BSD', 'connectivity_plus', '网络状态与在线判断', 'fluttercommunity'),
  ('BSD', 'file_selector', 'Windows 端文件选择', 'Flutter 团队'),
  ('BSD', 'android_alarm_manager_plus', '后台定时提醒与同步唤醒', 'fluttercommunity'),
  // MIT
  ('MIT', 'flutter_slidable', '列表条目的滑动操作', 'Romain Rastel'),
  ('MIT', 'cupertino_icons', '图标资源', 'Vladimir Kharlampidi'),
  ('MIT', 'provider', '状态管理', 'Remi Rousselet'),
  ('MIT', 'lunar', '农历日期换算', '6tail'),
  ('MIT', 'audioplayers', '提示音播放', 'Blue Fire'),
  ('MIT', 'geolocator', '天气精确定位', 'Baseflow'),
];

const Map<String, String> _kLicenseNotes = {
  'Apache-2.0': '宽松许可，带明确的专利授权。保留版权与许可声明，修改过的文件需注明改动。',
  'BSD': '宽松许可。保留版权声明与免责条款；不得用原作者名义推广（BSD-3 第 3 条）。',
  'MIT': '宽松许可。保留版权与许可声明即可使用、修改、分发。',
};

/// 开源许可页：按许可类型分组展示第三方组件与许可说明。
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = <String, List<(String, String, String, String)>>{};
    for (final item in _kLicenses) {
      groups.putIfAbsent(item.$1, () => []).add(item);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('开源许可')),
      body: ResponsiveContent(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.public_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '开源许可',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '之计客户端以 GPL-3.0 开源：可以自由使用、修改和再分发，'
                      '修改后的版本也要按 GPL-3.0 发布。同步服务端（server/）'
                      '以 AGPL-3.0 开源，部署成对外服务时也要公开修改后的源码。',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '许可说明',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '以下组件采用 MIT、BSD 或 Apache-2.0 许可：可以免费使用、'
                      '修改和再分发，保留原作者的版权与许可声明。'
                      '这些组件按「现状」提供，不含任何担保。',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            for (final entry in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                child: Text(
                  '${entry.key} 许可',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                child: Text(
                  _kLicenseNotes[entry.key] ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < entry.value.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          indent: 16,
                          endIndent: 16,
                          color: scheme.outlineVariant,
                        ),
                      ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          entry.value[i].$2,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${entry.value[i].$3} · ${entry.value[i].$4}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Center(
              child: Text(
                '完整许可文本见各组件的源码仓库',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
