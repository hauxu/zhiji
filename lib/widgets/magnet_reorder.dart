import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';

import '../theme.dart';

class MagnetAction {
  const MagnetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
}

/// 磁贴式长按交互组：长按弹操作胶囊，拖动磁吸排序，松手回调 onReorder
/// （索引相对 children 当前顺序）。children 必须带稳定 Key。
///
/// 拖动观感由根层代理呈现（RepaintBoundary 截图跟随手指），
/// 原位是等高占位块——不存在 Z 序重叠，也不会拖出列表范围。
class MagnetReorder extends StatefulWidget {
  const MagnetReorder({
    super.key,
    required this.children,
    required this.actions,
    required this.onReorder,
    this.enabled = true,
  });

  final List<Widget> children;
  final List<MagnetAction> Function(int index) actions;
  final void Function(int from, int to) onReorder;
  final bool enabled;

  @override
  State<MagnetReorder> createState() => _MagnetReorderState();
}

class _MagnetReorderState extends State<MagnetReorder>
    with TickerProviderStateMixin {
  final Map<int, GlobalKey> _tileKeys = {};
  final Map<int, GlobalKey> _boundaryKeys = {};

  int? _dragIndex;
  int? _targetIndex;
  double _dragDy = 0;
  double _dragDyMin = 0;
  double _dragDyMax = 0;
  Rect _dragRect = Rect.zero;
  List<double> _mids = const [];
  List<double> _heights = const [];
  List<double> _tops = const [];

  ui.Image? _proxyImage;
  OverlayEntry? _dragEntry;
  AnimationController? _dropCtrl;

  // 长按已弹出操作条、但尚未进入拖动
  int? _pillIndex;
  OverlayEntry? _pillEntry;

  AnimationController? _settleCtrl;
  int? _settleIndex;
  int? _lastAnnouncedTarget;

  GlobalKey _keyFor(int i) => _tileKeys.putIfAbsent(i, GlobalKey.new);
  GlobalKey _boundaryFor(int i) => _boundaryKeys.putIfAbsent(i, GlobalKey.new);

  Rect? _rectOf(int i) {
    final ctx = _keyFor(i).currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  // ---------- 状态清理 ----------

  /// 清空拖动/代理/胶囊/落位全部状态（不触发重建）。
  void _clearDragFields() {
    _dragIndex = null;
    _targetIndex = null;
    _lastAnnouncedTarget = null;
    _pillIndex = null;
    _settleIndex = null;
    _removePill();
    _removeDragEntry();
    final settle = _settleCtrl;
    _settleCtrl = null;
    settle?.dispose();
    final drop = _dropCtrl;
    _dropCtrl = null;
    drop?.dispose();
  }

  void _resetDragState() {
    _clearDragFields();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MagnetReorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 条目增删后索引失配：立即复位，防止磁贴悬空与整组锁死。
    if (widget.children.length != oldWidget.children.length) {
      _tileKeys.clear();
      _boundaryKeys.clear();
      if (_dragIndex != null || _pillEntry != null || _settleCtrl != null) {
        _resetDragState();
      }
    }
  }

  @override
  void dispose() {
    _clearDragFields();
    super.dispose();
  }

  // ---------- 长按操作胶囊 ----------

  void _showPill(int index, Offset globalTapPosition) {
    _removePill();
    final actions = widget.actions(index);
    if (actions.isEmpty) return;
    _pillIndex = index;
    final scheme = Theme.of(context).colorScheme;
    final entry = OverlayEntry(
      builder: (overlayContext) {
        // 每次覆盖层重建时实时取动作，避免闭包指向已变更的条目。
        final liveActions = widget.actions(index);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _removePill,
                onPanStart: (_) => _removePill(),
                child: const SizedBox.expand(),
              ),
            ),
            if (liveActions.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                top: math.max(12, globalTapPosition.dy - 108),
                child: _Pill(
                  actions: liveActions,
                  scheme: scheme,
                  onAction: (action) {
                    _removePill();
                    action.onTap();
                  },
                ),
              ),
          ],
        );
      },
    );
    _pillEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    HapticFeedback.selectionClick();
  }

  void _removePill() {
    _pillEntry?.remove();
    _pillEntry = null;
    _pillIndex = null;
  }

  // ---------- 磁贴拖动 ----------

  void _onLongPressStart(int index, LongPressStartDetails d) {
    if (_dragIndex != null) return;
    _showPillForTap(index, d.globalPosition);
  }

  /// 右键/长按共用的胶囊入口。
  void _showPillForTap(int index, Offset globalTapPosition) {
    _showPill(index, globalTapPosition);
  }

  void _onLongPressMoveUpdate(int index, LongPressMoveUpdateDetails d) {
    if (_pillIndex == index && _dragIndex == null) {
      if (d.offsetFromOrigin.distance < 18) return;
      // 从操作条态切到拖动态
      _removePill();
      _beginDrag(index, d.globalPosition);
      return;
    }
    if (_dragIndex == index) _updateDrag(d.globalPosition);
  }

  void _beginDrag(int index, Offset globalPosition) {
    final n = widget.children.length;
    final rect = _rectOf(index);
    if (rect == null || n < 2) {
      _removePill();
      return;
    }
    final mids = <double>[];
    final heights = <double>[];
    final tops = <double>[];
    for (var i = 0; i < n; i++) {
      final r = _rectOf(i);
      if (r == null) {
        // 兄弟几何不可用（键未挂载/被重建）：放弃本次拖动。
        return;
      }
      mids.add(r.center.dy);
      heights.add(r.height);
      tops.add(r.top);
    }
    // 落地上一次可能的回弹动画，避免残留控制器干扰。
    final oldSettle = _settleCtrl;
    _settleCtrl = null;
    oldSettle?.dispose();
    // 可拖范围：中心不越过首尾中线太多，磁贴不会飘出列表。
    final h = rect.height;
    _dragDyMin = mids.first - h * 0.55 - rect.center.dy;
    _dragDyMax = mids.last + h * 0.55 - rect.center.dy;
    setState(() {
      _dragIndex = index;
      _targetIndex = index;
      _dragDy = 0;
    });
    _dragRect = rect;
    _mids = mids;
    _heights = heights;
    _tops = tops;
    _dragStartPointerY = globalPosition.dy;
    _dragStartCenterY = rect.center.dy;
    HapticFeedback.mediumImpact();
    _captureProxy(index);
  }

  double _dragStartPointerY = 0;
  double _dragStartCenterY = 0;

  Future<void> _captureProxy(int index) async {
    try {
      final ctx = _boundaryFor(index).currentContext;
      if (ctx == null) return;
      final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final image = await boundary.toImage(pixelRatio: dpr);
      if (!mounted || _dragIndex != index) {
        image.dispose();
        return;
      }
      _proxyImage = image;
      if (mounted) setState(() {}); // 原位切占位，代理同时出现
      _insertDragEntry();
    } catch (_) {
      // 截图失败时本次拖动没有代理视觉，占位与排序逻辑照常。
    }
  }

  void _insertDragEntry() {
    if (_dragEntry != null || !mounted) return;
    final entry = OverlayEntry(builder: (_) => _buildProxy());
    _dragEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _removeDragEntry() {
    _dragEntry?.remove();
    _dragEntry = null;
    _proxyImage?.dispose();
    _proxyImage = null;
  }

  Widget _buildProxy() {
    final image = _proxyImage;
    if (image == null) return const SizedBox.shrink();
    return Positioned(
      left: _dragRect.left,
      top: _dragRect.top,
      width: _dragRect.width,
      height: _dragRect.height,
      child: Transform.translate(
        offset: Offset(0, _dragDy),
        child: _Lifted(
          child: RawImage(
            image: image,
            width: _dragRect.width,
            height: _dragRect.height,
            fit: BoxFit.fill,
          ),
        ),
      ),
    );
  }

  void _updateDrag(Offset globalPosition) {
    if (_dragIndex == null) return;
    final n = widget.children.length;
    final dragIndex = _dragIndex!;
    var dy = globalPosition.dy - _dragStartPointerY;
    dy = dy.clamp(_dragDyMin, _dragDyMax);
    final center = _dragStartCenterY + dy;

    // 目标插入位 = 其余磁贴中线在移动中心上方的个数。
    var target = 0;
    for (var j = 0; j < n; j++) {
      if (j == dragIndex) continue;
      if (center > _mids[j]) target++;
    }

    setState(() {
      _dragDy = dy;
      _targetIndex = target;
    });
    _dragEntry?.markNeedsBuild();
    if (target != _lastAnnouncedTarget) {
      _lastAnnouncedTarget = target;
      HapticFeedback.selectionClick(); // 让位经过时轻咔哒
    }
  }

  void _onLongPressEnd(int index, LongPressEndDetails d) {
    if (_dragIndex != index) {
      // 列表在拖动中变化会使 index 失效，复位防悬空。
      if (_dragIndex != null) _resetDragState();
      return;
    }
    final from = _dragIndex!;
    final to = (_targetIndex ?? from).clamp(0, widget.children.length - 1);
    if (from == to) {
      // 未发生换位：撤代理还原。
      _resetDragState();
      return;
    }
    _dragIndex = null;
    _targetIndex = null;
    _lastAnnouncedTarget = null;
    // 落点补间：代理滑向目标槽位，到位后再提交重排。
    final startDy = _dragDy;
    final targetDy = _tops[to] - _tops[from];
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    ctrl.addListener(() {
      // 补间直接写 _dragDy：代理 builder 每次读的就是它。
      final t = Curves.easeOut.transform(ctrl.value);
      _dragDy = startDy + (targetDy - startDy) * t;
      _dragEntry?.markNeedsBuild();
    });
    final oldDrop = _dropCtrl;
    _dropCtrl = ctrl;
    oldDrop?.dispose();
    ctrl.forward().whenCompleteOrCancel(() {
      if (!identical(_dropCtrl, ctrl)) return;
      _dropCtrl = null;
      ctrl.dispose();
      _commitDrop(from, to);
    });
  }

  void _commitDrop(int from, int to) {
    HapticFeedback.heavyImpact();
    // 先撤代理并还原原位，再提交重排，避免双帧错位。
    _removeDragEntry();
    setState(() {
      _dragIndex = null;
      _dragDy = 0;
    });
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    final oldSettle = _settleCtrl;
    _settleCtrl = ctrl;
    oldSettle?.dispose();
    setState(() => _settleIndex = to);
    ctrl.forward().whenCompleteOrCancel(() {
      // 已被新一次拖动接管（旧控制器被销毁触发本回调）时不再动作。
      if (!identical(_settleCtrl, ctrl)) return;
      if (mounted) setState(() => _settleIndex = null);
      ctrl.dispose();
      _settleCtrl = null;
    });
    widget.onReorder(from, to);
  }

  double _displacementFor(int i) {
    final dragIndex = _dragIndex;
    final target = _targetIndex;
    if (dragIndex == null || target == null || i == dragIndex) return 0;
    final h = _heights.isEmpty ? 0.0 : _heights[dragIndex];
    if (dragIndex < target && i > dragIndex && i <= target) return -h;
    if (target < dragIndex && i >= target && i < dragIndex) return h;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      _tileKeys.clear();
      _boundaryKeys.clear();
      if (_dragIndex != null || _pillEntry != null) {
        // build 期间只清字段，不 setState。
        _dragIndex = null;
        _targetIndex = null;
        _lastAnnouncedTarget = null;
        _pillIndex = null;
        _removePill();
      }
      return Column(children: widget.children);
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var i = 0; i < widget.children.length; i++) _buildTile(i, scheme),
      ],
    );
  }

  Widget _buildTile(int i, ColorScheme scheme) {
    final isDragged = _dragIndex == i;
    final dy = _displacementFor(i);
    final settling = _settleIndex == i && _settleCtrl != null;

    Widget tile = KeyedSubtree(
      key: _keyFor(i),
      child: GestureDetector(
        // 磁贴空白处右键也可触发。
        behavior: HitTestBehavior.translucent,
        onLongPressStart: widget.enabled
            ? (d) => _onLongPressStart(i, d)
            : null,
        onLongPressMoveUpdate: widget.enabled
            ? (d) => _onLongPressMoveUpdate(i, d)
            : null,
        onLongPressEnd: widget.enabled ? (d) => _onLongPressEnd(i, d) : null,
        onLongPressCancel: () {
          // 系统手势打断：完整复位，避免磁贴悬空或整组卡死。
          if (_dragIndex != null || _pillEntry != null) _resetDragState();
        },
        // 桌面右键等同长按，弹出同一条操作胶囊
        onSecondaryTapUp: widget.enabled
            ? (d) => _showPillForTap(i, d.globalPosition)
            : null,
        child: isDragged && _proxyImage != null
            // 拖动中的原位是等高占位（识别器必须保持挂载，
            // 否则手势随元素销毁、移动/抬手事件全部断流）。
            ? SizedBox(height: _heights.isEmpty ? 0.0 : _heights[i])
            : RepaintBoundary(key: _boundaryFor(i), child: widget.children[i]),
      ),
    );

    if (_dragIndex != null && !isDragged) {
      // 拖动期间让位补间常驻，回位同样平滑不再瞬跳。
      tile = TweenAnimationBuilder<double>(
        tween: Tween(end: dy),
        duration: m3Small,
        curve: m3CurveIn,
        builder: (_, v, child) =>
            Transform.translate(offset: Offset(0, v), child: child),
        child: tile,
      );
    }

    if (settling) {
      // 磁吸落位：微放大后弹性缩回，配合重触感
      final t = _settleCtrl!.value;
      final scale = 1.0 + 0.08 * (1 - Curves.easeOut.transform(t));
      final wobble = 1.0 + 0.03 * math.sin(t * math.pi * 3) * (1 - t); // 渐消弹簧
      tile = Transform.scale(scale: scale * wobble, child: tile);
    }

    return tile;
  }
}

