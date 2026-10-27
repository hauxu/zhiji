import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync/notify.dart';
import '../sync/updater.dart';
import '../theme.dart';
import '../util/open.dart';
import '../util/window_bridge.dart';
import 'm3_dialog.dart';
import '../widgets/top_toast.dart' show showTopToast;

bool _autoCheckDone = false;

const _autoUpdatePrefKey = 'gd2_auto_update';

/// 后台下载的全局状态：更新弹窗、更新中心、系统通知共用。
class BackgroundUpdate {
  static final ValueNotifier<BackgroundUpdateState?> state = ValueNotifier(
    null,
  );

  static bool get active => state.value?.phase == BackgroundPhase.downloading;
}

enum BackgroundPhase { downloading, ready, failed, cancelled }

class BackgroundUpdateState {
  const BackgroundUpdateState({
    required this.file,
    required this.latest,
    required this.expectedSha256,
    required this.phase,
    this.progress = 0,
    this.path,
    this.error,
  });

  final String file;
  final String latest;
  final String? expectedSha256;
  final BackgroundPhase phase;
  final double progress;

  /// phase=ready 时为已校验包的本地路径。
  final String? path;
  final String? error;

  BackgroundUpdateState copyWith({
    BackgroundPhase? phase,
    double? progress,
    String? path,
    String? error,
  }) => BackgroundUpdateState(
    file: file,
    latest: latest,
    expectedSha256: expectedSha256,
    phase: phase ?? this.phase,
    progress: progress ?? this.progress,
    path: path ?? this.path,
    error: error ?? this.error,
  );
}

/// 「立即更新」入口：弹窗即刻关闭，下载转后台，完成后系统通知安装。
Future<void> startBackgroundUpdate(
  BuildContext context,
  Map<String, dynamic> result,
) async {
  final file = result['file'] as String? ?? '';
  final latest = result['latest'] as String? ?? '';
  final sha = result['sha256'] as String?;
  if (file.isEmpty || BackgroundUpdate.active) return;
  // 本地已有校验通过的包时跳过下载直接就绪。
  final cached = await Updater.findVerifiedPackage(file, sha ?? '');
  if (cached != null) {
    BackgroundUpdate.state.value = BackgroundUpdateState(
      file: file,
      latest: latest,
      expectedSha256: sha,
      phase: BackgroundPhase.ready,
      progress: 1,
      path: cached,
    );
    await Notify.instance.showUpdateProgress(
      percent: 100,
      version: latest,
      ready: true,
    );
    if (Platform.isWindows) {}
    unawaited(Updater.cleanup(keepName: file));
    return;
  }
  BackgroundUpdate.state.value = BackgroundUpdateState(
    file: file,
    latest: latest,
    expectedSha256: sha,
    phase: BackgroundPhase.downloading,
  );
  Updater.cancelRequested = false;
  try {
    var lastNotified = -5;
    final path = await Updater.download(file, (received, total) {
      final v = total > 0 ? received / total : 0.0;
      final cur = BackgroundUpdate.state.value;
      if (cur != null && cur.phase == BackgroundPhase.downloading) {
        BackgroundUpdate.state.value = cur.copyWith(progress: v);
      }
      // 下载通知按 5% 节流刷新，避免高频系统调用。
      final percent = (v * 100).floor();
      if (percent >= lastNotified + 5 || percent <= 1) {
        lastNotified = percent;
        unawaited(
          Notify.instance.showUpdateProgress(percent: percent, version: latest),
        );
      }
      if (Platform.isWindows) WindowBridge.setProgress(v);
    }, expectedSha256: sha);
    BackgroundUpdate.state.value = BackgroundUpdate.state.value?.copyWith(
      phase: BackgroundPhase.ready,
      progress: 1,
      path: path,
    );
    await Notify.instance.showUpdateProgress(
      percent: 100,
      version: latest,
      ready: true,
      path: path,
    );
    if (Platform.isWindows) {
      WindowBridge.clearProgress();
      WindowBridge.setProgress(1);
    }
    unawaited(Updater.cleanup(keepName: file));
  } catch (e) {
    final cancelled = e.toString().contains('已取消');
    BackgroundUpdate.state.value = BackgroundUpdate.state.value?.copyWith(
      phase: cancelled ? BackgroundPhase.cancelled : BackgroundPhase.failed,
      error: e.toString(),
    );
    if (Platform.isWindows) WindowBridge.clearProgress();
    await Notify.instance.clearUpdateProgress();
  }
}

