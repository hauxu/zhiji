import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../theme.dart';
import '../util/dates.dart';
import 'burn_effect.dart';
import 'celebration.dart';
import 'm3_dialog.dart';
import 'magnet_reorder.dart';
import 'slide_action.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 任务行：右滑星标+归档，左滑删除。
class TaskRow extends StatefulWidget {
  TaskRow({
    required this.task,
    required this.day,
    required this.index,
    this.scope = 'day',
    this.onTap,
    this.trailing,
    this.selfActions = false,
  }) : super(key: keyFor(scope, day, task.id));

  /// 稳定 GlobalKey：重排时保留动画状态。
  static final Map<String, GlobalKey<TaskRowState>> _keys = {};
  static GlobalKey<TaskRowState> keyFor(
    String scope,
    DateTime day,
    String taskId,
  ) => _keys.putIfAbsent(
    '$scope-${dateKey(day)}-$taskId',
    () => GlobalKey<TaskRowState>(),
  );

  final PlanTask task;
  final DateTime day;
  final int index;
  final String scope;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// 磁贴组外行的操作胶囊。
  final bool selfActions;

  @override
  TaskRowState createState() => TaskRowState();
}

class TaskRowState extends State<TaskRow> with TickerProviderStateMixin {
  late final AnimationController _starCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final AnimationController _burnCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );
  late final AnimationController _archiveCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );
  late final AnimationController _moveCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final SlidableController _slideCtrl = SlidableController(this);

  bool _leaving = false; // 燃烧/归档动画播放中，屏蔽交互与重复触发
  int _lastIndex = -1;
  late final String _cacheKey =
      '${widget.scope}-${dateKey(widget.day)}-${widget.task.id}';

  @override
  void didUpdateWidget(covariant TaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 任务或位置变化时驱动动画。
    if (widget.task.id != oldWidget.task.id) {
      _leaving = false;
      _starCtrl.reset();
      _burnCtrl.reset();
      _archiveCtrl.reset();
      _moveCtrl.reset();
      _lastIndex = widget.index;
      return;
    }
    final starredNow = widget.task.starred && !oldWidget.task.starred;
    final moved = widget.index != _lastIndex;
    _lastIndex = widget.index;
    if (starredNow && moved && widget.index == 0) {
      _moveCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    TaskRow._keys.remove(_cacheKey);
    _starCtrl.dispose();
    _burnCtrl.dispose();
    _archiveCtrl.dispose();
    _moveCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  void _toggleStar(AppStore store) {
    final nowStarred = !widget.task.starred;
    store.setTaskStarred(widget.task.id, nowStarred);
    if (nowStarred) {
      HapticFeedback.mediumImpact();
      _starCtrl.forward(from: 0);
    } else {
      HapticFeedback.lightImpact();
    }
  }

  // ---- 长按操作胶囊入口 ----

  void editViaMenu() => widget.onTap?.call();

  void starViaMenu() {
    _slideCtrl.close();
    _toggleStar(context.read<AppStore>());
  }

  void moveToTodayViaMenu() {
    final store = context.read<AppStore>();
    store.moveTask(widget.task.id, dateKey(today()));
  }

  void archiveViaMenu() => _doArchive(context.read<AppStore>());

  void deleteViaMenu() => _confirmDelete(context);

  List<MagnetAction> _doneRowActions(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      MagnetAction(
        icon: Icons.check_circle_outline_rounded,
        label: '取消完成',
        onTap: () => _undoDone(context),
      ),
      MagnetAction(
        icon: Icons.local_fire_department_rounded,
        label: '删除',
        color: scheme.error,
        onTap: () => _confirmDelete(context),
      ),
    ];
  }

  Offset? _lastPress; // 指针按下位置，长按胶囊在其附近弹出

  void _showDoneRowPillAt(Offset globalPosition) {
    showActionsPill(context, globalPosition, _doneRowActions(context));
  }

  void _undoDone(BuildContext context) {
    if (_leaving) return;
    final store = context.read<AppStore>();
    store.setTaskDoneOn(widget.task, widget.day, false);
    Celebration.light();
  }

  Future<void> _doDelete(AppStore store) async {
    if (_leaving) return;
    _leaving = true;
    HapticFeedback.lightImpact();
    try {
      await _burnCtrl.forward().orCancel;
    } catch (_) {
      // 中断时直接落库。
    }
    store.deleteTask(widget.task.id);
    if (mounted) {}
  }

  Future<void> _doArchive(AppStore store) async {
    if (_leaving) return;
    _leaving = true;
    HapticFeedback.lightImpact();
    try {
      await _archiveCtrl.forward().orCancel;
    } catch (_) {
      // 中断时直接落库。
    }
    store.archiveTask(widget.task.id, true);
    if (mounted) {}
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final task = widget.task;
    final done = task.isDoneOn(widget.day);

    final tile = Listener(
      onPointerDown: (e) => _lastPress = e.position,
      child: InkWell(
        onTap: _leaving ? null : widget.onTap,
        onLongPress: _leaving || !widget.selfActions
            ? null
            : () => _showDoneRowPillAt(_lastPress ?? Offset.zero),
        onSecondaryTapUp: _leaving || !widget.selfActions
            ? null
            : (d) => _showDoneRowPillAt(d.globalPosition),
        // 长按由外层磁贴组接管。
        child: AnimatedBuilder(
          animation: _slideCtrl.animation,
          builder: (context, child) {
            final slide = _slideCtrl.animation.value.clamp(0.0, 1.0);
            final radius = lerpDouble(0, 14, slide)!;
            // 闲置：无底色直角铺满；滑动时圆角底浮现。
            Color? bg;
            if (slide > 0) {
              bg = scheme.surfaceContainerHigh.withValues(alpha: slide);
            } else if (task.starred) {
              bg = scheme.secondaryContainer.withValues(alpha: 0.55);
            }
            return Container(
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(radius),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: child,
            );
          },
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: Checkbox(
                  value: done,
                  onChanged: _leaving
                      ? null
                      : (v) {
                          final nowDone = v ?? false;
                          store.setTaskDoneOn(task, widget.day, nowDone);
                          if (nowDone) {
                            Celebration.complete(context);
                            // 3 秒内可撤销打勾；清掉排队旧提示保证准时消失。
                            showTopToast(
                              '「${task.title}」已完成',
                              actionLabel: '取消打勾',
                              onAction: () =>
                                  store.setTaskDoneOn(task, widget.day, false),
                            );
                            // 仅勾选当天任务且当天全部完成时提示。
                            if (dateKey(widget.day) == dateKey(today()) &&
                                store.allTodayDone()) {}
                          } else {
                            Celebration.light();
                          }
                        },
                ),
              ),
              const SizedBox(width: 2),
              if (task.isRecurring)
                Icon(
                  Icons.repeat_rounded,
                  size: 13,
                  color: scheme.onSurfaceVariant,
                ),
              AnimatedSwitcher(
                duration: m3Small,
                switchInCurve: m3CurveIn,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) {
                  // 星标入场：弹性缩放旋转。
                  final scale = Tween(begin: 0.3, end: 1.0).animate(
                    CurvedAnimation(parent: anim, curve: Curves.elasticOut),
                  );
                  final rot = Tween(begin: -0.6, end: 0.0).animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                  );
                  return RotationTransition(
                    turns: rot,
                    child: ScaleTransition(scale: scale, child: child),
                  );
                },
                child: task.starred
                    ? Icon(
                        Icons.star_rounded,
                        key: const ValueKey('star-on'),
                        size: 17,
                        color: scheme.secondary,
                      )
                    : const SizedBox.shrink(key: ValueKey('star-off')),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AnimatedBuilder(
                  animation: _starCtrl,
                  builder: (context, title) {
                    // 星标染色交互：文字随染色推进渐染主题色。
                    final base = done
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface;
                    final animating = _starCtrl.isAnimating;
                    final starT = animating
                        ? Curves.easeOut.transform(_starCtrl.value)
                        : (task.starred ? 1.0 : 0.0);
                    final tinted = Color.lerp(
                      base,
                      scheme.secondary,
                      0.6 * starT,
                    )!;
                    return AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.35,
                        color: tinted,
                        decoration: done
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                      ),
                      child: Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
              if (task.timeLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                AnimatedBuilder(
                  animation: _starCtrl,
                  builder: (context, label) {
                    final animating = _starCtrl.isAnimating;
                    final starT = animating
                        ? Curves.easeOut.transform(_starCtrl.value)
                        : (task.starred ? 1.0 : 0.0);
                    return Text(
                      task.timeLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: Color.lerp(
                          scheme.onSurfaceVariant,
                          scheme.secondary,
                          0.35 * starT,
                        ),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    );
                  },
                ),
              ],
              ?widget.trailing,
            ],
          ),
        ),
      ),
    );

    // 燃烧动画层。
    Widget content = AnimatedBuilder(
      animation: _burnCtrl,
      builder: (context, child) {
        if (!_leaving || _burnCtrl.value == 0) return child!;
        return BurnEffect(t: _burnCtrl.value, child: child!);
      },
      child: tile,
    );

    // 归档动画层：纸张飞入左侧文件袋。
    content = AnimatedBuilder(
      animation: _archiveCtrl,
      builder: (context, child) {
        final raw = _archiveCtrl.value;
        if (raw == 0) return child!;
        final fade = raw < 0.72
            ? 1.0
            : 1 - ((raw - 0.72) / 0.28).clamp(0.0, 1.0);
        final dx = -Curves.easeOut.transform(raw) * 64;
        final tilt = -0.08 * sin(raw * pi); // 提起时微倾、入袋前回正
        final sx = 1 - 0.12 * Curves.easeIn.transform(raw);
        final sy = 1 - 0.22 * Curves.easeIn.transform(raw);
        final paper = Opacity(
          opacity: fade,
          child: Transform.translate(
            offset: Offset(dx, -6 * sin(raw * pi)),
            child: Transform(
              alignment: Alignment.centerRight,
              transform: Matrix4.identity()
                ..rotateZ(tilt)
                ..scaleByDouble(sx, sy, 1, 1),
              child: child,
            ),
          ),
        );
        // 袋口前壁：从左缘生长。
        return Stack(
          children: [
            paper,
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _FolderMouthPainter(
                    t: raw,
                    fill: scheme.tertiaryContainer,
                    edge: scheme.tertiary,
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: content,
    );

    // 星标染色扩散层。
    content = AnimatedBuilder(
      animation: _starCtrl,
      builder: (context, child) {
        if (_starCtrl.value == 0 || _starCtrl.value == 1) return child!;
        return CustomPaint(
          foregroundPainter: _StarTintPainter(
            t: _starCtrl.value,
            color: scheme.secondaryContainer,
            accent: scheme.secondary,
          ),
          child: child,
        );
      },
      child: content,
    );

    // 星标落位动画层：置顶后轻微下滑落定。
    content = AnimatedBuilder(
      animation: _moveCtrl,
      builder: (context, child) {
        if (_moveCtrl.value == 0) return child!;
        final t = Curves.easeOutCubic.transform(_moveCtrl.value);
        return Transform.translate(
          offset: Offset(0, 18 * (1 - t)),
          child: child,
        );
      },
      child: content,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Slidable(
        key: ValueKey('task-${task.id}-${dateKey(widget.day)}'),
        controller: _slideCtrl,
        groupTag: 'goalday',
        startActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.36,
          children: [
            M3SlideAction(
              onTap: () {
                _toggleStar(store);
                // 星标后收起面板。
                _slideCtrl.close();
              },
              color: task.starred
                  ? scheme.secondary
                  : scheme.secondaryContainer,
              iconColor: task.starred
                  ? scheme.onSecondary
                  : scheme.onSecondaryContainer,
              icon: task.starred
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              label: task.starred ? '已置顶' : '星标',
            ),
            M3SlideAction(
              onTap: () => _doArchive(store),
              color: scheme.tertiaryContainer,
              iconColor: scheme.onTertiaryContainer,
              icon: Icons.archive_outlined,
              label: '归档',
            ),
          ],
        ),
        endActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.22,
          children: [
            M3SlideAction(
              onTap: () => _confirmDelete(context),
              color: scheme.errorContainer,
              iconColor: scheme.onErrorContainer,
              icon: Icons.local_fire_department_rounded,
              label: '删除',
            ),
          ],
        ),
        child: content,
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    final store = context.read<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    showM3Dialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('烧掉这个任务？'),
        content: Text('删除后无法恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _doDelete(store);
            },
            child: const Text('烧掉'),
          ),
        ],
      ),
    );
  }
}

