import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Clip, Path, PathFillType, Rect, Size;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Shared, bounded geometry cache for the collection's fixed card overlap.
class WalletCardOcclusionGeometry {
  WalletCardOcclusionGeometry({
    this.cornerRadius = 20,
    this.shadowExtent = 24,
  });

  final double cornerRadius;
  final double shadowExtent;
  static const _edgeGuard = 1.0;
  static const _maxCachedPaths = 4;
  final _paths = LinkedHashMap<({Size size, double occluderOffset}), Path>();

  Rect paintBounds(Size size) =>
      (Rect.fromLTWH(0, 0, size.width, size.height)).inflate(shadowExtent);

  Rect? coveredRectFor(Size size, double occluderOffset) {
    // This rectangle lies strictly inside the next card's opaque round rect.
    // Keep the corner columns, outer shadows, and an antialiasing guard intact.
    final sideInset = math.min(cornerRadius, size.width / 2) + _edgeGuard;
    final top = occluderOffset + _edgeGuard;
    final bottom = math.min(
      size.height + shadowExtent,
      occluderOffset + size.height - _edgeGuard,
    );
    if (size.width <= sideInset * 2 || bottom <= top) return null;
    return Rect.fromLTRB(sideInset, top, size.width - sideInset, bottom);
  }

  /// Extra content exposed when the next card is removed from the stack.
  /// The original cached mask stays unchanged. Only the uncovered rectangle
  /// above the following card needs a temporary paint, with no path difference.
  Rect? revealedRectFor(
    Size size,
    double originalOccluderOffset,
    double? remainingOccluderOffset,
  ) {
    final original = coveredRectFor(size, originalOccluderOffset);
    if (original == null) return null;
    final remaining = remainingOccluderOffset == null
        ? null
        : coveredRectFor(size, remainingOccluderOffset);
    if (remaining == null) return original;
    final bottom = math.min(original.bottom, remaining.top);
    if (bottom <= original.top) return null;
    return Rect.fromLTRB(original.left, original.top, original.right, bottom);
  }

  List<Rect> exposedRectsFor(Size size, double? occluderOffset) {
    final bounds = paintBounds(size);
    final covered =
        occluderOffset == null ? null : coveredRectFor(size, occluderOffset);
    if (covered == null) return [bounds];
    // Non-overlapping image source rectangles preserve the existing mask,
    // including corner columns and side shadows, without a live path clip.
    return [
      Rect.fromLTRB(bounds.left, bounds.top, bounds.right, covered.top),
      Rect.fromLTRB(bounds.left, covered.top, covered.left, covered.bottom),
      Rect.fromLTRB(covered.right, covered.top, bounds.right, covered.bottom),
      if (covered.bottom < bounds.bottom)
        Rect.fromLTRB(
          bounds.left,
          covered.bottom,
          bounds.right,
          bounds.bottom,
        ),
    ];
  }

  Path? pathFor(Size size, double occluderOffset) {
    final key = (size: size, occluderOffset: occluderOffset);
    final cached = _paths.remove(key);
    if (cached != null) {
      _paths[key] = cached;
      return cached;
    }

    final covered = coveredRectFor(size, occluderOffset);
    if (covered == null) return null;

    // Two rectangles and even-odd filling; no PathOperation or curved
    // difference calculation. The path is independent of scroll position.
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(paintBounds(size))
      ..addRect(covered);
    _paths[key] = path;
    if (_paths.length > _maxCachedPaths) {
      _paths.remove(_paths.keys.first);
    }
    return path;
  }

  void clear() => _paths.clear();
}

/// Collection-only paint restriction, placed inside the whole-card boundary.
/// A null offset paints the original card, including all of its shadows.
class WalletCardOcclusion extends SingleChildRenderObjectWidget {
  const WalletCardOcclusion({
    super.key,
    required this.geometry,
    required this.occluderOffset,
    required super.child,
  });

  final WalletCardOcclusionGeometry geometry;
  final double? occluderOffset;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWalletCardOcclusion(
        geometry: geometry,
        occluderOffset: occluderOffset,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWalletCardOcclusion renderObject,
  ) {
    renderObject.updateConfiguration(geometry, occluderOffset);
  }
}

class _RenderWalletCardOcclusion extends RenderProxyBox {
  _RenderWalletCardOcclusion({
    required WalletCardOcclusionGeometry geometry,
    required double? occluderOffset,
  })  : _geometry = geometry,
        _occluderOffset = occluderOffset;

  WalletCardOcclusionGeometry _geometry;
  double? _occluderOffset;

  void updateConfiguration(
    WalletCardOcclusionGeometry geometry,
    double? occluderOffset,
  ) {
    if (identical(_geometry, geometry) && _occluderOffset == occluderOffset) {
      return;
    }
    _geometry = geometry;
    _occluderOffset = occluderOffset;
    // Layout, hit testing, and the card's full size remain unchanged.
    markNeedsPaint();
  }

  @override
  Rect get paintBounds => _geometry.paintBounds(size);

  @override
  void paint(PaintingContext context, Offset offset) {
    final nextOffset = _occluderOffset;
    final path =
        nextOffset == null ? null : _geometry.pathFor(size, nextOffset);
    if (path == null) {
      layer = null;
      super.paint(context, offset);
      return;
    }

    // Ordinary cards record this clip in their existing whole-card
    // DisplayList. If an illustration has its own layer, pushClipPath also
    // clips that retained layer instead of relying on a parent canvas clip.
    // The cut edges are hidden by the next card, so no AA/saveLayer is needed.
    layer = context.pushClipPath(
      needsCompositing,
      offset,
      paintBounds,
      path,
      super.paint,
      clipBehavior: Clip.hardEdge,
      oldLayer: layer as ClipPathLayer?,
    );
  }
}
