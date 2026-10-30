import 'dart:io';

import 'package:flutter/material.dart';

import '../util/window_bridge.dart';

/// Windows 自绘标题栏。系统标题栏已由原生侧去掉（WM_NCCALCSIZE），
/// 拖动和缩放交给原生 WM_NCHITTEST，这里只放标题和窗口按钮。
class WindowsTitleBar extends StatelessWidget {
  const WindowsTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.favorite_rounded, size: 13, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            '之计',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          _WinButton(icon: Icons.remove_rounded, onTap: WindowBridge.minimize),
          _WinButton(
            icon: Icons.crop_square_rounded,
            onTap: WindowBridge.toggleMaximize,
          ),
          _WinButton(
            icon: Icons.close_rounded,
            danger: true,
            onTap: WindowBridge.closeWindow,
          ),
        ],
      ),
    );
  }
}

class _WinButton extends StatelessWidget {
  const _WinButton({
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 46,
      height: 38,
      child: InkWell(
        onTap: onTap,
        hoverColor: danger
            ? const Color(0x22D93025)
            : scheme.onSurface.withValues(alpha: 0.06),
        child: Icon(icon, size: 15, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
