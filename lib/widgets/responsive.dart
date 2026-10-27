import 'package:flutter/material.dart';

import '../ui/breakpoints.dart';

/// 单列页面的统一内容容器：宽屏下限制最大宽度并居中。
/// 手机宽度不足 maxWidth 时不改变任何布局。
class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    super.key,
    required this.child,
    this.maxWidth = Breakpoints.contentMaxWidth,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 关键：给子级「紧」宽度约束。若只用 maxWidth，Column/ListView 在
        // 手机窄屏上反而会收缩成内容宽度，改变原来的满宽布局。
        final width = constraints.maxWidth < maxWidth
            ? constraints.maxWidth
            : maxWidth;
        return Center(
          child: SizedBox(
            width: width,
            height: constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : null,
            child: Padding(padding: padding, child: child),
          ),
        );
      },
    );
  }
}

/// 桌面端常驻滚动条：宽屏窗口下纵向滚动条始终可见，手机维持系统默认。
///
/// Flutter 默认只在 Windows/macOS/Linux 用 Scrollbar 包裹滚动区，
/// 这里显式打开 thumb/track 可见性，并跳过横向滚动区（如筛选 Chips）。
class GoalDayScrollBehavior extends MaterialScrollBehavior {
  const GoalDayScrollBehavior();

  bool _desktop(BuildContext context) {
    return switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
  }

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (!_desktop(context) ||
        axisDirectionToAxis(details.direction) != Axis.vertical ||
        details.controller == null) {
      return super.buildScrollbar(context, child, details);
    }
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: true,
      trackVisibility: true,
      child: child,
    );
  }
}
