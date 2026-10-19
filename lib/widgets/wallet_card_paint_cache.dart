import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'wallet_card_occlusion.dart';
import 'wallet_card_texture_layout.dart';

typedef _CardTextureKey = ({
  String accountId,
  Object content,
  Object environment,
  Size size,
  double pixelRatio,
  double? occluderOffset,
  double radius,
  double shadowExtent,
  bool compact,
});

/// One shared pixel budget for active cards and a small recent offscreen LRU.
/// The total account count never determines the number of stored textures.
class WalletCardPaintCacheBudget {
  WalletCardPaintCacheBudget({
    this.maxPixelBytes = 64 * 1024 * 1024,
    this.maxImages = 24,
    this.maxIdleEntries = 4,
  });

  final int maxPixelBytes;
  final int maxImages;
  final int maxIdleEntries;
  final _entries = <_CardTextureKey, _CardTextureEntry>{};
  final _idle = LinkedHashMap<_CardTextureKey, _CardTextureEntry>();
  final _waiting = LinkedHashSet<_RenderWalletCardCachedPaint>();
  int _images = 0;
  int _pixelBytes = 0;
  int _serial = 0;
  bool _disposed = false;
  bool _retryScheduled = false;

  Map<String, Object> get _stats => {
        'activeImages': _images,
        'pinnedImages': _images - _idle.length,
        'idleImages': _idle.length,
        'reservedPixelBytes': _pixelBytes,
      };

  _CardTextureEntry? _acquire(_CardTextureKey key) {
    if (_disposed) return null;
    final entry = _entries[key];
    if (entry == null) return null;
    _idle.remove(key);
    entry.references++;
    return entry;
  }

  _PaintCacheReservation? _reserve(int bytes) {
    if (_disposed || bytes > maxPixelBytes) return null;
    while (_images >= maxImages || bytes > maxPixelBytes - _pixelBytes) {
      if (_idle.isEmpty) return null;
      _destroy(_idle.values.first);
    }
    _images++;
    _pixelBytes += bytes;
    return _PaintCacheReservation(this, bytes, ++_serial);
  }

  _CardTextureEntry _store(
    _CardTextureKey key,
    _PaintCacheReservation reservation,
    ui.Image image,
    WalletCardTextureLayout layout,
  ) {
    reservation.transferred = true;
    final entry = _CardTextureEntry(key, image, layout, reservation.serial);
    _entries[key] = entry;
    return entry;
  }

  void _invalidate(_CardTextureKey? key) {
    if (key == null) return;
    final entry = _entries.remove(key);
    if (entry == null) return;
    _idle.remove(key);
    entry.invalidated = true;
    if (entry.references == 0) _destroy(entry);
  }

  void _release(_CardTextureEntry entry,
      {required bool invalidate, required bool retain}) {
    if (invalidate) {
      entry.invalidated = true;
      if (identical(_entries[entry.key], entry)) _invalidate(entry.key);
    }
    entry.references--;
    if (entry.references > 0) return;
    if (_disposed ||
        entry.invalidated ||
        !identical(_entries[entry.key], entry) ||
        !retain ||
        maxIdleEntries == 0) {
      _destroy(entry);
    } else {
      _idle.remove(entry.key);
      _idle[entry.key] = entry;
      while (_idle.length > maxIdleEntries) {
        _destroy(_idle.values.first);
      }
    }
    _scheduleRetry();
  }

  void _destroy(_CardTextureEntry entry) {
    if (entry.disposed) return;
    entry.disposed = true;
    if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
    if (identical(_idle[entry.key], entry)) _idle.remove(entry.key);
    entry.image.dispose();
    _images--;
    _pixelBytes -= entry.layout.pixelBytes;
  }

  bool _couldFit(int bytes) {
    if (_disposed || bytes <= 0 || bytes > maxPixelBytes) return false;
    final idleBytes = _idle.values
        .fold<int>(0, (sum, entry) => sum + entry.layout.pixelBytes);
    return _images - _idle.length < maxImages &&
        bytes <= maxPixelBytes - _pixelBytes + idleBytes;
  }

