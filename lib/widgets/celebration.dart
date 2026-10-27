import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 完成反馈：触觉 + 随机庆祝音效 + 随机庆祝动效（4 种）。
class Celebration {
  Celebration._();

  static final AudioPlayer _player = AudioPlayer();
  static bool _audioReady = false;
  static final Random _rng = Random();
  static const _sounds = [
    'sounds/chime.wav',
    'sounds/sparkle.wav',
    'sounds/pop.wav',
  ];

  static Future<void> preload() async {
    try {
      await _player.setPlayerMode(PlayerMode.lowLatency);
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setSourceAsset(_sounds.first);
      _audioReady = true;
    } catch (_) {
      _audioReady = false;
    }
  }

  static Future<void> _playRandomSound() async {
    if (!_audioReady) return;
    try {
      final name = _sounds[_rng.nextInt(_sounds.length)];
      await _player.stop();
      await _player.play(AssetSource(name));
    } catch (_) {}
  }

  static void complete(BuildContext context) {
    HapticFeedback.mediumImpact();
    _playRandomSound();
    _maybeConfetti(context);
  }

  static void light() {
    HapticFeedback.lightImpact();
  }

  static void _maybeConfetti(BuildContext context) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final entry = OverlayEntry(builder: (_) => const _ConfettiOverlay());
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 1900), entry.remove);
  }
}

enum _Effect { starBurst, confettiRain, doubleFirework, ripple }

enum _Shape { dot, rect, star }

/// 随机庆祝覆盖层：每次从 4 种效果中随机选择，颜色取自当前主题。
class _ConfettiOverlay extends StatefulWidget {
  const _ConfettiOverlay();

  @override
  State<_ConfettiOverlay> createState() => _ConfettiOverlayState();
}

