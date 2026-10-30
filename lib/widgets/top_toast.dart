import 'dart:async';

import 'package:flutter/material.dart';

import 'app_keys.dart';

/// 顶部提示横幅入口：替代 SnackBar，出现在页面最上层。
void showTopToast(
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) => TopToast.show(message, actionLabel: actionLabel, onAction: onAction);

/// 顶部提示横幅：出现在页面最上层（状态栏下方），3.4 秒自动收起。
/// 替代贴底的黑色 SnackBar：全面屏手势区会压住底部提示，不便查看。
/// 新提示立即替换旧提示，不排队。
class TopToast {
  TopToast._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  /// 经全局 navigator 定位根 Overlay；App 未就绪时静默丢弃。
  static void show(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _timer?.cancel();
    _entry?.remove();
    _ToastCardState? cardState;
    _entry = OverlayEntry(
      builder: (_) => _ToastCard(
        message,
        actionLabel: actionLabel,
        onAction: onAction,
        onExpire: hide,
        onStateReady: (s) => cardState = s,
      ),
    );
    overlay.insert(_entry!);
    _timer = Timer(const Duration(milliseconds: 3400), () {
      cardState?.animateOut();
    });
  }

  static void hide() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard(
    this.message, {
    this.actionLabel,
    this.onAction,
    required this.onExpire,
    required this.onStateReady,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onExpire;
  final void Function(_ToastCardState) onStateReady;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );

  @override
  void initState() {
    super.initState();
    widget.onStateReady(this);
    _ctrl.forward();
  }

  Future<void> animateOut() async {
    await _ctrl.reverse();
    TopToast.hide();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top;
    return Positioned(
      top: top + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, -0.6),
          end: Offset.zero,
        ).animate(CurvedAnimation(curve: Curves.easeOutCubic, parent: _ctrl)),
        child: FadeTransition(
          opacity: _ctrl,
          child: Material(
            color: scheme.inverseSurface,
            elevation: 4,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: widget.actionLabel != null ? null : animateOut,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.message,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.35,
                          color: scheme.onInverseSurface,
                        ),
                      ),
                    ),
                    if (widget.actionLabel != null) ...[
                      const SizedBox(width: 4),
                      Semantics(
                        button: true,
                        label: widget.actionLabel,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              TopToast.hide();
                              widget.onAction?.call();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Center(
                                child: Text(
                                  widget.actionLabel!,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.inversePrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
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