  void _wait(_RenderWalletCardCachedPaint card) {
    _waiting.add(card);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed || _retryScheduled || _waiting.isEmpty) return;
    _retryScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _retryScheduled = false;
      if (_disposed) return;
      // At most one still-visible card is retried per frame. A failed card's
      // clean outer RepaintBoundary otherwise would retain vector paint forever.
      for (final card in _waiting.toList(growable: false)) {
        if (!card.attached ||
            !card._enabled ||
            !identical(card._budget, this)) {
          _waiting.remove(card);
          continue;
        }
        if (card._entry != null) {
          _waiting.remove(card);
          continue;
        }
        if (!card._visibleInViewport || !_couldFit(card._retryBytes)) continue;
        _waiting.remove(card);
        card._requestRetry();
        break;
      }
      if (_waiting.any((card) =>
          card.attached &&
          card._visibleInViewport &&
          _couldFit(card._retryBytes))) {
        _scheduleRetry();
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _clearIdle() {
    for (final entry in _idle.values.toList(growable: false)) {
      _destroy(entry);
    }
    _scheduleRetry();
  }

  void dispose() {
    _disposed = true;
    _waiting.clear();
    for (final entry in _entries.values.toList(growable: false)) {
      _invalidate(entry.key);
    }
    // Active render objects release their images on detach/dispose. Retained
    // DisplayLists and driver/in-flight references are outside the pixel budget.
  }
}

class _PaintCacheReservation {
  _PaintCacheReservation(this.budget, this.pixelBytes, this.serial);
  final WalletCardPaintCacheBudget budget;
  final int pixelBytes;
  final int serial;
  bool transferred = false;
  bool cancelled = false;

  void cancel() {
    if (transferred || cancelled) return;
    cancelled = true;
    budget._images--;
    budget._pixelBytes -= pixelBytes;
    budget._scheduleRetry();
  }
}

class _CardTextureEntry {
  _CardTextureEntry(this.key, this.image, this.layout, this.serial);
  final _CardTextureKey key;
  final ui.Image image;
  final WalletCardTextureLayout layout;
  final int serial;
  int references = 1;
  bool invalidated = false;
  bool disposed = false;
}

/// Collection-only texture caching inside the Sliver's whole-card boundary.
/// Layout, hit testing and the child widgets remain unchanged.
class WalletCardCachedPaint extends SingleChildRenderObjectWidget {
  const WalletCardCachedPaint({
    super.key,
    required this.enabled,
    required this.accountId,
    required this.contentVersion,
    required this.budget,
    required this.geometry,
    required this.occluderOffset,
    this.compact = true,
    this.batchDraws = true,
    required super.child,
  });

  final bool enabled;
  final String accountId;
  final Object contentVersion;
  final WalletCardPaintCacheBudget budget;
  final WalletCardOcclusionGeometry geometry;
  final double? occluderOffset;
  final bool compact;
  final bool batchDraws;

  double _pixelRatio(BuildContext context) {
    final designWidth = MediaQuery.sizeOf(context).width;
    final physicalWidth = View.of(context).physicalSize.width;
    return designWidth > 0 && physicalWidth > 0
        ? physicalWidth / designWidth
        : MediaQuery.devicePixelRatioOf(context);
  }

  Object _environment(BuildContext context) => (
        textStyle: DefaultTextStyle.of(context).style,
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      );

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWalletCardCachedPaint(
        enabled: enabled,
        accountId: accountId,
        contentVersion: contentVersion,
        environment: _environment(context),
        budget: budget,
        geometry: geometry,
        occluderOffset: occluderOffset,
        pixelRatio: _pixelRatio(context),
        compact: compact,
        batchDraws: batchDraws,
      );

  @override
  void updateRenderObject(
      BuildContext context, _RenderWalletCardCachedPaint renderObject) {
    renderObject.updateConfiguration(
      enabled: enabled,
      accountId: accountId,
      contentVersion: contentVersion,
      environment: _environment(context),
      budget: budget,
      geometry: geometry,
      occluderOffset: occluderOffset,
      pixelRatio: _pixelRatio(context),
      compact: compact,
      batchDraws: batchDraws,
    );
  }
}

class _CardCaptureContext extends PaintingContext {
  _CardCaptureContext(ContainerLayer layer, Rect bounds) : super(layer, bounds);
  void finish() => stopRecordingIfNeeded();
}

class _RenderWalletCardCachedPaint extends RenderProxyBox {
  _RenderWalletCardCachedPaint({
    required bool enabled,
    required String accountId,
    required Object contentVersion,
    required Object environment,
    required WalletCardPaintCacheBudget budget,
    required WalletCardOcclusionGeometry geometry,
    required double? occluderOffset,
    required double pixelRatio,
    required bool compact,
    required bool batchDraws,
  })  : _enabled = enabled,
        _accountId = accountId,
        _contentVersion = contentVersion,
        _environment = environment,
        _budget = budget,
        _geometry = geometry,
        _occluderOffset = occluderOffset,
        _pixelRatio = pixelRatio,
        _compact = compact,
        _batchDraws = batchDraws;