/// 取下态的外观：圆角投影卡片。
class _Lifted extends StatelessWidget {
  const _Lifted({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 1.05,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).colorScheme.shadow
                  .withValues(alpha: 0.28),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

/// 非模态操作胶囊条
class _Pill extends StatelessWidget {
  const _Pill({
    required this.actions,
    required this.scheme,
    required this.onAction,
  });

  final List<MagnetAction> actions;
  final ColorScheme scheme;
  final void Function(MagnetAction action) onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      shadowColor: scheme.shadow.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final action in actions)
              InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () => onAction(action),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        action.icon,
                        size: 20,
                        color: action.color ?? scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        action.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: action.color ?? scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 未接入拖拽组的行的长按/右键胶囊。
void showActionsPill(
  BuildContext context,
  Offset globalTapPosition,
  List<MagnetAction> actions,
) {
  if (actions.isEmpty) return;
  final scheme = Theme.of(context).colorScheme;
  OverlayEntry? entry;
  void close() {
    entry?.remove();
    entry = null;
  }

  final created = OverlayEntry(
    builder: (overlayContext) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: close,
            onPanStart: (_) => close(),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          top: math.max(12, globalTapPosition.dy - 108),
          child: Material(
            color: scheme.surfaceContainerHigh,
            elevation: 6,
            shadowColor: scheme.shadow.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(28),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final action in actions)
                    InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: () {
                        close();
                        // 页面可能已在胶囊存活期间被关闭。
                        if (!context.mounted) return;
                        action.onTap();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              action.icon,
                              size: 20,
                              color: action.color ?? scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              action.label,
                              style: TextStyle(
                                fontSize: 11,
                                color: action.color ?? scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
  entry = created;
  Overlay.of(context, rootOverlay: true).insert(created);
  HapticFeedback.selectionClick();
}
