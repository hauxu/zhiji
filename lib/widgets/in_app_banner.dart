import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_keys.dart';

import '../theme.dart';

/// 应用根导航 key：横幅通过根 overlay 覆盖所有页面。

OverlayEntry? _bannerEntry;
void Function()? _activeClose;

/// 应用内顶部横幅：新留言等即时事件的显眼提醒（替代易被忽略的 SnackBar）。
/// 4 秒自动消失；点击整条触发 [onTap]（如跳转留言板）；同一时间只显示一条。
void showInAppBanner({
  required String title,
  required String body,
  VoidCallback? onTap,
  String? avatarPath,
}) {
  final overlay = rootNavigatorKey.currentState?.overlay;
  if (overlay == null) return;
  // 同帧内连续弹出时旧横幅尚未 build（_activeClose 为空），
  // 直接移除即可；已 build 的走动画收起。
  if (_activeClose == null) {
    _bannerEntry?.remove();
    _bannerEntry = null;
  } else {
    _activeClose?.call();
  }
  OverlayEntry? entry;
  entry = OverlayEntry(
    builder: (_) => _InAppBanner(
      title: title,
      body: body,
      onTap: onTap,
      avatarPath: avatarPath,
      onClose: (close) => _activeClose = close,
      // 收起动画完成后只移除自己，此刻可能有新横幅已插入。
      onDismissed: () {
        if (identical(_bannerEntry, entry)) _bannerEntry = null;
        final e = entry;
        if (e != null && e.mounted) e.remove();
      },
    ),
  );
  _bannerEntry = entry;
  overlay.insert(entry);
}

class _InAppBanner extends StatefulWidget {
  const _InAppBanner({
    required this.title,
    required this.body,
    required this.onClose,
    required this.onDismissed,
    this.onTap,
    this.avatarPath,
  });

  final String title;
  final String body;
  final VoidCallback? onTap;
  final String? avatarPath;
  final void Function(void Function() close) onClose;
  final VoidCallback onDismissed;

  @override
  State<_InAppBanner> createState() => _InAppBannerState();
}

class _InAppBannerState extends State<_InAppBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: m3Medium,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: m3CurveIn));
  Timer? _autoClose;

  @override
  void initState() {
    super.initState();
    widget.onClose(_close);
    _ctrl.forward();
    _autoClose = Timer(const Duration(seconds: 4), _close);
  }

  bool _closing = false;

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    _autoClose?.cancel();
    _ctrl.reverse().then((_) => widget.onDismissed());
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final topPad = MediaQuery.paddingOf(context).top;
    final avatar = widget.avatarPath;
    return Positioned(
      top: topPad + 8,
      left: 12,
      right: 12,
      child: SlideTransition(
        position: _slide,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              _close();
              widget.onTap?.call();
            },
            child: Ink(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: scheme.tertiaryContainer,
                      backgroundImage:
                          avatar != null &&
                              avatar.isNotEmpty &&
                              File(avatar).existsSync()
                          ? FileImage(File(avatar))
                          : null,
                      child: avatar == null || avatar.isEmpty
                          ? Icon(
                              Icons.favorite_rounded,
                              size: 15,
                              color: scheme.tertiary,
                            )
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            widget.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.keyboard_arrow_up_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
