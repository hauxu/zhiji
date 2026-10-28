import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../widgets/m3_dialog.dart';
import '../data/models.dart';
import '../util/dates.dart';
import '../util/gallery_saver.dart';
import '../util/native_share.dart';
import 'journal_page.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 日记导出预览与分享。
class JournalSharePage extends StatefulWidget {
  const JournalSharePage({
    super.key,
    required this.date,
    required this.title,
    required this.text,
    required this.mood,
    required this.weather,
  });

  final DateTime date;
  final String title;
  final String text;
  final Mood? mood;
  final String? weather;

  @override
  State<JournalSharePage> createState() => _JournalSharePageState();
}

class _JournalSharePageState extends State<JournalSharePage> {
  final _boundaryKey = GlobalKey();
  bool _sharing = false;

  /// 生成分享图片到临时目录，返回文件；失败抛异常。
  Future<File> _generateImage() async {
    final boundary =
        _boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 3);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) throw Exception('图片编码失败');
    final bytes = data.buffer.asUint8List();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/zhiji_diary_${dateKey(widget.date)}.png');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<void> _saveImage() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    File? src;
    try {
      src = await _generateImage();
      // Android 优先写系统相册（MediaStore，不需要额外权限）；
      // 失败时回退到应用目录，至少文件还在。
      if (Platform.isAndroid) {
        final saved = await GallerySaver.saveImage(
          src.path,
          name: 'zhiji_diary_${dateKey(widget.date)}.png',
        );
        if (saved != null) {
          if (!mounted) return;
          showTopToast('已保存到相册');
          return;
        }
        {
          final dir = await getApplicationDocumentsDirectory();
          final destDir = Directory('${dir.path}/saved_diary');
          await destDir.create(recursive: true);
          final dest = File(
            '${destDir.path}/zhiji_diary_${dateKey(widget.date)}.png',
          );
          await src.copy(dest.path);
          if (!mounted) return;
          showTopToast('没存到相册，已存到应用目录：${dest.path}');
          return;
        }
      }
      // Windows（及其它桌面端）保持原逻辑：写 Pictures/Zhiji。
      Directory destDir;
      if (Platform.isWindows) {
        final home = Platform.environment['USERPROFILE'] ?? '';
        destDir = Directory('$home/Pictures/Zhiji');
      } else {
        destDir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/saved_diary',
        );
      }
      await destDir.create(recursive: true);
      final dest = File(
        '${destDir.path}/zhiji_diary_${dateKey(widget.date)}.png',
      );
      await src.copy(dest.path);
      if (!mounted) return;
      showTopToast('已保存到：${dest.path}');
    } catch (e) {
      if (mounted) showTopToast('保存失败：$e');
    } finally {
      if (mounted) setState(() => _sharing = false);
      // 临时目录里的预览图用完就删，避免长期堆积。
      try {
        if (src != null && await src.exists()) await src.delete();
      } catch (_) {}
    }
  }

  /// 精选分享目标面板：微信/QQ/微博（未安装隐藏）+ 更多方式（全量）。
  Future<void> _showTargets() async {
    final installed = await NativeShare.installedShareTargets();
    if (!mounted) return;
    final targets = [
      ('com.tencent.mm', '微信', Icons.chat_rounded, const Color(0xFF07C160)),
      (
        'com.tencent.mobileqq',
        'QQ',
        Icons.forum_rounded,
        const Color(0xFF12B7F5),
      ),
      (
        'com.sina.weibo',
        '微博',
        Icons.alternate_email_rounded,
        const Color(0xFFE6162D),
      ),
    ].where((t) => installed.contains(t.$1)).toList();

    await showM3Sheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Text(
                '分享到',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            for (final (pkg, label, icon, color) in targets)
              ListTile(
                leading: Icon(icon, color: color),
                title: Text(label, style: const TextStyle(fontSize: 14)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _shareTo(pkg);
                },
              ),
            ListTile(
              leading: const Icon(Icons.apps_rounded),
              title: const Text('更多方式…', style: TextStyle(fontSize: 14)),
              subtitle: const Text('全部分享目标', style: TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _share();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareTo(String package) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final file = await _generateImage();
      if (!await NativeShare.shareImageTo(file.path, package)) {
        // 指定应用分享失败时退回系统分享面板，不再额外打断用户。
        await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')]);
      }
    } catch (e) {
      showTopToast('分享失败：$e');
    } finally {
      if (context.mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final file = await _generateImage();
      // Android 优先原生 ACTION_SEND：厂商分享框架（MagicOS 等）接管。
      if (Platform.isAndroid && await NativeShare.shareImage(file.path)) {
        return;
      }
      // 纯图片 intent：不带文字，避免部分 ROM 只显示文字类分享目标。
      await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')]);
    } catch (e) {
      // 图片失败时退化为文字分享。
      try {
        await Share.share(
          _plainText(),
          subject: widget.title.isEmpty ? '我的日记' : widget.title,
        );
      } catch (e2) {
        showTopToast('分享失败：$e2');
      }
    } finally {
      if (context.mounted) setState(() => _sharing = false);
    }
  }

  String _plainText() {
    final buf = StringBuffer();
    buf.writeln(widget.title.isEmpty ? '我的日记' : widget.title.trim());
    if (widget.text.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln(widget.text.trim());
    }
    if (widget.mood != null) buf.writeln();
    if (widget.mood != null) buf.writeln('心情：${moodLabel(widget.mood)}');
    buf.writeln();
    buf.write('—— 来自 之计');
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = widget.date;

    return Scaffold(
      appBar: AppBar(title: const Text('日记卡片')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: _JournalCard(
                      date: d,
                      title: widget.title,
                      text: widget.text,
                      mood: widget.mood,
                      weather: widget.weather,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _sharing ? null : _saveImage,
                      icon: const Icon(Icons.save_alt_rounded, size: 18),
                      label: const Text('保存图片'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: scheme.primary,
                      ),
                      onPressed: _sharing ? null : _showTargets,
                      icon: _sharing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.ios_share_rounded, size: 18),
                      label: Text(_sharing ? '生成中…' : '系统分享'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JournalCard extends StatelessWidget {
  const _JournalCard({
    required this.date,
    required this.title,
    required this.text,
    required this.mood,
    required this.weather,
  });

  final DateTime date;
  final String title;
  final String text;
  final Mood? mood;
  final String? weather;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bodyText = text.trim();

    return Container(
      width: 320,
      padding: const EdgeInsets.fromLTRB(26, 26, 26, 20),
      decoration: BoxDecoration(
        color: scheme.surface, // 跟随主题深浅与取色
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '${date.year}年${date.month}月${date.day}日',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: scheme.primary,
                ),
              ),
              const Spacer(),
              if (weather != null && weather!.isNotEmpty) ...[
                Icon(
                  Icons.wb_sunny_rounded,
                  size: 13,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 3),
                Text(
                  weather!,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          Text(
            weekdayCn(date),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          if (title.trim().isNotEmpty) ...[
            Text(
              title.trim(),
              style: TextStyle(
                fontSize: 21,
                height: 1.35,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (bodyText.isNotEmpty)
            Text(
              bodyText,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.75,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          if (mood != null) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: moodColor(mood).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(moodIcon(mood), size: 15, color: moodColor(mood)),
                  const SizedBox(width: 6),
                  Text(
                    moodLabel(mood),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: moodColor(mood).withValues(alpha: 1.0),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 1,
                  color: scheme.primary.withValues(alpha: 0.25),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '之计',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
