import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui/breakpoints.dart';

/// M3E 对话框：emphasized 缩放淡入。
Future<T?> showM3Dialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  RouteSettings? routeSettings,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor:
        barrierColor ??
        Theme.of(context).colorScheme.scrim.withValues(alpha: 0.5),
    barrierLabel:
        barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    routeSettings: routeSettings,
    transitionDuration: m3Duration,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: m3CurveIn,
        reverseCurve: m3CurveOut,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (context, _, _) {
      final child = builder(context);
      // 宽屏下 AlertDialog 不铺满整屏：限制最大宽度并居中。
      if (Breakpoints.of(context) == BreakpointSize.compact) return child;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: Breakpoints.dialogMaxWidth,
          ),
          child: child,
        ),
      );
    },
  );
}

/// M3E 底部弹层：emphasized 滑入。
Future<T?> showM3Sheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool showDragHandle = true,
}) {
  // 桌面 expanded 下，颜色/主题/图标等列表选择器改成居中 Dialog，
  // 不再从屏幕底部弹一条半屏 sheet。
  if (Breakpoints.of(context) == BreakpointSize.expanded) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: isDismissible,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.5),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: m3Duration,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: m3CurveIn,
          reverseCurve: m3CurveOut,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
      pageBuilder: (dialogContext, _, _) {
        final maxHeight = MediaQuery.sizeOf(dialogContext).height * 0.86;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: Breakpoints.sheetDialogMaxWidth,
              maxHeight: maxHeight,
            ),
            child: Dialog(
              clipBehavior: Clip.antiAlias,
              child: builder(dialogContext),
            ),
          ),
        );
      },
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    // 窄窗口下限宽。
    constraints: const BoxConstraints(maxWidth: 560),
    sheetAnimationStyle: AnimationStyle(
      duration: m3Duration,
      reverseDuration: m3Small,
      curve: m3CurveIn,
      reverseCurve: m3CurveOut,
    ),
    builder: builder,
  );
}

/// 带弹跳缩放的勾选/状态图标。
class PopIcon extends StatelessWidget {
  const PopIcon({
    super.key,
    required this.icon,
    required this.color,
    this.size = 20,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: m3Duration,
      curve: Curves.elasticOut,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Icon(icon, size: size, color: color),
    );
  }
}