/// 安装已就绪的更新包（通知点击/更新中心「安装」按钮共用）。
Future<void> installReadyPackage(BuildContext context) async {
  final st = BackgroundUpdate.state.value;
  final path = st?.path;
  if (path == null || !File(path).existsSync()) return;
  try {
    if (Platform.isWindows && path.toLowerCase().endsWith('.zip')) {
      // Windows 便携版：解包到同名目录后打开。
      final destPath = path.substring(0, path.length - 4);
      final destDir = Directory(destPath);
      if (destDir.existsSync()) {
        destDir.deleteSync(recursive: true);
      }
      destDir.createSync(recursive: true);
      final r = await Process.run('tar', ['-xf', path, '-C', destPath]);
      if (r.exitCode == 0) {
        await openExternally(destPath);
      } else {
        await openExternally(path);
      }
    } else if (Platform.isWindows) {
      await openExternally(path);
    } else {
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done) {
        showTopToast('无法启动安装，请允许「安装未知应用」权限');
      }
    }
  } catch (e) {
    showTopToast('安装更新失败：$e');
  }
}

Future<bool> _autoUpdateEnabled() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoUpdatePrefKey) ?? true;
  } catch (_) {
    return true;
  }
}

/// 启动后静默检查一次更新。
Future<void> autoCheckUpdateOnce(BuildContext context) async {
  if (_autoCheckDone || !Platform.isAndroid && !Platform.isWindows) return;
  _autoCheckDone = true;
  if (!await _autoUpdateEnabled()) return;
  try {
    final info = await PackageInfo.fromPlatform();
    final result = await Updater.check(info.version);
    if (result == null || result['update'] != true) return;
    if (!context.mounted) return;
    await showUpdateFlow(context, result);
  } catch (_) {
    // 静默检查失败不打扰用户。
  }
}

Future<Map<String, dynamic>?> runUpdateCheck(BuildContext context) async {
  final info = await PackageInfo.fromPlatform();
  Map<String, dynamic>? result;
  try {
    result = await Updater.check(info.version);
  } catch (e) {
    if (context.mounted) {}
    return null;
  }
  if (!context.mounted) return null;
  if (result == null) {
    // 未配置同步服务器：无更新通道。
    return null;
  }
  return result;
}

/// 更新中心弹层。
Future<void> showUpdateCenterSheet(BuildContext context) async {
  final info = await PackageInfo.fromPlatform();
  if (!context.mounted) return;
  await showM3Sheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _UpdateCenterSheet(version: info.version),
  );
}

class _UpdateCenterSheet extends StatefulWidget {
  const _UpdateCenterSheet({required this.version});

  final String version;

  @override
  State<_UpdateCenterSheet> createState() => _UpdateCenterSheetState();
}

class _UpdateCenterSheetState extends State<_UpdateCenterSheet> {
  late bool _autoUpdate = true;
  bool _autoLoaded = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _autoUpdate = prefs.getBool(_autoUpdatePrefKey) ?? true;
        _autoLoaded = true;
      });
    });
  }

  Future<void> _toggleAuto(bool value) async {
    m3HapticSelect();
    setState(() => _autoUpdate = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoUpdatePrefKey, value);
    } catch (_) {}
  }

  Future<void> _check() async {
    if (_checking) return;
    m3HapticSelect();
    setState(() => _checking = true);
    try {
      final result = await runUpdateCheck(context);
      if (!mounted) return;
      if (result == null) return; // 失败已由 runUpdateCheck 提示
      if (result['update'] == true) {
        // 先走更新流程、后收起更新中心，顺序不能反（先 pop 会挂在已销毁路由上）。
        await showUpdateFlow(context, result);
        if (mounted) Navigator.of(context).pop();
      } else {}
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '检查更新',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  '当前版本 v${widget.version}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启动时自动检查更新', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                _autoUpdate ? '启动时静默检查' : '仅手动检查',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              value: _autoUpdate,
              onChanged: _autoLoaded ? _toggleAuto : null,
            ),
            const Divider(height: 1),
            ValueListenableBuilder<BackgroundUpdateState?>(
              valueListenable: BackgroundUpdate.state,
              builder: (context, st, _) {
                if (st == null) return const SizedBox.shrink();
                if (st.phase == BackgroundPhase.downloading) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              st.latest.isEmpty
                                  ? '正在后台下载更新包'
                                  : '正在后台下载 v${st.latest}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Updater.cancelRequested = true;
                            },
                            child: const Text('取消'),
                          ),
                        ],
                      ),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: st.progress > 0 ? st.progress : null,
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        st.progress > 0
                            ? '${(st.progress * 100).toStringAsFixed(0)}% · 中断后可从进度续传'
                            : '连接中…',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );
                }
                if (st.phase == BackgroundPhase.ready && st.path != null) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => installReadyPackage(context),
                        icon: const Icon(
                          Icons.install_mobile_rounded,
                          size: 18,
                        ),
                        label: Text(
                          st.latest.isEmpty
                              ? '安装已就绪的更新包'
                              : '安装已就绪的 v${st.latest}',
                        ),
                      ),
                    ),
                  );
                }
                if (st.phase == BackgroundPhase.failed) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '上次下载失败：${st.error ?? '未知原因'}（重试会从已下载进度续传）',
                      style: TextStyle(fontSize: 11, color: scheme.error),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.history_edu_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              title: const Text('更新日志', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                '全部版本的变更记录',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ChangelogPage()),
                );
              },
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _checking ? null : _check,
                icon: _checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.system_update_alt_rounded, size: 18),
                label: Text(_checking ? '正在检查…' : '检查更新'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 更新日志独立页：从更新中心入口进入，可按大版本筛选。
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  String _major = '全部';
  late final Future<String> _changelog = rootBundle.loadString(
    'assets/CHANGELOG.md',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('更新日志')),
      body: FutureBuilder<String>(
        future: _changelog,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                '日志加载失败',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            );
          }
          final markdown = snap.data!;
          final majors = <String>{'全部'};
          for (final line in markdown.split('\n')) {
            final l = line.trim();
            if (l.startsWith('## v')) {
              final ver = l.substring(3).trim();
              majors.add(ver.split('.').first);
            }
          }
          final visible = _major == '全部'
              ? markdown
              : _filterMajor(markdown, _major);

          return Column(
            children: [
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final m in majors)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text(m == '全部' ? '全部' : '$m.x'),
                          selected: _major == m,
                          onSelected: (_) => setState(() => _major = m),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: _ChangelogView(markdown: visible),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 只保留指定大版本（v5/v4…）的版本段落。
  static String _filterMajor(String markdown, String major) {
    final out = <String>[];
    var keep = false;
    for (final line in markdown.split('\n')) {
      final l = line.trim();
      if (l.startsWith('## v')) {
        keep = l.substring(3).trim().split('.').first == major;
      }
      if (keep) out.add(line);
    }
    return out.join('\n');
  }
}