class _ConfettiOverlayState extends State<_ConfettiOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final _Effect _effect;
  late final List<_Particle> _particles;
  late final List<_Ripple> _ripples;
  late final Offset _center;
  bool _tinted = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    final rng = Random();
    _effect = _Effect.values[rng.nextInt(_Effect.values.length)];
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screen = Size(
      view.physicalSize.width / view.devicePixelRatio,
      view.physicalSize.height / view.devicePixelRatio,
    );
    _center = Offset(
      screen.width * (0.35 + rng.nextDouble() * 0.3),
      screen.height * (0.3 + rng.nextDouble() * 0.18),
    );
    final fallback = Colors.primaries;
    Color pick() => fallback[rng.nextInt(fallback.length)];

    _particles = [];
    _ripples = [];
    switch (_effect) {
      case _Effect.starBurst:
        for (var i = 0; i < 30; i++) {
          _particles.add(
            _Particle(
              angle: (i / 30) * 2 * pi + rng.nextDouble() * 0.3,
              speed: 0.55 + rng.nextDouble() * 0.45,
              size: 5 + rng.nextDouble() * 8,
              color: pick(),
              shape: rng.nextBool() ? _Shape.star : _Shape.dot,
              spin: rng.nextDouble() * 6,
            ),
          );
        }
      case _Effect.confettiRain:
        for (var i = 0; i < 44; i++) {
          _particles.add(
            _Particle(
              angle: 0,
              speed: 0,
              size: 4 + rng.nextDouble() * 7,
              color: pick(),
              shape: _Shape.rect,
              spin: (rng.nextDouble() - 0.5) * 12,
              x: _center.dx + (rng.nextDouble() - 0.5) * screen.width * 0.5,
              y: _center.dy - screen.height * 0.12 - rng.nextDouble() * 80,
              fallSpeed: 0.45 + rng.nextDouble() * 0.55,
              drift: (rng.nextDouble() - 0.5) * 60,
            ),
          );
        }
      case _Effect.doubleFirework:
        for (var i = 0; i < 22; i++) {
          _particles.add(
            _Particle(
              angle: (i / 22) * 2 * pi,
              speed: 0.5 + rng.nextDouble() * 0.4,
              size: 4 + rng.nextDouble() * 6,
              color: pick(),
              shape: _Shape.dot,
              spin: 0,
            ),
          );
        }
        _ripples.add(_Ripple(delay: 0, color: pick()));
        _ripples.add(
          _Ripple(
            delay: 0.3,
            color: pick(),
            offset: Offset(
              (rng.nextDouble() - 0.5) * screen.width * 0.3,
              -screen.height * 0.05,
            ),
          ),
        );
      case _Effect.ripple:
        _ripples.add(_Ripple(delay: 0, color: pick()));
        _ripples.add(_Ripple(delay: 0.12, color: pick()));
        _ripples.add(_Ripple(delay: 0.24, color: pick()));
        for (var i = 0; i < 14; i++) {
          _particles.add(
            _Particle(
              angle: (i / 14) * 2 * pi + rng.nextDouble() * 0.4,
              speed: 0.35 + rng.nextDouble() * 0.35,
              size: 3 + rng.nextDouble() * 5,
              color: pick(),
              shape: _Shape.dot,
              spin: 0,
            ),
          );
        }
    }
    _ctrl.forward();
  }

  /// 首帧拿到真实主题后，把随机色替换为主题调色板。
  void _tintWithScheme(ColorScheme scheme) {
    if (_tinted) return;
    _tinted = true;
    final rng = Random();
    final palette = [
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      scheme.primaryContainer,
      scheme.tertiaryContainer,
    ];
    for (final p in _particles) {
      p.color = palette[rng.nextInt(palette.length)];
    }
    for (var i = 0; i < _ripples.length; i++) {
      _ripples[i].color = palette[i % palette.length];
    }
  }

  @override
  Widget build(BuildContext context) {
    _tintWithScheme(Theme.of(context).colorScheme);
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) => CustomPaint(
            painter: _EffectsPainter(
              effect: _effect,
              particles: _particles,
              ripples: _ripples,
              center: _center,
              t: _ctrl.value,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
}

class _Particle {
  _Particle({
    required this.angle,
    required this.speed,
    required this.size,
    required this.color,
    required this.shape,
    required this.spin,
    this.x,
    this.y,
    this.fallSpeed = 0,
    this.drift = 0,
  });

  final double angle;
  final double speed;
  final double size;
  Color color;
  final _Shape shape;
  final double spin;
  final double? x;
  final double? y;
  final double fallSpeed;
  final double drift;
}

class _Ripple {
  _Ripple({
    required this.delay,
    required this.color,
    this.offset = Offset.zero,
  });

  final double delay;
  Color color;
  final Offset offset;
}

class _EffectsPainter extends CustomPainter {
  _EffectsPainter({
    required this.effect,
    required this.particles,
    required this.ripples,
    required this.center,
    required this.t,
  });

  final _Effect effect;
  final List<_Particle> particles;
  final List<_Ripple> ripples;
  final Offset center;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final maxDist = size.width * 0.4;
    final paint = Paint()..style = PaintingStyle.fill;

    // 波纹扩散环。
    for (final r in ripples) {
      final local = (t - r.delay) / 0.7;
      if (local <= 0 || local >= 1) continue;
      final eased = Curves.easeOutCubic.transform(local);
      paint.color = r.color.withValues(alpha: (1 - local) * 0.55);
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 5 * (1 - local) + 1;
      canvas.drawCircle(center + r.offset, eased * size.width * 0.28, paint);
      paint.style = PaintingStyle.fill;
    }

    for (final p in particles) {
      switch (effect) {
        case _Effect.starBurst:
        case _Effect.doubleFirework:
          final local = (t / 0.85).clamp(0.0, 1.0);
          final dist = maxDist * p.speed * Curves.easeOut.transform(local);
          final pos =
              center +
              Offset(
                cos(p.angle) * dist,
                sin(p.angle) * dist + local * local * 55,
              );
          paint.color = p.color.withValues(alpha: (1 - local).clamp(0.0, 1.0));
          _drawShape(canvas, pos, p, local, paint);
        case _Effect.confettiRain:
          final dist = t * size.height * 0.5 * p.fallSpeed;
          final pos = Offset(
            p.x! + p.drift * sin(t * 3 + p.size) * t,
            p.y! + dist,
          );
          if (pos.dy > size.height + 20) continue;
          paint.color = p.color.withValues(
            alpha: (1 - Curves.easeIn.transform(t)).clamp(0.0, 1.0),
          );
          _drawShape(canvas, pos, p, t, paint);
        case _Effect.ripple:
          final local = (t / 0.9).clamp(0.0, 1.0);
          final dist =
              maxDist * 0.5 * p.speed * Curves.easeOut.transform(local);
          final pos =
              center +
              Offset(cos(p.angle) * dist, sin(p.angle) * dist + local * 30);
          paint.color = p.color.withValues(alpha: (1 - local).clamp(0.0, 1.0));
          _drawShape(canvas, pos, p, local, paint);
      }
    }
  }

  void _drawShape(
    Canvas canvas,
    Offset pos,
    _Particle p,
    double local,
    Paint paint,
  ) {
    switch (p.shape) {
      case _Shape.dot:
        canvas.drawCircle(pos, p.size * (1 - local * 0.5), paint);
      case _Shape.rect:
        canvas.save();
        canvas.translate(pos.dx, pos.dy);
        canvas.rotate(p.spin + local * p.spin * 0.6);
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: p.size * 1.6,
            height: p.size * 0.8,
          ),
          paint,
        );
        canvas.restore();
      case _Shape.star:
        canvas.save();
        canvas.translate(pos.dx, pos.dy);
        canvas.rotate(p.spin + local * 2);
        final path = Path();
        final r = p.size * (1 - local * 0.4);
        for (var i = 0; i < 8; i++) {
          final rr = i.isEven ? r : r * 0.42;
          final a = i * pi / 4;
          i == 0
              ? path.moveTo(cos(a) * rr, sin(a) * rr)
              : path.lineTo(cos(a) * rr, sin(a) * rr);
        }
        path.close();
        canvas.drawPath(path, paint);
        canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _EffectsPainter old) => old.t != t;
}
