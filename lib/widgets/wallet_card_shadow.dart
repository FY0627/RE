import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Shares actual shadow images across cards, rather than only drawing commands.
/// Memory depends on geometry/resolution variants, never on account count.
class WalletCardShadowCache {
  WalletCardShadowCache({this.shadowExtent = 24});

  final double shadowExtent;
  static const _maxCachedImages = 2;
  final _images = LinkedHashMap<
      ({
        Size size,
        BorderRadius borderRadius,
        BoxShadow shadow,
        double pixelRatio,
      }),
      ui.Image>();

  ui.Image? imageFor(
    Size size,
    BorderRadius borderRadius,
    BoxShadow shadow,
    double pixelRatio,
  ) {
    if (size.isEmpty || !pixelRatio.isFinite || pixelRatio <= 0) return null;
    final key = (
      size: size,
      borderRadius: borderRadius,
      shadow: shadow,
      pixelRatio: pixelRatio,
    );
    final cached = _images.remove(key);
    if (cached != null) {
      _images[key] = cached;
      return cached;
    }

    final width = ((size.width + shadowExtent * 2) * pixelRatio).ceil();
    final height = ((size.height + shadowExtent * 2) * pixelRatio).ceil();
    final image = developer.Timeline.timeSync<ui.Image>(
      'WalletCardShadowCache.Create',
      () {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..scale(pixelRatio)
          ..translate(shadowExtent, shadowExtent);
        final shadowRect = (Offset.zero & size)
            .shift(shadow.offset)
            .inflate(shadow.spreadRadius);
        // Matches BoxDecoration's round-rect shadow drawing and Paint exactly.
        canvas.drawRRect(borderRadius.toRRect(shadowRect), shadow.toPaint());
        final picture = recorder.endRecording();
        try {
          // With the Android GPU context, this creates a GPU-resident image.
          // Rasterization is deferred; subsequent cards reuse the same image.
          return picture.toImageSync(width, height);
        } finally {
          picture.dispose();
        }
      },
      arguments: {'pixelWidth': width, 'pixelHeight': height},
    );
    _images[key] = image;
    if (_images.length > _maxCachedImages) {
      _images.remove(_images.keys.first)!.dispose();
    }
    return image;
  }

  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }
}

/// Explicitly used by the collection entry; detail/flight keep vector shadows.
class WalletCardShadow extends StatelessWidget {
  const WalletCardShadow({
    super.key,
    required this.cache,
    required this.borderRadius,
    required this.shadow,
    required this.child,
  });

  final WalletCardShadowCache cache;
  final BorderRadius borderRadius;
  final BoxShadow shadow;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final designWidth = MediaQuery.sizeOf(context).width;
    final physicalWidth = View.of(context).physicalSize.width;
    // Includes AppDesignLayout's outer scale as well as the device pixel ratio.
    final pixelRatio = designWidth > 0 && physicalWidth > 0
        ? physicalWidth / designWidth
        : MediaQuery.devicePixelRatioOf(context);
    return CustomPaint(
      painter: _WalletCardShadowPainter(
        cache: cache,
        borderRadius: borderRadius,
        shadow: shadow,
        pixelRatio: pixelRatio,
      ),
      child: child,
    );
  }
}

class _WalletCardShadowPainter extends CustomPainter {
  const _WalletCardShadowPainter({
    required this.cache,
    required this.borderRadius,
    required this.shadow,
    required this.pixelRatio,
  });

  final WalletCardShadowCache cache;
  final BorderRadius borderRadius;
  final BoxShadow shadow;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final image = cache.imageFor(size, borderRadius, shadow, pixelRatio);
    if (image == null) {
      final rect = (Offset.zero & size)
          .shift(shadow.offset)
          .inflate(shadow.spreadRadius);
      canvas.drawRRect(borderRadius.toRRect(rect), shadow.toPaint());
      return;
    }
    final source = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    // Use the rounded-up texture dimensions to avoid stretching its contents.
    final destination = Rect.fromLTWH(
      -cache.shadowExtent,
      -cache.shadowExtent,
      image.width / pixelRatio,
      image.height / pixelRatio,
    );
    canvas.drawImageRect(
      image,
      source,
      destination,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _WalletCardShadowPainter oldDelegate) =>
      !identical(cache, oldDelegate.cache) ||
      borderRadius != oldDelegate.borderRadius ||
      shadow != oldDelegate.shadow ||
      pixelRatio != oldDelegate.pixelRatio;
}