  bool _enabled;
  String _accountId;
  Object _contentVersion;
  Object _environment;
  WalletCardPaintCacheBudget _budget;
  WalletCardOcclusionGeometry _geometry;
  double? _occluderOffset;
  double _pixelRatio;
  bool _compact;
  bool _batchDraws;
  _CardTextureEntry? _entry;
  _CardTextureKey? _lastKey;
  bool _cannotSnapshot = false;
  String _reason = 'mount';
  int _retryBytes = 0;
  final _imagePaint = Paint()..filterQuality = FilterQuality.low;

  _CardTextureKey get _key => (
        accountId: _accountId,
        content: _contentVersion,
        environment: _environment,
        size: size,
        pixelRatio: _pixelRatio,
        occluderOffset: _occluderOffset,
        radius: _geometry.cornerRadius,
        shadowExtent: _geometry.shadowExtent,
        compact: _compact,
      );

  void updateConfiguration({
    required bool enabled,
    required String accountId,
    required Object contentVersion,
    required Object environment,
    required WalletCardPaintCacheBudget budget,
    required WalletCardOcclusionGeometry geometry,
    required double? occluderOffset,
    required double pixelRatio,
    required bool compact,
    required bool batchDraws,
  }) {
    final textureUnchanged = _enabled == enabled &&
        _accountId == accountId &&
        _contentVersion == contentVersion &&
        _environment == environment &&
        identical(_budget, budget) &&
        identical(_geometry, geometry) &&
        _occluderOffset == occluderOffset &&
        _pixelRatio == pixelRatio &&
        _compact == compact;
    if (textureUnchanged && _batchDraws == batchDraws) return;
    if (!textureUnchanged) {
      _dropEntry(invalidate: false, retain: true);
      _lastKey = null;
      _reason = _contentVersion != contentVersion
          ? 'contentVersion'
          : _environment != environment
              ? 'environment'
              : _pixelRatio != pixelRatio
                  ? 'resolution'
                  : 'configuration';
      _cannotSnapshot = false;
    }
    _enabled = enabled;
    _accountId = accountId;
    _contentVersion = contentVersion;
    _environment = environment;
    _budget = budget;
    _geometry = geometry;
    _occluderOffset = occluderOffset;
    _pixelRatio = pixelRatio;
    _compact = compact;
    _batchDraws = batchDraws;
    // Changing submission mode does not generate another texture.
    super.markNeedsPaint();
  }

  void _dropEntry({required bool invalidate, required bool retain}) {
    _budget._waiting.remove(this);
    _retryBytes = 0;
    final entry = _entry;
    _entry = null;
    if (entry != null) {
      _budget._release(entry, invalidate: invalidate, retain: retain);
    } else if (invalidate) {
      _budget._invalidate(_lastKey);
    }
  }

  @override
  void markNeedsPaint() {
    _dropEntry(invalidate: true, retain: false);
    _reason = 'childPaint';
    super.markNeedsPaint();
  }

  @override
  void performLayout() {
    final previousSize = hasSize ? size : null;
    super.performLayout();
    if (previousSize != size) {
      _dropEntry(invalidate: false, retain: true);
      _lastKey = null;
      _reason = previousSize == null ? 'mount' : 'size';
    }
  }

  @override
  Rect get paintBounds => _geometry.paintBounds(size);

  bool get _visibleInViewport {
    if (!attached || !hasSize || size.isEmpty || !_enabled) return false;
    final viewport = RenderAbstractViewport.maybeOf(this);
    if (viewport is! RenderBox) return false;
    final viewportBox = viewport as RenderBox;
    if (!viewportBox.hasSize) return false;
    final rect =
        MatrixUtils.transformRect(getTransformTo(viewportBox), paintBounds);
    return rect.overlaps(viewportBox.paintBounds);
  }

