import 'dart:math';

import 'package:flutter/material.dart';

/// 纸张燃烧：前锋从右向左推进，前锋右侧已烧穿消失，
/// 焦黑带随前锋移动。[t] 取 0..1。
class BurnEffect extends StatelessWidget {
  const BurnEffect({super.key, required this.t, required this.child});

  final double t;
  final Widget? child;

  /// 前锋位置（物理像素，从右侧起算）：t=0 在右缘外，t=1 越过左缘。
  static double frontX(double t, double width) {
    // t=0 在右缘外、t=1 越过左缘，焦黑带完全扫过整行。
    final curved = Curves.easeInOutCubic.transform(t.clamp(0.0, 1.0));
    return width + 18 - curved * (width + 48);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final front = frontX(t, w);
        // 焦黑过渡带：前锋左侧渐透明。
        const band = 26.0;
        final fs = ((front - band) / w).clamp(0.0, 1.0);
        final fe = ((front + 2) / w).clamp(0.0, 1.0);

        return Stack(
          children: [
            ShaderMask(
              shaderCallback: (bounds) {
                // dstOut：alpha 高处被擦除。
                return LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: const [
                    Color(0x00000000),
                    Color(0x00000000),
                    Color(0x60000000),
                    Colors.black,
                    Colors.black,
                  ],
                  stops: [0.0, fs, fs + (fe - fs) * 0.45, fe, 1.0],
                ).createShader(bounds);
              },
              blendMode: BlendMode.dstOut,
              child: child,
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _BurnFrontPainter(t: t, front: front, w: w),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 燃烧前锋：波浪焦黑线 + 灼热光带 + 飞散火星。
class _BurnFrontPainter extends CustomPainter {
  _BurnFrontPainter({required this.t, required this.front, required this.w});

  final double t;
  final double front;
  final double w;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1 || front < -8 || front > size.width + 8) return;
    final h = size.height;
    final rng = Random(42);

    // 波浪前锋路径：竖直方向带两级正弦抖动，模拟纸边燃烧的不规则。
    Path frontLine(double offset) {
      final path = Path()..moveTo(front + offset, -6);
      for (var y = 0.0; y <= h + 6; y += 7) {
        final wave = sin(y / 13 + t * 9) * 3.2 + sin(y / 29 - t * 5) * 2.4;
        path.lineTo(front + offset + wave, y);
      }
      return path;
    }

    // 灼热光带：向右渐散。
    final glowRect = Rect.fromLTWH(front - 30, 0, 74, h);
    canvas.drawRect(
      glowRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            const Color(0x00FF7A1A),
            const Color(0x59FF7A1A).withValues(alpha: (1 - t) * 0.55),
            const Color(0x00000000),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(glowRect),
    );

    // 焦黑碳化带：宽主缘 + 细亮内缘。
    canvas.drawPath(
      frontLine(0),
      Paint()
        ..color = const Color(0xE6261A10).withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7 + 3 * (1 - t)
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      frontLine(-4),
      Paint()
        ..color = const Color(0xFF8A5A2E).withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // 火星：沿前锋全高随机喷出，向上、向已烧区（右）飘散。
    final paint = Paint()..style = PaintingStyle.fill;
    final life = (1 - t).clamp(0.0, 1.0);
    for (var i = 0; i < 30; i++) {
      final y = rng.nextDouble() * h;
      final seedShift = rng.nextDouble() * 26 - 6;
      final flight = t * (26 + rng.nextDouble() * 80);
      final pos = Offset(
        front + seedShift + flight * (0.5 + rng.nextDouble() * 0.8),
        y - flight * (0.35 + rng.nextDouble() * 0.55),
      );
      if (pos.dy < -8 || pos.dx > size.width + 10) continue;
      paint.color = Color.lerp(
        const Color(0xFFFFC46B),
        const Color(0xFFE2571E),
        rng.nextDouble(),
      )!.withValues(alpha: life * 0.9);
      canvas.drawCircle(pos, 1.1 + rng.nextDouble() * 2.1 * life, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BurnFrontPainter old) =>
      old.t != t || old.front != front;
}
