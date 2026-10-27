import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Material 3 Expressive 波浪进度条：主波 + 相位滞后的回声波，
/// 两端 smoothstep 收尾；value 为 null 时为不定态扫动。
class M3EWavyProgress extends StatefulWidget {
  const M3EWavyProgress({
    super.key,
    this.value,
    this.height = 8,
    this.color,
    this.trackColor,
  });

  /// 0..1；null 表示不定态。
  final double? value;

  final double height;

  final Color? color;
  final Color? trackColor;

  @override
  State<M3EWavyProgress> createState() => _M3EWavyProgressState();
}

class _M3EWavyProgressState extends State<M3EWavyProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _driver = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// 自累加相位 0..1，速度随能量加快。
  double _phase = 0;

  /// 呼吸相位：约 3s 一轮。
  double _breath = 0;

  /// 能量：value 变化置 1，随时间衰减。
  double _energy = 1;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _driver.addListener(_onTick);
    _driver.repeat();
  }

  void _onTick() {
    final now = _driver.lastElapsedDuration ?? Duration.zero;
    var dt = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    if (dt <= 0) return; // repeat() 环回时 elapsed 归零，丢弃负帧
    // 相位推进：静止 1.6s/周。
    _phase =
        (_phase + dt / 1.6 * (1 + 1.2 * Curves.easeOut.transform(_energy))) %
        1.0;
    _breath = (_breath + dt / 3.0) % 1.0;
    if (_energy > 0) {
      _energy = math.max(0.0, _energy - dt / 0.9); // ~0.9s 回落到静止幅
    }
  }

  @override
  void didUpdateWidget(covariant M3EWavyProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _energy = 1;
  }

  @override
  void dispose() {
    _driver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.value == null
          ? '加载中'
          : '进度 ${(widget.value! * 100).round()}%',
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: (widget.value ?? 0).clamp(0.0, 1.0)),
        duration: m3Small,
        curve: m3CurveIn,
        builder: (_, v, _) => AnimatedBuilder(
          animation: _driver,
          builder: (_, _) => CustomPaint(
            size: Size.fromHeight(widget.height),
            painter: _WavyPainter(
              value: widget.value == null ? null : v,
              phase: _phase,
              breath: _breath,
              energy: Curves.easeOutCubic.transform(_energy),
              color: widget.color ?? scheme.primary,
              // M3 中性轨道：onSurface 12%。
              trackColor:
                  widget.trackColor ?? scheme.onSurface.withValues(alpha: 0.12),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({
    required this.value,
    required this.phase,
    required this.breath,
    required this.energy,
    required this.color,
    required this.trackColor,
  });

  final double? value;
  final double phase;
  final double breath;
  final double energy;
  final Color color;
  final Color trackColor;
  double x0w = 0;
  double x1w = 0;

  // ---- 几何（比例相对轨道高 h）----
  // 描边 0.50h；摆幅静止 0.10h / 活跃 0.25h，峰顶恰贴轨道边缘。
  static const double _idleAmpRatio = 0.10;
  static const double _fullAmpRatio = 0.25;
  static const double _strokeRatio = 0.50;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final mid = h / 2;
    final stroke = h * _strokeRatio;

    // 呼吸调制：0.88..1.00 慢速正弦。
    final breathe = 0.88 + 0.12 * math.sin(2 * math.pi * breath);
    final amp =
        h *
        (_idleAmpRatio + (_fullAmpRatio - _idleAmpRatio) * energy) *
        breathe;
    // 波长随高度自适应。
    final wavelength = math.max(10.0, h * 2.2);

    double x0, x1;
    final indeterminate = value == null;
    if (indeterminate) {
      const seg = 90.0;
      final eased = Curves.easeInOut.transform(phase);
      x1 = -seg + (w + 2 * seg) * eased;
      x0 = x1 - seg;
    } else {
      x0 = 0;
      x1 = w * value!.clamp(0.0, 1.0);
    }
    x0w = x0;
    x1w = x1;

    // 端部 smoothstep 包络：振幅向中线收敛。
    double env(double x) {
      const fadeScale = 0.5;
      var k = 1.0;
      final head = (x - x0w) / (wavelength * fadeScale);
      if (head < 1) k = head;
      final tail = (x1w - x) / (wavelength * fadeScale);
      if (tail < 1) k = math.min(k, tail);
      k = k.clamp(0.0, 1.0);
      return k * k * (3 - 2 * k);
    }

    // y(x)：包络 × 正弦，主波与回声波共用。
    double waveY(double x, double a, double ph) =>
        mid +
        a *
            env(x) *
            math.sin(2 * math.pi * (x / wavelength) - 2 * math.pi * ph);

    Path waveSegment(double from, double to, double a, double ph) {
      final path = Path()..moveTo(from, waveY(from, a, ph));
      for (var x = from; x <= to; x += 1.2) {
        path.lineTo(x, waveY(x, a, ph));
      }
      path.lineTo(to, waveY(to, a, ph));
      return path;
    }

    Paint strokePaint(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (indeterminate) {
      // 不定态：回声波 + 主波扫动。
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      if (x1 - x0 >= stroke) {
        canvas.drawPath(
          waveSegment(x0 - 10, x1 - 10, amp * 0.72, phase + 0.16),
          strokePaint(color.withValues(alpha: 0.25)),
        );
        canvas.drawPath(waveSegment(x0, x1, amp, phase), strokePaint(color));
      }
      canvas.restore();
      return;
    }

    // 确定态：回声波垫底，主波在上。
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(h / 2)),
    );
    if (x1 >= stroke * 0.5) {
      canvas.drawPath(
        waveSegment(0, x1, amp * 0.72, phase + 0.16),
        strokePaint(color.withValues(alpha: 0.25)),
      );
      canvas.drawPath(waveSegment(0, x1, amp, phase), strokePaint(color));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WavyPainter old) =>
      old.value != value ||
      old.phase != phase ||
      old.breath != breath ||
      old.energy != energy ||
      old.color != color ||
      old.trackColor != trackColor;
}