/// 极简 Markdown 渲染：版本标题与条目。
class _ChangelogView extends StatelessWidget {
  const _ChangelogView({required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = markdown.split('\n');
    final widgets = <Widget>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.startsWith('# ') || line.startsWith('> ') || line.isEmpty) {
        continue;
      }
      if (line.startsWith('## ')) {
        if (widgets.isNotEmpty) {
          widgets.add(const SizedBox(height: 10));
        }
        widgets.add(
          Text(
            line.substring(3).trim(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
        );
        continue;
      }
      if (line.startsWith('- ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Icon(
                    Icons.circle,
                    size: 4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _MdText(line.substring(2).trim())),
              ],
            ),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

/// 行内文本：剥除 ** 并对加粗段着重显示。
class _MdText extends StatelessWidget {
  const _MdText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <TextSpan>[];
    final base = TextStyle(
      fontSize: 12.5,
      height: 1.6,
      color: scheme.onSurfaceVariant,
    );
    final bold = TextStyle(
      fontSize: 12.5,
      height: 1.6,
      color: scheme.onSurface,
      fontWeight: FontWeight.w600,
    );
    var rest = text;
    while (true) {
      final i = rest.indexOf('**');
      if (i < 0) break;
      final j = rest.indexOf('**', i + 2);
      if (j < 0) break;
      if (i > 0) parts.add(TextSpan(text: rest.substring(0, i), style: base));
      parts.add(TextSpan(text: rest.substring(i + 2, j), style: bold));
      rest = rest.substring(j + 2);
    }
    parts.add(TextSpan(text: rest, style: base));
    return SelectableText.rich(TextSpan(children: parts, style: base));
  }
}

/// 新版本弹窗：更新日志完整滚动展示 + 确认后下载安装。
Future<void> showUpdateFlow(
  BuildContext context,
  Map<String, dynamic> result,
) async {
  final latest = result['latest'] as String? ?? '';
  final sizeMb = ((result['size'] as num? ?? 0) / 1024 / 1024).toStringAsFixed(
    1,
  );
  final notes = result['notes'] as String? ?? '';
  final scheme = Theme.of(context).colorScheme;

  final confirmed = await showM3Dialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 $latest'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (notes.isNotEmpty) ...[
              Text(
                '更新日志',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 190),
                child: SingleChildScrollView(
                  child: Text(
                    notes,
                    style: const TextStyle(fontSize: 13, height: 1.55),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Text(
              '大小 $sizeMb MB',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('以后再说'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('立即更新'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    // 下载转后台进行：弹窗即刻关闭，完成/失败经通知与应用内状态呈现。
    await startBackgroundUpdate(context, result);
  }
}