  void _requestRetry() {
    _retryBytes = 0;
    _reason = 'budgetRetry';
    super.markNeedsPaint();
  }

  OffsetLayer _recordSource() {
    final layer = OffsetLayer();
    final captureContext = _CardCaptureContext(layer, paintBounds);
    try {
      super.paint(captureContext, Offset.zero);
      captureContext.finish();
      return layer;
    } catch (_) {
      try {
        captureContext.finish();
      } finally {
        layer.dispose();
      }
      rethrow;
    }
  }

  Map<String, Object> _diagnostics() => {
        'accountId': _accountId,
        'reason': _reason,
        ..._budget._stats,
      };

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      _dropEntry(invalidate: false, retain: false);
      return;
    }
    if (!_enabled ||
        _cannotSnapshot ||
        !_pixelRatio.isFinite ||
        _pixelRatio <= 0) {
      super.paint(context, offset);
      return;
    }
    if (_entry == null) {
      final key = _key;
      _lastKey = key;
      final cached = _budget._acquire(key);
      _entry = cached;
      OffsetLayer? layer;
      try {
        final sourceLayer = _recordSource();
        layer = sourceLayer;
        if (cached != null) {
          // Painting into a discarded source layer clears a newly mounted
          // child's dirty flags. No GPU snapshot is generated for an LRU hit.
          _entry = cached;
          developer.Timeline.instantSync('WalletCardPaintCache.Hit',
              arguments: {
                ..._diagnostics(),
                'cacheId': cached.serial,
              });
        } else if (!sourceLayer.supportsRasterization()) {
          _cannotSnapshot = true;
        } else {
          final rects = _geometry.exposedRectsFor(size, _occluderOffset);
          final layout =
              _compact && WalletCardTextureLayout.canPack(sourceLayer)
                  ? WalletCardTextureLayout.compact(
                      bounds: paintBounds,
                      exposedRects: rects,
                      pixelRatio: _pixelRatio)
                  : WalletCardTextureLayout.full(
                      bounds: paintBounds,
                      exposedRects: rects,
                      pixelRatio: _pixelRatio);
          final reservation = _budget._reserve(layout.pixelBytes);
          if (reservation == null) {
            _retryBytes = layout.pixelBytes;
            _budget._wait(this);
            developer.Timeline.instantSync('WalletCardPaintCache.BudgetFull',
                arguments: {
                  ..._diagnostics(),
                  'requestedPixelBytes': layout.pixelBytes,
                });
          } else {
            try {
              final image = developer.Timeline.timeSync<ui.Image>(
                'WalletCardPaintCache.Create',
                () => layout.capture(sourceLayer),
                arguments: {
                  ..._diagnostics(),
                  'cacheId': reservation.serial,
                  'pixelWidth': layout.width,
                  'pixelHeight': layout.height,
                  'sourcePixelWidth': (paintBounds.width * _pixelRatio).ceil(),
                  'sourcePixelHeight':
                      (paintBounds.height * _pixelRatio).ceil(),
                  'packed': layout.packed,
                  'pieces': layout.pieces.length,
                },
              );
              _entry = _budget._store(key, reservation, image, layout);
              _budget._waiting.remove(this);
              _retryBytes = 0;
            } catch (_) {
              reservation.cancel();
              rethrow;
            }
          }
        }
      } catch (_) {
        _dropEntry(invalidate: false, retain: true);
        rethrow;
      } finally {
        layer?.dispose();
      }
    }
    final entry = _entry;
    if (entry == null) {
      super.paint(context, offset);
    } else {
      entry.layout.draw(context.canvas, entry.image, offset, _imagePaint,
          batch: _batchDraws);
    }
  }

  @override
  void reassemble() {
    _dropEntry(invalidate: true, retain: false);
    _budget._clearIdle();
    _lastKey = null;
    _cannotSnapshot = false;
    _reason = 'reassemble';
    super.reassemble();
  }

  @override
  void detach() {
    _dropEntry(invalidate: false, retain: true);
    super.detach();
  }

  @override
  void dispose() {
    _dropEntry(invalidate: false, retain: true);
    super.dispose();
  }
}
