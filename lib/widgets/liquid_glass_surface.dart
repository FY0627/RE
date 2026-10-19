import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Glass is applied to the base, while the selected capsule has no extra blur.
class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.isDark,
    required this.child,
    this.height = 52,
    this.width,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
  });

  final bool isDark;
  final Widget child;
  final double? height;
  final double? width;
  final BorderRadius? borderRadius;
  final BoxShape shape;

  static BoxShadow surfaceShadow(bool isDark) => BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? .30 : .07),
        blurRadius: isDark ? 14 : 16,
        offset: Offset(0, isDark ? 4 : 3),
      );

  static ImageFilter backgroundFilter(bool isDark) => isDark
      ? ImageFilter.blur(sigmaX: 12, sigmaY: 12)
      : ImageFilter.compose(
          inner: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          outer: const ColorFilter.matrix([
            1.02,
            0,
            0,
            0,
            0,
            0,
            1.02,
            0,
            0,
            0,
            0,
            0,
            1.02,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
        );

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = shape == BoxShape.circle
        ? null
        : (borderRadius ??
            BorderRadius.all(Radius.circular((height ?? 52) / 2)));

    Widget surface = BackdropFilter(
      filter: backgroundFilter(isDark),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: isDark ? AppTheme.darkGlass : AppTheme.lightGlass),
          IgnorePointer(
              child:
                  CustomPaint(painter: GlassEdgePainter(isDark, shape: shape))),
          child,
        ],
      ),
    );

    if (shape == BoxShape.circle) {
      surface = ClipOval(child: surface);
    } else {
      surface = ClipRRect(borderRadius: effectiveRadius!, child: surface);
    }

    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: shape,
          borderRadius: effectiveRadius,
          boxShadow: [surfaceShadow(isDark)],
        ),
        child: surface,
      ),
    );
  }
}

class GlassEdgePainter extends CustomPainter {
  const GlassEdgePainter(this.isDark, {this.shape = BoxShape.rectangle});
  final bool isDark;
  final BoxShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    final sheen = Rect.fromLTWH(0, 0, size.width, size.height * .18);
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

    const stroke = .75;
    const inset = stroke / 2;
    final r = size.height / 2;
    final arc = Radius.circular(r - inset);

    final path = Path();
    if (shape == BoxShape.circle) {
      path
        ..moveTo(inset, r)
        ..arcToPoint(Offset(size.width - inset, r), radius: arc);
    } else {
      path
        ..moveTo(inset, r)
        ..arcToPoint(Offset(r, inset), radius: arc)
        ..lineTo(size.width - r, inset)
        ..arcToPoint(Offset(size.width - inset, r), radius: arc);
    }

    final fade = Rect.fromLTWH(0, 0, size.width, r * .82);
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
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

    if (size.height < 45) {
      final outlinePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: isDark ? .20 : .40),
            Colors.white.withValues(alpha: isDark ? .06 : .12),
          ],
        ).createShader(Offset.zero & size);

      if (shape == BoxShape.circle) {
        canvas.drawCircle(Offset(size.width / 2, size.height / 2),
            size.width / 2 - 0.25, outlinePaint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r)),
          outlinePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant GlassEdgePainter oldDelegate) =>
      oldDelegate.isDark != isDark || oldDelegate.shape != shape;
}

class LiquidSymbol extends StatelessWidget {
  const LiquidSymbol(
      {super.key,
      required this.index,
      required this.color,
      this.selected = false,
      this.size = 18});
  final int index;
  final Color color;
  final bool selected;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _SymbolPainter(index, color, selected)),
      );
}

class _SymbolPainter extends CustomPainter {
  const _SymbolPainter(this.index, this.color, this.selected);
  final int index;
  final Color color;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = index == 4 ? 1.8 : 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    switch (index) {
      case 0:
        path
          ..moveTo(3, 10)
          ..lineTo(12, 3)
          ..lineTo(21, 10)
          ..lineTo(21, 19)
          ..quadraticBezierTo(21, 21, 19, 21)
          ..lineTo(15, 21)
          ..lineTo(15, 14)
          ..lineTo(9, 14)
          ..lineTo(9, 21)
          ..lineTo(5, 21)
          ..quadraticBezierTo(3, 21, 3, 19)
          ..close();
        break;
      case 1:
        path
          ..moveTo(20, 8)
          ..lineTo(20, 6)
          ..quadraticBezierTo(20, 4, 18, 4)
          ..lineTo(6, 4)
          ..cubicTo(2, 4, 2, 10, 6, 10)
          ..lineTo(20, 10)
          ..lineTo(20, 20)
          ..lineTo(6, 20)
          ..quadraticBezierTo(3, 20, 3, 17)
          ..lineTo(3, 7)
          ..moveTo(20, 11)
          ..lineTo(15, 11)
          ..cubicTo(12.3, 11, 12.3, 15, 15, 15)
          ..lineTo(20, 15)
          ..moveTo(15, 13)
          ..lineTo(15.1, 13);
        break;
      case 2:
        path
          ..moveTo(4, 5)
          ..lineTo(4, 19)
          ..lineTo(20, 19)
          ..moveTo(8, 15)
          ..lineTo(8, 11)
          ..moveTo(13, 15)
          ..lineTo(13, 7)
          ..moveTo(18, 15)
          ..lineTo(18, 9);
        break;
      case 3:
        path.addOval(Rect.fromCircle(center: const Offset(12, 8), radius: 3.5));
        path
          ..moveTo(5, 21)
          ..lineTo(5, 19)
          ..cubicTo(5, 9.7, 19, 9.7, 19, 19)
          ..lineTo(19, 21);
        break;
      case 4:
        path
          ..moveTo(12, 5)
          ..lineTo(12, 19)
          ..moveTo(5, 12)
          ..lineTo(19, 12);
        break;
    }
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SymbolPainter oldDelegate) =>
      oldDelegate.index != index ||
      oldDelegate.color != color ||
      oldDelegate.selected != selected;
}
