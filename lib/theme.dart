import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// M3 Expressive 动效基线：时长阶梯 + emphasized 曲线对。
const Duration m3Small = Duration(milliseconds: 200);
const Duration m3Medium = Duration(milliseconds: 350);
const Duration m3Large = Duration(milliseconds: 500);
const Curve m3CurveIn =
    Cubic(0.05, 0.7, 0.1, 1.0); // M3E emphasizedDecelerate
const Curve m3CurveOut =
    Cubic(0.3, 0.0, 0.8, 0.15); // M3E emphasizedAccelerate

const Duration m3Duration = m3Medium;
const Curve m3Curve = Curves.easeInOutCubicEmphasized;

ButtonStyle errorFilledButtonStyle(ThemeData theme) {
  return FilledButton.styleFrom(
    backgroundColor: theme.colorScheme.error,
    foregroundColor: theme.colorScheme.onError,
  );
}

void m3HapticSelect() => HapticFeedback.selectionClick();

const Color kDefaultSeed = Color(0xFF3E6B4F); // 苔绿

/// 全局弹出提示时长。
const kSnackBarDuration = Duration(seconds: 3);

/// M3 主题：动态取色或传统色种子；仅传统色浅色模式做暖纸表面。
ThemeData buildGoalDayTheme({
  ColorScheme? dynamicScheme,
  Color seedColor = kDefaultSeed,
  bool dark = false,
}) {
  var scheme = dynamicScheme ??
      ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: dark ? Brightness.dark : Brightness.light);

  if (!dark && dynamicScheme == null) {
    // 传统色浅色：暖纸表面。
    scheme = scheme.copyWith(
      surface: const Color(0xFFFAF9F6),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFFDFBF6),
      surfaceContainer: const Color(0xFFF6F2E9),
      surfaceContainerHigh: const Color(0xFFF0EBE0),
      surfaceContainerHighest: const Color(0xFFE9E3D5),
      onSurface: const Color(0xFF1E251F),
      onSurfaceVariant: const Color(0xFF75705F),
      outline: const Color(0xFFC9C4B4),
      outlineVariant: const Color(0xFFE4E0D2),
    );
  }

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    // 桌面滚动条样式。
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.dragged) ? 8.0 : 5.0),
      thumbVisibility: const WidgetStatePropertyAll(true),
      radius: Radius.circular(999),
      crossAxisMargin: 3,
      mainAxisMargin: 4,
      thumbColor: WidgetStateProperty.resolveWith((states) => scheme
          .onSurface
          .withValues(alpha: states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? 0.45
              : 0.22)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: scheme.onSurface,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      side: BorderSide(color: scheme.outline, width: 2),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : Colors.transparent,
      ),
    ),
    // 选中态仅用着重色表达。
    chipTheme: ChipThemeData(
      showCheckmark: false,
      selectedColor: scheme.primaryContainer,
      backgroundColor: scheme.surfaceContainerHigh,
      checkmarkColor: Colors.transparent,
      labelPadding: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
      linearMinHeight: 8,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}
