import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import 'liquid_glass_surface.dart';

enum _PullPhase { idle, dragging, returning, retracting, opening }

class GestureAddButton extends StatefulWidget {
  const GestureAddButton({
    super.key,
    required this.onTrigger,
    required this.isDark,
    this.screenHeight,
    this.onInteractionChanged,
  });

  final FutureOr<void> Function() onTrigger;
  final bool isDark;
  final double? screenHeight;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<GestureAddButton> createState() => _GestureAddButtonState();
}

class _GestureAddButtonState extends State<GestureAddButton>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _diameter = 52.0;
  late final AnimationController _controller;
  final _focusNode = FocusNode();
  Timer? _handoffTimer;
  _PullPhase _phase = _PullPhase.idle;
  double _headPull = 0;
  double _basePull = 0;
  double _startY = 0;
  double _startPull = 0;
  double _releasePull = 0;
  double _releaseFootRadius = 26;
  bool _isReady = false;
  bool _interactionActive = false;

  double get _screenHeight =>
      widget.screenHeight ?? MediaQuery.sizeOf(context).height;
  double get _threshold => _screenHeight * .15;
  Color get _ink =>
      widget.isDark ? const Color(0xFFF5F5F7) : const Color(0xFF171719);
  bool get _blocked =>
      _phase == _PullPhase.retracting || _phase == _PullPhase.opening;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(vsync: this)
      ..addListener(_tick)
      ..addStatusListener((status) {
        if (status != AnimationStatus.completed) return;
        if (_phase == _PullPhase.returning) {
          _reset();
        } else if (_phase == _PullPhase.retracting) {
          unawaited(_openEntry());
        }
      });
  }

  void _setInteraction(bool active) {
    if (_interactionActive == active) return;
    _interactionActive = active;
    widget.onInteractionChanged?.call(active);
  }

  void _tick() {
    if (!mounted) return;
    final t = _controller.value;
    setState(() {
      if (_phase == _PullPhase.returning) {
        // Longer pulls slightly strengthen the bounce; overshoot stays softly bounded.
        final pullRatio =
            (_releasePull / math.max(1.0, _threshold)).clamp(0.0, 1.0);
        final damping = lerpDouble(8.4, 8.0, pullRatio.toDouble())!;
        const frequency = math.pi * 4;
        final spring = t >= 1
            ? 0.0
            : math.exp(-damping * t) *
                (math.cos(frequency * t) +
                    damping / frequency * math.sin(frequency * t));
        final displacement = _releasePull * spring;
        final bounceLimit = lerpDouble(4.5, 6.0, pullRatio.toDouble())!;
        _headPull = displacement < 0
            ? displacement / (1 + -displacement / bounceLimit)
            : displacement;
        _basePull = 0;
      } else if (_phase == _PullPhase.retracting) {
        // Successful release only absorbs the lower droplet; the button stays still.
        _headPull = _releasePull;
        _basePull = _releasePull * Curves.easeOutCubic.transform(t);
      }
    });
  }

  void _reset() {
    if (!mounted) return;
    _controller.stop();
    setState(() {
      _phase = _PullPhase.idle;
      _headPull = _basePull = 0;
      _isReady = false;
    });
    _setInteraction(false);
  }

  void _start(DragStartDetails details) {
    if (_blocked) return;
    _controller.stop();
    _focusNode.requestFocus();
    _startY = details.localPosition.dy;
    _startPull = math.max(0, _headPull);
    setState(() {
      _phase = _PullPhase.dragging;
      _basePull = 0;
      _isReady = _startPull >= _threshold;
    });
    _setInteraction(true);
  }

  void _update(DragUpdateDetails details) {
    if (_phase != _PullPhase.dragging) return;
    final travel =
        math.max(0.0, _startPull + _startY - details.localPosition.dy);
    final ready = travel >= _threshold;
    setState(() {
      _headPull = travel.clamp(0.0, _threshold).toDouble();
      _basePull = 0;
      _isReady = ready;
    });
  }

  void _release(DragEndDetails details) {
    if (_phase != _PullPhase.dragging) return;
    if (_isReady) {
      _retract();
    } else {
      _returnHome();
    }
  }

  void _returnHome() {
    if (_blocked || _phase == _PullPhase.idle) return;
    _controller.stop();
    _releasePull = math.max(0, _headPull);
    setState(() {
      _phase = _PullPhase.returning;
      _isReady = false;
      _basePull = 0;
    });
    if (MediaQuery.disableAnimationsOf(context) || _releasePull < .5) {
      _reset();
    } else {
      _controller.duration = const Duration(milliseconds: 600);
      _controller.forward(from: 0);
    }
  }

  void _retract() {
    if (_blocked) return;
    _controller.stop();
    _releasePull = math.max(0, _headPull);
    _releaseFootRadius = _footRadiusFor(_releasePull, _threshold);
    _setInteraction(true);
    HapticFeedback.heavyImpact();
    setState(() {
      _phase = _PullPhase.retracting;
      _basePull = 0;
      _isReady = true;
    });
    if (MediaQuery.disableAnimationsOf(context) || _releasePull < .5) {
      _basePull = _releasePull;
      unawaited(_openEntry());
    } else {
      _controller.duration = const Duration(milliseconds: 240);
      _controller.forward(from: 0);
    }
  }

  Future<void> _openEntry() async {
    if (!mounted || _phase == _PullPhase.opening) return;
    setState(() {
      _phase = _PullPhase.opening;
      _headPull = _basePull = _releasePull;
    });
    // Restore the idle button after the sheet covers it, avoiding a visible jump down.
    _handoffTimer?.cancel();
    _handoffTimer = Timer(const Duration(milliseconds: 240), () {
      if (mounted && _phase == _PullPhase.opening) {
        setState(() {
          _headPull = _basePull = 0;
        });
      }
    });
    try {
      await Future<void>.sync(widget.onTrigger);
    } finally {
      _handoffTimer?.cancel();
      if (mounted) _reset();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _phase == _PullPhase.dragging) {
      _returnHome();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _handoffTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lift = math.max(0.0, math.max(_headPull, _basePull));
    final overshoot = math.max(0.0, -math.min(_headPull, _basePull));
    final height = _diameter + lift + overshoot;
    final head = Offset(26, lift - _headPull + 26);
    final base = Offset(26, lift - _basePull + 26);
    final distance = math.max(0.0, base.dy - head.dy);
    final stretch =
        (distance / math.max(1.0, _threshold)).clamp(0.0, 1.0).toDouble();
    final path = _liquidTether(head, base, _threshold,
        fixedFootRadius:
            _phase == _PullPhase.retracting ? _releaseFootRadius : null);
    final restingTint =
        widget.isDark ? AppTheme.darkGlass : AppTheme.lightGlass;
    final pulledTint =
        widget.isDark ? const Color(0x30FFFFFF) : const Color(0x26C0BFC8);
    final tint =
        Color.lerp(restingTint, pulledTint, Curves.easeOut.transform(stretch))!;

    return FocusableActionDetector(
      focusNode: _focusNode,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          if (!_blocked) _retract();
          return null;
        }),
        DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) {
          _returnHome();
          return null;
        }),
      },
      child: Semantics(
        button: true,
        label: '向上拉动加号至屏幕高度的百分之十五后松开记账',
        onTap: () {
          if (!_blocked) _retract();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onVerticalDragStart: _start,
          onVerticalDragUpdate: _update,
          onVerticalDragEnd: _release,
          onVerticalDragCancel: _returnHome,
          child: SizedBox.square(
            dimension: _diameter,
            child: Transform.translate(
              offset: Offset(0, overshoot),
              child: OverflowBox(
                alignment: Alignment.bottomCenter,
                minWidth: _diameter,
                maxWidth: _diameter,
                minHeight: height,
                maxHeight: height,
                child: SizedBox(
                  width: _diameter,
                  height: height,
                  child: AnimatedOpacity(
                    opacity: _phase == _PullPhase.opening ? 0 : 1,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    child: CustomPaint(
                      painter: _DropletShadowPainter(path, widget.isDark),
                      child: ClipPath(
                        clipper: _DropletClipper(path),
                        child: BackdropFilter(
                          filter: LiquidGlassSurface.backgroundFilter(
                              widget.isDark),
                          child: CustomPaint(
                            foregroundPainter: _DropletHighlightPainter(
                                path, head, widget.isDark),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(color: tint),
                                Positioned(
                                  top: head.dy - 12,
                                  left: 14,
                                  width: 24,
                                  height: 24,
                                  child: LiquidSymbol(
                                      index: 4, size: 24, color: _ink),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double _footRadiusFor(double pull, double threshold) => lerpDouble(
    26, 14, (pull / math.max(1.0, threshold)).clamp(0.0, 1.0).toDouble())!;

/// Circle arcs join the waist along their exact tangents; the entire shape is one surface.
Path _liquidTether(Offset head, Offset base, double threshold,
    {double? fixedFootRadius}) {
  const radius = 26.0;
  final distance = math.max(0.0, base.dy - head.dy);
  final footRadius = fixedFootRadius ?? _footRadiusFor(distance, threshold);
  if (distance <= .5 ||
      (fixedFootRadius != null && distance <= radius - footRadius))
    return Path()..addOval(Rect.fromCircle(center: head, radius: radius));
  final stretch =
      (distance / math.max(1.0, threshold)).clamp(0.0, 1.0).toDouble();
  const headAngleLimit = math.pi * 35 / 180;
  const footAngleLimit = math.pi * 25 / 180;
  final merge = math.min(
      1.0,
      distance /
          (radius * math.sin(headAngleLimit) +
              footRadius * math.sin(footAngleLimit) +
              18));
  var headAngle = headAngleLimit * merge;
  var footAngle = footAngleLimit * merge;
  var neckAmount = 1.0;
  if (fixedFootRadius != null && distance < radius + footRadius) {
    // Keep the lower circle's radius fixed as its visible arc enters the head.
    neckAmount = (distance - (radius - footRadius)) / (2 * footRadius);
    final headIntersection = math.acos(
        ((radius * radius + distance * distance - footRadius * footRadius) /
                (2 * radius * distance))
            .clamp(-1.0, 1.0));
    final footIntersection = math.acos(
        ((footRadius * footRadius + distance * distance - radius * radius) /
                (2 * footRadius * distance))
            .clamp(-1.0, 1.0));
    headAngle =
        math.pi / 2 - headIntersection - (math.pi / 2 - headAngle) * neckAmount;
    footAngle =
        math.pi / 2 - footIntersection - (math.pi / 2 - footAngle) * neckAmount;
  }
  final hx = radius * math.cos(headAngle);
  final fx = footRadius * math.cos(footAngle);
  final hy = head.dy + radius * math.sin(headAngle);
  final fy = base.dy - footRadius * math.sin(footAngle);
  final attachmentWidth = math.min(hx, fx);
  final waist = lerpDouble(attachmentWidth, math.min(attachmentWidth, 7.5),
      stretch * stretch * neckAmount)!;
  final midY = hy + (fy - hy) * .62;
  final upperSpan = math.max(0.0, midY - hy);
  final lowerSpan = math.max(0.0, fy - midY);
  final headHandle = math.min(upperSpan * .65,
      (hx - waist) * .85 / math.max(.001, math.sin(headAngle)));
  final footHandle = math.min(lowerSpan * .65,
      (fx - waist) * .85 / math.max(.001, math.sin(footAngle)));
  final waistHandle = math.min(upperSpan, lowerSpan) * .5;
  final cx = head.dx;
  return Path()
    ..moveTo(cx - hx, hy)
    ..arcToPoint(Offset(cx + hx, hy),
        radius: const Radius.circular(radius), largeArc: true)
    ..cubicTo(
        cx + hx - math.sin(headAngle) * headHandle,
        hy + math.cos(headAngle) * headHandle,
        cx + waist,
        midY - waistHandle,
        cx + waist,
        midY)
    ..cubicTo(
        cx + waist,
        midY + waistHandle,
        cx + fx - math.sin(footAngle) * footHandle,
        fy - math.cos(footAngle) * footHandle,
        cx + fx,
        fy)
    ..arcToPoint(Offset(cx - fx, fy),
        radius: Radius.circular(footRadius), largeArc: footAngle >= 0)
    ..cubicTo(
        cx - fx + math.sin(footAngle) * footHandle,
        fy - math.cos(footAngle) * footHandle,
        cx - waist,
        midY + waistHandle,
        cx - waist,
        midY)
    ..cubicTo(
        cx - waist,
        midY - waistHandle,
        cx - hx + math.sin(headAngle) * headHandle,
        hy + math.cos(headAngle) * headHandle,
        cx - hx,
        hy)
    ..close();
}

class _DropletClipper extends CustomClipper<Path> {
  const _DropletClipper(this.path);
  final Path path;
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(covariant _DropletClipper oldClipper) => true;
}

class _DropletShadowPainter extends CustomPainter {
  const _DropletShadowPainter(this.path, this.isDark);
  final Path path;
  final bool isDark;
  @override
  void paint(Canvas canvas, Size size) {
    final shadow = LiquidGlassSurface.surfaceShadow(isDark);
    canvas.drawPath(path.shift(shadow.offset), shadow.toPaint());
  }

  @override
  bool shouldRepaint(covariant _DropletShadowPainter oldDelegate) => true;
}

class _DropletHighlightPainter extends CustomPainter {
  const _DropletHighlightPainter(this.path, this.head, this.isDark);
  final Path path;
  final Offset head;
  final bool isDark;
  @override
  void paint(Canvas canvas, Size size) {
    final top = head.dy - 26;
    final sheen = Rect.fromLTWH(0, top, size.width, 52 * .18);
    canvas.drawRect(
        sheen,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: isDark ? .05 : .14),
              Colors.white.withValues(alpha: 0)
            ],
          ).createShader(sheen));
    final fade = Rect.fromLTWH(0, top, size.width, 26 * .82);
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .75
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, .55, 1],
            colors: [
              Colors.white.withValues(alpha: isDark ? .45 : .68),
              Colors.white.withValues(alpha: isDark ? .18 : .32),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(fade));
  }

  @override
  bool shouldRepaint(covariant _DropletHighlightPainter oldDelegate) => true;
}
