import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../widgets/responsive.dart';

import 'package:image_picker/image_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../ai/ai_config.dart';
import '../ai/ai_service.dart';
import '../data/seed.dart';
import '../desktop/windows_shell.dart';
import '../data/store.dart';
import '../sync/focus_island.dart';
import '../sync/keep_alive.dart';
import '../sync/notify.dart';
import '../sync/reminders.dart';
import '../theme.dart';
import '../ui_prefs.dart';
import '../weather/weather_service.dart';
import '../widgets/recovery_codes.dart';
import '../widgets/update_flow.dart';
import '../widgets/background_sheet.dart';
import '../widgets/keep_alive_helper.dart';
import '../sync/sync_service.dart';
import '../theme_store.dart';
import '../util/native_share.dart';
import 'archived_page.dart';
import 'devices_page.dart';
import 'couple_page.dart';
import 'history_page.dart';
import 'licenses_page.dart';
import '../widgets/m3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 我的：账号、情侣绑定、云端备份、历史计划、设置与关于。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then(
      (v) => mounted ? setState(() => _info = v) : null,
    );
  }

  Future<void> _backupNow() async {
    final sync = context.read<SyncService>();
    if (sync.isSyncing) return;
    final ok = await sync.backupNow();
    if (!mounted) return;
    // 只有真的推上去了才提示；成功不再打扰（备份卡时间会更新）。
    if (!ok) {
      showTopToast('备份未完成：${sync.lastError ?? '这次没有上传'}');
    }
  }

  /// 放弃云端旧备份，用本机数据重建。旧备份会被覆盖，必须二次确认。
  Future<void> _rebuildFromLocal() async {
    final sync = context.read<SyncService>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('用本机数据重建云端备份'),
        content: const Text('云端旧备份将被本机数据覆盖，且无法找回'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认重建'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await sync.rebuildCloudFromLocal();
    if (!mounted) return;
    if (!done) showTopToast('重建没有成功，稍后再试');
  }

  Future<void> _restoreFromCloud() async {
    final sync = context.read<SyncService>();
    if (sync.isSyncing) return;
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从云端恢复？'),
        content: const Text('将用云端备份替换本机全部数据，未备份的新增内容会丢失'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await sync.restoreFromCloud();
    if (!mounted) return;
    if (result == null) {
      showTopToast('云端还没有备份');
    } else if (result is RestoreResult) {
      if (result.needsUnlock) {
        // 云端是加密的，本机还没密钥：先解锁，解锁成功后自动补完恢复。
        if (result.lockedJournal != null && mounted) {
          await _promptUnlockJournal(
            result.lockedJournal!,
            completeRestore: true,
          );
        } else {
          showTopToast('云端备份已加密，需要恢复码才能恢复');
        }
        return;
      }
      if (result.lockedJournal != null && mounted) {
        await _promptUnlockJournal(result.lockedJournal!);
      }
    } else {
      showTopToast('恢复未完成，请稍后再试');
    }
  }

  Future<void> _promptUnlockJournal(
    String encrypted, {
    bool completeRestore = false,
  }) async {
    final sync = context.read<SyncService>();
    // 预填本机上一次用过的数据密钥。
    final lastKey = await sync.lastJournalKey();
    if (!mounted) return;
    final ctrl = TextEditingController(text: lastKey);
    final key = await showM3Dialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('解锁云端备份'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('云端备份已加密，输入恢复码或备份密钥', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: '恢复码（16 组数字）或备份密钥',
                  helperText: lastKey.isNotEmpty ? '已自动填入本机上一次使用的密钥' : null,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('暂不解锁'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text),
            child: const Text('解锁'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (key == null || key.trim().isEmpty) return;
    final ok = await sync.unlockJournalWithKey(key, encrypted);
    if (!mounted) return;
    if (!ok) showTopToast('密钥不对，解锁失败');
    if (ok && completeRestore) {
      // 密钥就位后把上次被拦下的恢复补完；若仍未完成，备份卡会停在
      // “等待从云端恢复”并给出按钮，不再额外弹提示。
      await sync.restoreFromCloud();
      if (!mounted) return;
    }
  }

  /// 独立的备份解锁入口：用上次恢复时留存的密文，不必重新走一遍恢复。
  Future<void> _unlockFromStored() async {
    final sync = context.read<SyncService>();
    final cipher = await sync.lockedJournalCipher();
    if (!mounted) return;
    if (cipher == null || cipher.isEmpty) {
      showTopToast('没有待解锁的备份，先用「从云端恢复」');
      return;
    }
    await _promptUnlockJournal(cipher);
  }

  Future<void> _checkUpdate() async {
    await showUpdateCenterSheet(context);
  }

  Future<void> _restoreInitialData() async {
    final confirmed1 = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复初始数据？'),
        content: const Text('本机数据将被清空，云端备份不受影响'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed1 != true || !mounted) return;
    final confirmed2 = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('再次确认'),
        content: const Text('清空后无法撤销'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed2 == true && mounted) {
      // 云端备份不受影响：抑制重置后的一次自动推送。
      context.read<SyncService>().suppressNextPush();
      final store = context.read<AppStore>();
      store.replaceData(seedData());
      // 数据清空后，之前写进应用目录的图片/附件就没人引用了，一并清掉，
      // 否则「恢复初始数据」之后磁盘上还留着旧照片。
      unawaited(store.purgeUnusedAttachments());
    }
  }

  Future<void> _clearCaches() async {
    await context.read<SyncService>().clearLocalCache();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final loggedIn = sync.loggedIn;

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ResponsiveContent(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _AccountCard(loggedIn: loggedIn),
            const SizedBox(height: 12),
            _CoupleCard(),
            const SizedBox(height: 12),
            _BackupCard(
              onBackup: _backupNow,
              onRestore: _restoreFromCloud,
              onRebuild: _rebuildFromLocal,
              onUnlock: _unlockFromStored,
              onSetupRecovery: _manageJournalKey,
            ),
            const SizedBox(height: 12),
            _SettingsCard(
              onOpenHistory: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const HistoryPage())),
              onOpenArchived: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ArchivedPage())),
              onClearCaches: _clearCaches,
              onRestoreInitial: _restoreInitialData,
              onManageJournalKey: _manageJournalKey,
              onCheckUpdate: _checkUpdate,
              onShowBuildInfo: _showBuildInfo,
              version: _info?.version ?? '…',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _manageJournalKey() async {
    await showRecoverySetupFlow(context);
  }

  Future<void> _showBuildInfo() async {
    final info = _info;
    final themeStore = context.read<ThemeStore>();
    final sync = context.read<SyncService>();
    final rows = <(String, String)>[];

    if (info != null) {
      rows.add(('package', info.packageName));
      rows.add(('build', '${info.version} (${info.buildNumber})'));
    }
    try {
      final support = await getApplicationSupportDirectory();
      rows.add(('storage', support.path));
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        final android = await DeviceInfoPlugin().androidInfo;
        final release = android.version.release;
        final sdk = android.version.sdkInt;
        rows.add(('os', 'Android $release (API $sdk)'));
        rows.add((
          'abi',
          android.supportedAbis.isEmpty
              ? 'unknown'
              : android.supportedAbis.first,
        ));
        rows.add(('brand', '${android.brand} ${android.model}'));
        rows.add(('build.id', android.id));
      } catch (_) {}
    }
    if (Platform.isWindows) {
      try {
        final win = await DeviceInfoPlugin().windowsInfo;
        rows.add((
          'os',
          '${win.productName} ${win.displayVersion} (build ${win.buildNumber})',
        ));
        rows.add(('abi', 'x64（ARM64 Windows 经内置仿真运行）'));
        rows.add(('brand', win.computerName));
      } catch (_) {}
    }
    final darkDesc = switch (themeStore.darkMode) {
      true => '深色',
      false => '跟随系统',
    };
    rows.add((
      'theme',
      Platform.isWindows
          ? '固定品牌色 · $darkDesc'
          : '莫奈取色 ${themeStore.useDynamic ? '开' : '关'} · $darkDesc',
    ));
    rows.add(('sync', sync.loggedIn ? '已登录 ${sync.username}' : '未登录'));
    if (mounted) {
      final versionLabel = info == null
          ? '…'
          : 'v${info.version} (${info.buildNumber})';
      await showM3Dialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const _AppIconBadge(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '之计',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              versionLabel,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(dialogContext)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '一日之计：清单、计划、日子与习惯。\n'
                    '本地存储，登录后云备份，可绑定情侣',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: Theme.of(dialogContext)
                          .colorScheme
                          .onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final (key, value) in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 86,
                            child: Text(
                              '[$key]',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.4,
                                color: Color(0x99888888),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              value,
                              softWrap: true,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            FilledButton.tonal(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LicensesPage()),
                );
              },
              child: const Text('开源许可'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }
}

class _AppIconBadge extends StatelessWidget {
  const _AppIconBadge();

  static const Color kleinBlue = Color(0xFF002FA7);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: kleinBlue,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 26),
    );
  }
}

class _AccountCard extends StatefulWidget {
  const _AccountCard({required this.loggedIn});

  final bool loggedIn;

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  String? _avatarPath;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _pickAvatar() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
      );
      if (picked == null || !mounted) return;
      final sync = context.read<SyncService>();
      final dir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      final oldPath = _avatarPath;
      final savePath =
          '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(picked.path).copy(savePath);
      if (!mounted) return;
      // 清理上一张头像文件。
      if (oldPath != null &&
          oldPath != savePath &&
          oldPath != sync.avatarPath &&
          File(oldPath).existsSync()) {
        try {
          await File(oldPath).delete();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _avatarPath = savePath);
      await sync.setAvatarPath(savePath);
    } catch (_) {
      if (mounted) showTopToast('头像保存失败，请重试');
    }
  }

  Future<void> _editNickname() async {
    final sync = context.read<SyncService>();
    final ctrl = TextEditingController(text: sync.myName);
    final name = await showM3Dialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑昵称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 20,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
          decoration: const InputDecoration(labelText: '昵称', counterText: ''),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name != null && name.isNotEmpty && mounted) {
      await sync.setMyName(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    if (!widget.loggedIn) {
      return Card(
        child: ListTile(
          onTap: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const CouplePage())),
          leading: CircleAvatar(
            backgroundColor: scheme.surfaceContainerHigh,
            child: Icon(Icons.person_outline_rounded, color: scheme.outline),
          ),
          title: const Text(
            '未登录',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text('登录后可云备份与情侣同步', style: TextStyle(fontSize: 12)),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            InkWell(
              onTap: _pickAvatar,
              customBorder: const CircleBorder(),
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: scheme.primaryContainer,
                    backgroundImage:
                        sync.avatarPath.isNotEmpty &&
                            File(sync.avatarPath).existsSync()
                        ? FileImage(File(sync.avatarPath))
                        : (_avatarPath != null
                              ? FileImage(File(_avatarPath!))
                              : null),
                    child: sync.avatarPath.isEmpty && _avatarPath == null
                        ? Text(
                            sync.myName.isEmpty ? '我' : sync.myName[0],
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: scheme.primary,
                            ),
                          )
                        : null,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.camera_alt_rounded,
                        size: 11,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: _editNickname,
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          sync.myName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.edit_rounded,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sync.username,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final confirmed = await showM3Dialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('退出登录？'),
                    content: const Text(
                      '退出会解除情侣绑定，并清除本机的'
                      '备份密钥与恢复码；云端备份保留，重新登录同一账号'
                      '可恢复数据（云端备份需恢复码）',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: const Text('退出'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  await context.read<SyncService>().logout();
                }
              },
              child: const Text('退出'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoupleCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final subtitle = !sync.loggedIn
        ? '登录后可用'
        : sync.isBound
        ? '和 ${sync.partnerName} 在一起 · 上次同步 ${_ago(sync.lastSyncAt)}'
        : '未绑定 · 生成绑定码邀请 TA';
    return Card(
      child: ListTile(
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const CouplePage())),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          backgroundImage:
              sync.isBound &&
                  sync.partnerAvatarPath.isNotEmpty &&
                  File(sync.partnerAvatarPath).existsSync()
              ? FileImage(File(sync.partnerAvatarPath))
              : null,
          child:
              (sync.isBound &&
                  sync.partnerAvatarPath.isNotEmpty &&
                  File(sync.partnerAvatarPath).existsSync())
              ? null
              : Icon(
                  sync.isBound
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: scheme.primary,
                ),
        ),
        title: Text(
          sync.isBound ? '和 ${sync.partnerName} 在一起' : '情侣绑定',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }

  String _ago(int ms) {
    if (ms <= 0) return '尚未同步';
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 3600 * 1000) return '${diff ~/ 60000} 分钟前';
    if (diff < 24 * 3600 * 1000) return '${diff ~/ 3600000} 小时前';
    return '${diff ~/ 86400000} 天前';
  }
}

class _BackupCard extends StatelessWidget {
  const _BackupCard({
    required this.onBackup,
    required this.onRestore,
    required this.onRebuild,
    required this.onUnlock,
    required this.onSetupRecovery,
  });

  final VoidCallback onBackup;
  final VoidCallback onRestore;

  /// 放弃云端旧备份、用本机数据重建（危险，需确认）。
  final VoidCallback onRebuild;
  final VoidCallback onUnlock;
  final VoidCallback onSetupRecovery;

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    // 备份卡右上角状态：正常时显示上次备份时间，异常时显示原因。
    final backupLabel = !sync.loggedIn
        ? '登录后自动备份'
        : sync.pendingUnlock
        ? '备份未解锁 · 自动备份暂停中'
        : sync.restoreBlocked
        ? '等待从云端恢复 · 自动备份暂停中'
        : switch (sync.health) {
            SyncHealth.offline =>
              sync.hasPendingChanges ? '离线中 · 改动已保存，联网后自动备份' : '离线中 · 联网后自动备份',
            SyncHealth.serverDown => '暂时连不上服务器 · ${sync.lastError ?? '未知原因'}',
            SyncHealth.authFailed => '登录已过期',
            SyncHealth.error => '备份未完成：${sync.lastError}',
            _ =>
              sync.cloudBackupAt == 0
                  ? '还没有备份记录'
                  : '上次备份 ${_agoStatic(sync.cloudBackupAt)}',
          };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cloud_upload_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                const Text(
                  '云端备份',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  backupLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '上传前本机加密，服务器只存密文；头像与昵称明文。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            // 云备份端到端加密：没有恢复码，换机后解不开。
            if (sync.loggedIn && !sync.hasRecoveryCodes) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '未设置恢复码，换机后无法解密备份',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.error,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onSetupRecovery,
                    child: const Text('去设置', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
            // 解锁/恢复失败后 pendingUnlock 会一直是 true，之前这个条件把
            // 「重建备份」也一起藏了，用户就只剩卸装一条路。只要处于等待恢复
            // 状态就给出这个出口。
            if (sync.loggedIn && sync.restoreBlocked) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '备份未恢复到本机，自动备份已暂停',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.error,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onRestore,
                    child: const Text('从云端恢复', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '没有恢复码时，可用本机数据重建备份',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onRebuild,
                    child: const Text('重建备份', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
            if (sync.loggedIn && sync.pendingUnlock) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '备份未解锁，自动备份已暂停',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.error,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onUnlock,
                    child: const Text('解锁备份', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    // 同步中禁用，避免连点（原来靠「正在同步中」提示拦截）。
                    onPressed: sync.loggedIn && !sync.isSyncing
                        ? onBackup
                        : null,
                    icon: const Icon(Icons.cloud_upload_rounded, size: 18),
                    label: const Text('立即备份'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: sync.loggedIn && !sync.isSyncing
                        ? onRestore
                        : null,
                    icon: const Icon(Icons.cloud_download_rounded, size: 18),
                    label: const Text('从云端恢复'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _agoStatic(int ms) {
    if (ms <= 0) return '尚未备份';
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 3600 * 1000) return '${diff ~/ 60000} 分钟前';
    if (diff < 24 * 3600 * 1000) return '${diff ~/ 3600000} 小时前';
    return '${diff ~/ 86400000} 天前';
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.onOpenHistory,
    required this.onOpenArchived,
    required this.onClearCaches,
    required this.onRestoreInitial,
    required this.onCheckUpdate,
    required this.onManageJournalKey,
    required this.onShowBuildInfo,
    required this.version,
  });

  final VoidCallback onOpenHistory;
  final VoidCallback onOpenArchived;
  final VoidCallback onShowBuildInfo;
  final VoidCallback onManageJournalKey;
  final VoidCallback onClearCaches;
  final VoidCallback onRestoreInitial;
  final VoidCallback onCheckUpdate;
  final String version;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        children: [
          const _CardTitle('提醒与通知'),
          if (Platform.isAndroid) const _NotificationPermissionTile(),
          if (Platform.isAndroid)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(
                Icons.phone_android_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              title: const Text('后台与提醒适配', style: TextStyle(fontSize: 14)),
              subtitle: Text('自启动与保活设置', style: const TextStyle(fontSize: 11)),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () async {
                m3HapticSelect();
                final brand = await NativeShare.manufacturer();
                if (!context.mounted) return;
                await showKeepAliveGuideSheet(context, brand);
              },
            ),
          if (Platform.isAndroid) const _IslandLine(),
          if (Platform.isAndroid) const _KeepAliveLine(),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const _CardTitle('外观'),
          ListTile(
            dense: true,
            leading: Icon(
              Icons.wallpaper_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            title: const Text('自定义背景', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              context.watch<UiPrefs>().bgEnabled &&
                      context.watch<UiPrefs>().bgPath.isNotEmpty
                  ? '已启用 · 图片透明度 ${((1 - context.watch<UiPrefs>().bgOpacity) * 100).toStringAsFixed(0)}%'
                  : '选择图片作为背景',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => showBackgroundSheet(context),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('深色模式', style: TextStyle(fontSize: 14)),
            value: context.watch<ThemeStore>().darkMode,
            onChanged: (v) {
              m3HapticSelect();
              context.read<ThemeStore>().setDarkMode(v);
            },
          ),
          if (!Platform.isWindows)
            SwitchListTile(
              dense: true,
              title: const Text('跟随系统取色', style: TextStyle(fontSize: 14)),
              subtitle: const Text('使用系统壁纸取色', style: TextStyle(fontSize: 11)),
              value: context.watch<ThemeStore>().useDynamic,
              onChanged: (v) {
                m3HapticSelect();
                context.read<ThemeStore>().setUseDynamic(v);
              },
            ),
          if (!Platform.isWindows)
            ListTile(
              dense: true,
              leading: Icon(
                Icons.palette_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              title: const Text('主题颜色', style: TextStyle(fontSize: 14)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: context.watch<ThemeStore>().seedColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right_rounded, size: 20),
                ],
              ),
              onTap: () => showThemeColorPicker(context),
            ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const _CardTitle('天气'),
          const _WeatherPreciseTile(),
          if (Platform.isWindows) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            const _CardTitle('Windows'),
            const _LaunchAtStartupTile(),
            const _GlassTile(),
            const _GlassStrengthTile(),
            const _MinimizeToTrayTile(),
          ],
          const Divider(height: 1, indent: 16, endIndent: 16),
          const _CardTitle('通用'),
          const _AiAssistantTile(),
          const DevicesTile(),
          ListTile(
            dense: true,
            leading: Icon(
              Icons.history_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            title: const Text('历史计划', style: TextStyle(fontSize: 14)),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: onOpenHistory,
          ),
          ListTile(
            dense: true,
            leading: Icon(
              Icons.key_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            title: const Text('备份密钥与恢复码', style: TextStyle(fontSize: 14)),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: onManageJournalKey,
          ),
          ListTile(
            dense: true,
            leading: Icon(
              Icons.inventory_2_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            title: const Text('归档', style: TextStyle(fontSize: 14)),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: onOpenArchived,
          ),
          ListTile(
            dense: true,
            leading: Icon(
              Icons.cleaning_services_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            title: const Text('清除本地缓存', style: TextStyle(fontSize: 14)),
            onTap: onClearCaches,
          ),
          ListTile(
            dense: true,
            leading: Icon(
              Icons.restart_alt_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            title: const Text('恢复初始数据', style: TextStyle(fontSize: 14)),
            onTap: onRestoreInitial,
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            dense: true,
            leading: Icon(
              Icons.system_update_alt_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            title: const Text('检查更新', style: TextStyle(fontSize: 14)),
            subtitle: Text('v$version', style: TextStyle(fontSize: 11)),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: onCheckUpdate,
          ),
          ListTile(
            dense: true,
            leading: Icon(
              Icons.fact_check_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            title: const Text('版本详情', style: TextStyle(fontSize: 14)),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: onShowBuildInfo,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// Windows 开机自动启动占位：真正接 launch_at_startup 后，只需替换
/// [_readLaunchAtStartup] / [_writeLaunchAtStartup] 两个方法即可。
class _LaunchAtStartupTile extends StatefulWidget {
  const _LaunchAtStartupTile();

  @override
  State<_LaunchAtStartupTile> createState() => _LaunchAtStartupTileState();
}

class _LaunchAtStartupTileState extends State<_LaunchAtStartupTile> {
  bool _enabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _readLaunchAtStartup().then((v) {
      if (mounted) {
        setState(() {
          _enabled = v;
          _loaded = true;
        });
      }
    });
  }

  Future<bool> _readLaunchAtStartup() =>
      WindowsShell.instance.isAutoStartEnabled();

  Future<bool> _writeLaunchAtStartup(bool value) =>
      WindowsShell.instance.setAutoStart(value);

  Future<void> _toggle(bool value) async {
    m3HapticSelect();
    setState(() => _enabled = value);
    final ok = await _writeLaunchAtStartup(value);
    if (!ok && mounted) {
      setState(() => _enabled = !value);
      showTopToast('开机自启设置失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SwitchListTile(
      dense: true,
      secondary: Icon(
        Icons.power_settings_new_rounded,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      title: const Text('开机自动启动', style: TextStyle(fontSize: 14)),
      subtitle: const Text('登录后自动启动，不弹主窗口', style: TextStyle(fontSize: 11)),
      value: _loaded ? _enabled : false,
      onChanged: _loaded ? _toggle : null,
    );
  }
}

/// 「窗口毛玻璃」开关：Mica/亚克力，关掉就回到不透明窗口。
class _GlassTile extends StatefulWidget {
  const _GlassTile();

  @override
  State<_GlassTile> createState() => _GlassTileState();
}

class _GlassTileState extends State<_GlassTile> {
  bool _enabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WindowsShell.instance.isGlassEnabled().then((v) {
      if (mounted) {
        setState(() {
          _enabled = v;
          _loaded = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SwitchListTile(
      dense: true,
      secondary: Icon(
        Icons.blur_on_rounded,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      title: const Text('窗口毛玻璃', style: TextStyle(fontSize: 14)),
      subtitle: const Text('透出桌面轮廓', style: TextStyle(fontSize: 11)),
      value: _enabled,
      onChanged: _loaded
          ? (v) async {
              m3HapticSelect();
              setState(() => _enabled = v);
              await WindowsShell.instance.setGlassEnabled(v);
            }
          : null,
    );
  }
}

/// 毛玻璃浓度：清晰 / 标准 / 通透。
class _GlassStrengthTile extends StatelessWidget {
  const _GlassStrengthTile();

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<UiPrefs>();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Icon(
            Icons.opacity_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          const Text('浓度', style: TextStyle(fontSize: 14)),
          const Spacer(),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('清晰')),
              ButtonSegment(value: 1, label: Text('标准')),
              ButtonSegment(value: 2, label: Text('通透')),
            ],
            selected: {prefs.glassStrength},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (v) {
              m3HapticSelect();
              prefs.setGlassStrength(v.first);
            },
          ),
        ],
      ),
    );
  }
}

/// 「关闭窗口时最小化到托盘」开关。
class _MinimizeToTrayTile extends StatefulWidget {
  const _MinimizeToTrayTile();

  @override
  State<_MinimizeToTrayTile> createState() => _MinimizeToTrayTileState();
}

class _MinimizeToTrayTileState extends State<_MinimizeToTrayTile> {
  bool _enabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WindowsShell.instance.isMinimizeToTray().then((v) {
      if (mounted) {
        setState(() {
          _enabled = v;
          _loaded = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SwitchListTile(
      dense: true,
      secondary: Icon(
        Icons.minimize_rounded,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      title: const Text('关闭窗口时最小化到托盘', style: TextStyle(fontSize: 14)),
      subtitle: const Text('关闭后继续后台同步', style: TextStyle(fontSize: 11)),
      value: _enabled,
      onChanged: _loaded
          ? (v) async {
              m3HapticSelect();
              setState(() => _enabled = v);
              await WindowsShell.instance.setMinimizeToTray(v);
            }
          : null,
    );
  }
}

/// 「AI 助手」设置入口：只在打开/返回时读一次本机配置，build 不碰 prefs。
class _AiAssistantTile extends StatefulWidget {
  const _AiAssistantTile();

  @override
  State<_AiAssistantTile> createState() => _AiAssistantTileState();
}

class _AiAssistantTileState extends State<_AiAssistantTile> {
  bool _enabled = AiConfig.cached.enabled;
  bool _configured = AiConfig.cached.isConfigured;
  String _model = AiConfig.cached.model;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _apply(AiConfig cfg) {
    _enabled = cfg.enabled;
    _configured = cfg.isConfigured;
    _model = cfg.model;
  }

  Future<void> _refresh() async {
    final cfg = await AiConfig.load();
    if (!mounted) return;
    setState(() => _apply(cfg));
  }

  Future<void> _open() async {
    m3HapticSelect();
    await _showAiSettingsSheet(context);
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = _configured
        ? '已启用 · $_model'
        : _enabled
        ? '已开启，配置未完成'
        : '未启用 · 配置后可用 ✨ 识别';
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.auto_awesome_rounded,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      title: const Text('AI 助手', style: TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: _open,
    );
  }
}

/// AI 助手设置弹层：运行时配置 OpenAI 兼容接口。
/// Key 只存本机、默认关闭；「测试连接」用当前表单值且不要求先启用。
Future<void> _showAiSettingsSheet(BuildContext context) {
  return showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _AiSettingsSheet(),
  );
}

class _AiSettingsSheet extends StatefulWidget {
  const _AiSettingsSheet();

  @override
  State<_AiSettingsSheet> createState() => _AiSettingsSheetState();
}

class _AiSettingsSheetState extends State<_AiSettingsSheet> {
  late final TextEditingController _baseUrl = TextEditingController(
    text: AiConfig.cached.baseUrl,
  );
  late final TextEditingController _model = TextEditingController(
    text: AiConfig.cached.model,
  );
  late final TextEditingController _apiKey = TextEditingController(
    text: AiConfig.cached.apiKey,
  );
  bool _enabled = AiConfig.cached.enabled;
  bool _obscureKey = true;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    // 缓存没加载过时读一次本机配置；只在字段为空时回填，避免覆盖用户输入。
    AiConfig.load().then((cfg) {
      if (!mounted) return;
      setState(() {
        _enabled = cfg.enabled;
        if (_baseUrl.text.trim().isEmpty) _baseUrl.text = cfg.baseUrl;
        if (_model.text.trim().isEmpty) _model.text = cfg.model;
        if (_apiKey.text.isEmpty) _apiKey.text = cfg.apiKey;
      });
    });
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  /// 当前表单值；测试连接直接用未保存的输入。
  AiConfig get _draft => AiConfig(
    enabled: _enabled,
    baseUrl: _baseUrl.text,
    model: _model.text,
    apiKey: _apiKey.text,
  );

  Future<void> _test() async {
    if (_testing) return;
    setState(() => _testing = true);
    final result = await AiService.testConnection(_draft);
    if (!mounted) return;
    setState(() => _testing = false);
    showTopToast(result.message);
  }

  Future<void> _save() async {
    final cfg = _draft;
    await cfg.save();
    if (!mounted) return;
    if (cfg.enabled && (cfg.endpoint == null || cfg.apiKey.isEmpty)) {
      showTopToast('已保存；启用 AI 还需要接口地址与 API Key');
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'AI 助手',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '新建计划时点 ✨，由下面配置的接口识别输入',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 AI 识别', style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                  '填好 Key 后才会显示 ✨',
                  style: TextStyle(fontSize: 11),
                ),
                value: _enabled,
                onChanged: (v) {
                  m3HapticSelect();
                  setState(() => _enabled = v);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '接口地址',
                  hintText: AiConfig.defaultBaseUrl,
                  helperText: 'OpenAI 兼容 baseUrl，不用写 /chat/completions',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '模型名',
                  hintText: 'gpt-4o-mini',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKey,
                obscureText: _obscureKey,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: 'sk-…',
                  helperText: '只存本机，留空则不启用',
                  suffixIcon: IconButton(
                    tooltip: _obscureKey ? '显示 Key' : '隐藏 Key',
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    icon: Icon(
                      _obscureKey
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 20,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering_rounded, size: 18),
                      label: Text(_testing ? '测试中…' : '测试连接'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _testing ? null : _save,
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'API Key 只存本机；识别时会把输入文字发给你填写的接口',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '常见配置（接口地址 · 模型名）',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '千问（默认）：${AiConfig.defaultBaseUrl} · ${AiConfig.defaultModel}（Key 形如 sk-ws-…）\n'
                'OpenAI：https://api.openai.com/v1 · gpt-4o-mini\n'
                'DeepSeek：https://api.deepseek.com/v1 · deepseek-chat\n'
                '智谱 GLM：https://open.bigmodel.cn/api/paas/v4 · glm-4.5-flash',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 小米 HyperOS 超级岛提醒（实验）：到点提醒以灵动岛胶囊弹出。
/// 仅小米/红米/POCO 设备渲染；未授权焦点通知时自动回落普通通知。
class _IslandLine extends StatefulWidget {
  const _IslandLine();

  @override
  State<_IslandLine> createState() => _IslandLineState();
}

class _IslandLineState extends State<_IslandLine> {
  Map<String, dynamic>? _status;
  bool _enabled = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final st = await FocusIsland.status();
    final on = await FocusIsland.isEnabled();
    if (!mounted) return;
    setState(() {
      _status = st;
      _enabled = on;
    });
  }

  Future<void> _toggle(bool v) async {
    m3HapticSelect();
    setState(() => _enabled = v);
    final usable =
        _status != null &&
        _status!['isXiaomi'] == true &&
        _status!['canShowFocus'] != false;
    await FocusIsland.setEnabled(v, usable: usable);
    if (!mounted) return;
    final sync = context.read<SyncService>();
    final store = context.read<AppStore>();
    await Reminders.rescheduleAll(
      store,
      force: true,
      taskEnabled: sync.swTaskReminders,
      milestoneEnabled: sync.swMilestoneReminders,
      habitEnabled: sync.swHabitReminders,
      partnerMilestones: sync.partner?.data.milestones ?? const [],
    );
  }

  Future<void> _sendTest() async {
    if (_sending) return;
    m3HapticSelect();
    setState(() => _sending = true);
    final ok = await FocusIsland.postIslandTest();
    if (!mounted) return;
    {
      setState(() => _sending = false);
      if (ok) {
      } else {
        showTopToast('测试发送失败：通知权限可能被关闭');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    // 非小米设备不渲染（首帧 status 未回前先显示占位判断 isXiaomi）。
    if (st != null && st['isXiaomi'] != true) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final supported = st == null ? null : st['systemSupported'] == true;
    final focus = st == null ? null : st['canShowFocus'];
    final focusLabel = focus == null
        ? '焦点通知权限：未知'
        : focus == true
        ? '焦点通知权限：已允许'
        : '焦点通知权限：已被拦截（提醒自动回落为普通通知）';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          dense: true,
          title: const Text('超级岛提醒（实验）', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            st == null
                ? '正在检测设备…'
                : '小米/红米/POCO 支持 · 到点提醒以灵动岛胶囊弹出 · $focusLabel'
                      '${supported == false ? ' · 未检测到灵动岛开关' : ''}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          value: _enabled && (focus != false),
          onChanged: st == null
              ? null
              : (v) {
                  if (focus == false) return;
                  _toggle(v);
                },
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _sending ? null : _sendTest,
                icon: const Icon(Icons.traffic_rounded, size: 16),
                label: const Text('发送超级岛测试', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 通知与提醒权限：一句话说明 + 一个「开启通知」按钮，依次申请
/// 通知权限、精确闹钟、全屏弹窗、忽略电池优化；缺哪项就在结果里点名。
class _NotificationPermissionTile extends StatefulWidget {
  const _NotificationPermissionTile();

  @override
  State<_NotificationPermissionTile> createState() =>
      _NotificationPermissionTileState();
}

class _NotificationPermissionTileState
    extends State<_NotificationPermissionTile>
    with WidgetsBindingObserver {
  bool? _exact;
  bool? _fullScreen;
  bool? _battery;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统授权页返回后复检（IndexedStack 常驻，仅靠 initState 不够）。
    if (state == AppLifecycleState.resumed) _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    final exact = await Notify.instance.canScheduleExact();
    final fullScreen = await NativeShare.canUseFullScreenIntent();
    final battery = await NativeShare.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _exact = exact;
      _fullScreen = fullScreen;
      _battery = battery;
    });
  }

  Future<void> _enable() async {
    if (_busy) return;
    m3HapticSelect();
    setState(() => _busy = true);
    final missing = <String>[];
    if (!await Notify.instance.requestPermission()) {
      missing.add('通知权限');
    }
    if (!await Notify.instance.canScheduleExact()) {
      missing.add('精确闹钟');
      await NativeShare.openExactAlarmSettings();
    }
    if (!await NativeShare.canUseFullScreenIntent()) {
      if (!await Notify.instance.requestFullScreenIntent()) {
        missing.add('全屏弹窗');
      }
    }
    if (!await NativeShare.isIgnoringBatteryOptimizations()) {
      await NativeShare.requestIgnoreBatteryOptimizations();
      if (!await NativeShare.isIgnoringBatteryOptimizations()) {
        missing.add('忽略电池优化');
      }
    }
    await _check();
    if (!mounted) return;
    setState(() => _busy = false);
    if (missing.isNotEmpty) {
      // 权限被拒会直接导致提醒/留言收不到，必须告诉用户缺哪项。
      showTopToast('还差：${missing.join('、')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = _exact == true && _fullScreen == true && _battery == true;
    return ListTile(
      dense: true,
      leading: Icon(
        ok
            ? Icons.notifications_active_rounded
            : Icons.notifications_paused_rounded,
        size: 20,
        color: ok ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: const Text('开启通知', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        ok ? '权限已就绪' : '开启通知、提醒与后台运行权限',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: _busy ? null : _enable,
              child: Text(
                ok ? '检查' : '开启',
                style: const TextStyle(fontSize: 12),
              ),
            ),
    );
  }
}

/// 后台保活状态行：常驻静默连接换取秒级消息提醒（不接厂商推送）。
class _KeepAliveLine extends StatefulWidget {
  const _KeepAliveLine();

  @override
  State<_KeepAliveLine> createState() => _KeepAliveLineState();
}

class _KeepAliveLineState extends State<_KeepAliveLine>
    with WidgetsBindingObserver {
  bool _enabled = KeepAliveBridge.enabled;
  bool _notifOk = KeepAliveBridge.notificationsEnabled;
  bool _batteryOk = KeepAliveBridge.ignoringBatteryOptimizations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    await KeepAliveBridge.refreshSystemState();
    await KeepAliveBridge.refreshNoticeState();
    if (!mounted) return;
    setState(() {
      _enabled = KeepAliveBridge.enabled;
      _notifOk = KeepAliveBridge.notificationsEnabled;
      _batteryOk = KeepAliveBridge.ignoringBatteryOptimizations;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final healthy = _enabled && _notifOk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          secondary: Icon(
            Icons.bolt_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          title: const Text('后台保持连接', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            _enabled
                ? (healthy ? '已开启，退后台也能收到消息' : '已开启，通知权限未授予')
                : '已关闭，改由系统闹钟每 2 分钟拉取',
            style: const TextStyle(fontSize: 11),
          ),
          value: _enabled,
          onChanged: (v) async {
            m3HapticSelect();
            await context.read<SyncService>().applyKeepAliveSetting(v);
            await _refresh();
          },
        ),
        if (_enabled && !_notifOk)
          _permRow('允许通知', NativeShare.openNotificationSettings),
        if (_enabled && !_batteryOk)
          _permRow('忽略电池优化', KeepAliveBridge.openBatterySettings),
      ],
    );
  }

  Widget _permRow(String label, Future<void> Function() open) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        m3HapticSelect();
        await open();
        await _refresh();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 15,
              color: Theme.of(context).colorScheme.tertiary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    ),
  );
}

class _CardTitle extends StatelessWidget {
  const _CardTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

void showThemeColorPicker(BuildContext context) {
  final themeStore = context.read<ThemeStore>();
  final scheme = Theme.of(context).colorScheme;
  showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '主题颜色 · 中国传统色',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              if (!Platform.isWindows)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('跟随系统取色', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    themeStore.useDynamic ? '使用系统壁纸色' : '使用传统色',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  value: themeStore.useDynamic,
                  onChanged: (v) {
                    m3HapticSelect();
                    themeStore.setUseDynamic(v);
                    Navigator.of(sheetContext).pop();
                  },
                ),
              const SizedBox(height: 6),
              Text(
                '选择传统色',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.95,
                children: [
                  for (final tc in traditionalColors)
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        m3HapticSelect();
                        themeStore.setSeed(tc.value);
                        Navigator.of(sheetContext).pop();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: themeStore.seedColor == tc.value
                                ? scheme.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: tc.value,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: scheme.outlineVariant,
                                  width: 1,
                                ),
                              ),
                              child: themeStore.seedColor == tc.value
                                  ? Icon(
                                      Icons.check_rounded,
                                      size: 18,
                                      color: tc.value.computeLuminance() > 0.5
                                          ? Colors.black
                                          : Colors.white,
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              tc.name,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11,
                                color: themeStore.seedColor == tc.value
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 天气定位开关：开了用设备定位，关掉走 IP 粗略定位。
class _WeatherPreciseTile extends StatefulWidget {
  const _WeatherPreciseTile();

  @override
  State<_WeatherPreciseTile> createState() => _WeatherPreciseTileState();
}

class _WeatherPreciseTileState extends State<_WeatherPreciseTile> {
  bool _on = true;

  @override
  void initState() {
    super.initState();
    WeatherService.preciseEnabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  Future<void> _toggle(bool value) async {
    m3HapticSelect();
    setState(() => _on = value);
    await WeatherService.setPreciseEnabled(value);
    if (!value || !mounted) return;
    // 打开后顺手请求一次定位权限；用户拒绝就让天气回落 IP，不再反复打扰。
    final ok = await WeatherService.ensurePrecisePermission();
    if (!ok && mounted) {
      showTopToast('没有定位权限，先用网络大致定位');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      title: const Text('天气用设备定位', style: TextStyle(fontSize: 14)),
      subtitle: const Text('关闭后按网络定位', style: TextStyle(fontSize: 11)),
      value: _on,
      onChanged: _toggle,
    );
  }
}