class _StarTintPainter extends CustomPainter {
  _StarTintPainter({
    required this.t,
    required this.color,
    required this.accent,
  });

  final double t;
  final Color color;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = const Alignment(
      -1.0,
      0.0,
    ).withinRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final maxR = sqrt(pow(size.width, 2) + pow(size.height / 2, 2));
    final r = maxR * Curves.easeOutCubic.transform(t);
    // 染色随扩散推进回落到常驻强度。
    final alpha = lerpDouble(0.85, 0.45, t)!;
    final rect = Rect.fromCircle(center: center, radius: r);
    // 染色全幅直角铺满。
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: alpha * 0.9),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.72, 1],
        ).createShader(rect)
        ..isAntiAlias = true,
    );
    // 扩散前沿的细亮环。
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = accent.withValues(alpha: (1 - t) * 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _StarTintPainter old) => old.t != t;
}

/// 归档袋口前壁，盖住向左滑入的纸张。
class _FolderMouthPainter extends CustomPainter {
  _FolderMouthPainter({
    required this.t,
    required this.fill,
    required this.edge,
  });

  final double t;
  final Color fill;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    final w = size.width;
    final h = size.height;
    final growth = Curves.easeOut.transform(t.clamp(0.0, 1.0));
    final mouthW = w * 0.62 * growth;
    if (mouthW < 2) return;

    // 前壁：左实右渐隐。
    final rect = Rect.fromLTWH(0, 0, mouthW, h);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            fill.withValues(alpha: 0.96),
            fill.withValues(alpha: 0.88),
            fill.withValues(alpha: 0.55),
          ],
          stops: const [0, 0.78, 1],
        ).createShader(rect),
    );

    // 前缘亮线：袋口的翻边。
    canvas.drawLine(
      Offset(mouthW, 0),
      Offset(mouthW, h),
      Paint()
        ..color = edge.withValues(alpha: 0.85)
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(mouthW - 5, 0),
      Offset(mouthW - 5, h),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..strokeWidth = 1,
    );

    // 顶口阴影：袋口开合处的压痕。
    canvas.drawRect(
      Rect.fromLTWH(0, 0, mouthW, 3),
      Paint()..color = Colors.black.withValues(alpha: 0.14 * (1 - t)),
    );
  }

  @override
  bool shouldRepaint(covariant _FolderMouthPainter old) =>
      old.t != t || old.fill != fill;
}
