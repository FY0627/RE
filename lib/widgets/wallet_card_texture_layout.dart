import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

/// Physical-pixel packing for an unchanged card and its exposed paint regions.
/// The one-texel gutters share the original card's raster grid, so filtering
/// does not read an unrelated neighbouring tile or create a cut in a shadow.
class WalletCardTextureLayout {
  WalletCardTextureLayout._({
    required this.bounds,
    required this.pixelRatio,
    required this.width,
    required this.height,
    required this.packed,
    required this.pieces,
  }) {
    sourceRects = Float32List(pieces.length * 4);
    transforms = Float32List(pieces.length * 4);
    for (var i = 0; i < pieces.length; i++) {
      final piece = pieces[i];
      final index = i * 4;
      sourceRects[index] = piece.source.left;
      sourceRects[index + 1] = piece.source.top;
      sourceRects[index + 2] = piece.source.right;
      sourceRects[index + 3] = piece.source.bottom;
      transforms[index] = piece.rotated ? 0 : 1 / pixelRatio;
      transforms[index + 1] = piece.rotated ? -1 / pixelRatio : 0;
      transforms[index + 2] = piece.destination.left;
      transforms[index + 3] =
          piece.rotated ? piece.destination.bottom : piece.destination.top;
    }
  }

  factory WalletCardTextureLayout.full({
    required Rect bounds,
    required List<Rect> exposedRects,
    required double pixelRatio,
  }) =>
      WalletCardTextureLayout._(
        bounds: bounds,
        pixelRatio: pixelRatio,
        width: (bounds.width * pixelRatio).ceil(),
        height: (bounds.height * pixelRatio).ceil(),
        packed: false,
        pieces: [
          for (final rect in exposedRects)
            WalletCardTexturePiece(
              destination: rect,
              source: _pixels(rect, bounds, pixelRatio),
              capture: Rect.zero,
              placement: Rect.zero,
              rotated: false,
            ),
        ],
      );

  factory WalletCardTextureLayout.compact({
    required Rect bounds,
    required List<Rect> exposedRects,
    required double pixelRatio,
  }) {
    // A full final card already has no central hole to remove.
    if (exposedRects.length == 1) {
      return WalletCardTextureLayout.full(
        bounds: bounds,
        exposedRects: exposedRects,
        pixelRatio: pixelRatio,
      );
    }
    const gutter = 1;
    final captures =
        <({Rect destination, Rect pixels, Rect capture, bool rotated})>[];
    var rowWidth = 0.0;
    for (final rect in exposedRects) {
      final pixels = _pixels(rect, bounds, pixelRatio);
      final capture = Rect.fromLTRB(
        (pixels.left.floor() - gutter).toDouble(),
        (pixels.top.floor() - gutter).toDouble(),
        (pixels.right.ceil() + gutter).toDouble(),
        (pixels.bottom.ceil() + gutter).toDouble(),
      );
      final rotated = capture.height > capture.width;
      rowWidth = math.max(rowWidth, rotated ? capture.height : capture.width);
      captures.add((
        destination: rect,
        pixels: pixels,
        capture: capture,
        rotated: rotated,
      ));
    }

    // Shelf packing keeps the two rotated shadow strips in the same row.
    var x = 0.0;
    var y = 0.0;
    var shelfHeight = 0.0;
    final pieces = <WalletCardTexturePiece>[];
    for (final tile in captures) {
      final width = tile.rotated ? tile.capture.height : tile.capture.width;
      final height = tile.rotated ? tile.capture.width : tile.capture.height;
      if (x > 0 && x + width > rowWidth) {
        y += shelfHeight;
        x = 0;
        shelfHeight = 0;
      }
      final placement = Rect.fromLTWH(x, y, width, height);
      final source = tile.rotated
          ? Rect.fromLTWH(
              x + tile.capture.height - (tile.pixels.bottom - tile.capture.top),
              y + tile.pixels.left - tile.capture.left,
              tile.pixels.height,
              tile.pixels.width,
            )
          : Rect.fromLTWH(
              x + tile.pixels.left - tile.capture.left,
              y + tile.pixels.top - tile.capture.top,
              tile.pixels.width,
              tile.pixels.height,
            );
      pieces.add(WalletCardTexturePiece(
        destination: tile.destination,
        source: source,
        capture: tile.capture,
        placement: placement,
        rotated: tile.rotated,
      ));
      x += width;
      shelfHeight = math.max(shelfHeight, height);
    }
    final result = WalletCardTextureLayout._(
      bounds: bounds,
      pixelRatio: pixelRatio,
      width: rowWidth.ceil(),
      height: (y + shelfHeight).ceil(),
      packed: true,
      pieces: pieces,
    );
    final full = WalletCardTextureLayout.full(
      bounds: bounds,
      exposedRects: exposedRects,
      pixelRatio: pixelRatio,
    );
    return result.pixelBytes < full.pixelBytes ? result : full;
  }

