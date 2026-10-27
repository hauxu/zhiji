import 'package:flutter/widgets.dart';

/// 全局响应式断点：手机 compact，小窗 medium，桌面 expanded。
///
/// 只做布局判断，不承载任何业务逻辑；页面不要自己再写魔法数字。
enum BreakpointSize { compact, medium, expanded }

abstract final class Breakpoints {
  /// < 600：手机（保持现有安卓布局）。
  static const double compactMax = 600;

  /// 600–999：NavigationRail 折叠态（平板/窄窗口）。
  static const double mediumMin = compactMax;

  /// ≥ 1000：NavigationRail 展开态，允许列表+详情双栏。
  static const double expandedMin = 1000;

  /// 单列页面内容最大宽度：宽屏下居中，不横向拉满。
  static const double contentMaxWidth = 820;

  /// 双栏/多列页面外壳最大宽度。
  static const double wideContentMaxWidth = 1280;

  /// 宽屏 AlertDialog 最大宽度。
  static const double dialogMaxWidth = 520;

  /// 宽屏列表型弹层改成 Dialog 后的最大宽度。
  static const double sheetDialogMaxWidth = 640;

  static BreakpointSize classify(double width) {
    if (width < compactMax) return BreakpointSize.compact;
    if (width < expandedMin) return BreakpointSize.medium;
    return BreakpointSize.expanded;
  }

  static BreakpointSize of(BuildContext context) =>
      classify(MediaQuery.sizeOf(context).width);
}

/// 页面里常用的快捷判断：`context.isExpanded`。
extension BreakpointContext on BuildContext {
  BreakpointSize get breakpointSize => Breakpoints.of(this);

  bool get isCompact => breakpointSize == BreakpointSize.compact;

  bool get isMedium => breakpointSize == BreakpointSize.medium;

  bool get isExpanded => breakpointSize == BreakpointSize.expanded;
}