  final Rect bounds;
  final double pixelRatio;
  final int width;
  final int height;
  final bool packed;
  final List<WalletCardTexturePiece> pieces;
  late final Float32List sourceRects;
  late final Float32List transforms;
  int get pixelBytes => width * height * 4;
  static final _quarterTurn = Float64List.fromList([
    0,
    1,
    0,
    0,
    -1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);
  static final _inverseQuarterTurn = Float64List.fromList([
    0,
    -1,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  static Rect _pixels(Rect rect, Rect bounds, double ratio) => Rect.fromLTWH(
        (rect.left - bounds.left) * ratio,
        (rect.top - bounds.top) * ratio,
        rect.width * ratio,
        rect.height * ratio,
      );

  /// Only known picture/offset/transform/clip layers use the compact path.
  /// Other effects retain Flutter's original whole-scene snapshot mechanism.
  static bool canPack(Layer layer) {
    if (layer.subtreeHasCompositionCallbacks) return false;
    final supported = layer.runtimeType == PictureLayer ||
        layer.runtimeType == ContainerLayer ||
        layer.runtimeType == OffsetLayer ||
        layer.runtimeType == TransformLayer ||
        (layer.runtimeType == ClipRectLayer &&
            layer is ClipRectLayer &&
            _plainClip(layer.clipBehavior)) ||
        (layer.runtimeType == ClipRRectLayer &&
            layer is ClipRRectLayer &&
            _plainClip(layer.clipBehavior)) ||
        (layer.runtimeType == ClipPathLayer &&
            layer is ClipPathLayer &&
            _plainClip(layer.clipBehavior));
    if (!supported) return false;
    if (layer is ContainerLayer) {
      for (var child = layer.firstChild;
          child != null;
          child = child.nextSibling) {
        if (!canPack(child)) return false;
      }
    }
    return true;
  }

  static bool _plainClip(Clip clip) =>
      clip == Clip.hardEdge || clip == Clip.antiAlias;

  ui.Image capture(OffsetLayer layer) {
    if (!packed) return layer.toImageSync(bounds, pixelRatio: pixelRatio);
    final originalRecorder = ui.PictureRecorder();
    final recorder = ui.PictureRecorder();
    ui.Picture? original;
    ui.Picture? picture;
    try {
      _replayLayer(Canvas(originalRecorder), layer);
      original = originalRecorder.endRecording();
      final canvas = Canvas(recorder);
      for (final piece in pieces) {
        canvas.save();
        canvas.clipRect(piece.placement, doAntiAlias: false);
        if (piece.rotated) {
          canvas.translate(
            piece.placement.left + piece.capture.height,
            piece.placement.top,
          );
          canvas.transform(_quarterTurn);
        } else {
          canvas.translate(piece.placement.left, piece.placement.top);
        }
        canvas.translate(-piece.capture.left, -piece.capture.top);
        canvas.scale(pixelRatio);
        canvas.translate(-bounds.left, -bounds.top);
        canvas.drawPicture(original);
        canvas.restore();
      }
      picture = recorder.endRecording();
      // One GPU snapshot of the packed target, never a full image plus copies.
      return picture.toImageSync(width, height);
    } finally {
      if (recorder.isRecording) recorder.endRecording().dispose();
      if (originalRecorder.isRecording) {
        originalRecorder.endRecording().dispose();
      }
      picture?.dispose();
      original?.dispose();
    }
  }

  static void _replayLayer(Canvas canvas, Layer layer) {
    canvas.save();
    if (layer is OffsetLayer)
      canvas.translate(layer.offset.dx, layer.offset.dy);
    if (layer is TransformLayer) canvas.transform(layer.transform!.storage);
    if (layer is ClipRectLayer) {
      canvas.clipRect(layer.clipRect!,
          doAntiAlias: layer.clipBehavior != Clip.hardEdge);
    } else if (layer is ClipRRectLayer) {
      canvas.clipRRect(layer.clipRRect!,
          doAntiAlias: layer.clipBehavior != Clip.hardEdge);
    } else if (layer is ClipPathLayer) {
      canvas.clipPath(layer.clipPath!,
          doAntiAlias: layer.clipBehavior != Clip.hardEdge);
    }
    if (layer is PictureLayer) {
      final picture = layer.picture;
      if (picture != null) canvas.drawPicture(picture);
    } else if (layer is ContainerLayer) {
      for (var child = layer.firstChild;
          child != null;
          child = child.nextSibling) {
        _replayLayer(canvas, child);
      }
    }
    canvas.restore();
  }

  void draw(Canvas canvas, ui.Image image, Offset offset, Paint paint,
      {required bool batch}) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    if (batch) {
      canvas.drawRawAtlas(
          image, transforms, sourceRects, null, null, bounds, paint);
    } else {
      for (final piece in pieces) {
        if (piece.rotated) {
          canvas.save();
          canvas.translate(piece.destination.left, piece.destination.bottom);
          // Counter-clockwise inverse of the packed tile's rotation.
          canvas.transform(_inverseQuarterTurn);
          canvas.drawImageRect(
            image,
            piece.source,
            Rect.fromLTWH(
                0, 0, piece.destination.height, piece.destination.width),
            paint,
          );
          canvas.restore();
        } else {
          canvas.drawImageRect(image, piece.source, piece.destination, paint);
        }
      }
    }
    canvas.restore();
  }
}

class WalletCardTexturePiece {
  const WalletCardTexturePiece({
    required this.destination,
    required this.source,
    required this.capture,
    required this.placement,
    required this.rotated,
  });
  final Rect destination;
  final Rect source;
  final Rect capture;
  final Rect placement;
  final bool rotated;
}
