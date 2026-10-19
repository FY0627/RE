import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'account_detail_motion.dart';

/// Lazy wallet cards with full card height and a smaller overlapping stride.
class SliverWalletCards extends SliverMultiBoxAdaptorWidget {
  const SliverWalletCards({
    super.key,
    required super.delegate,
    required this.itemCount,
    required this.cardExtent,
    required this.peekExtent,
    required this.isCardOpaque,
    this.hiddenIndex,
    this.exitAnimation,
    this.exitDistance = 0,
    this.selectedTravelOffset = 0,
    this.cornerRadius = 20,
    this.shadowExtent = 24,
  })  : assert(itemCount >= 0),
        assert(peekExtent > 0),
        assert(cardExtent >= peekExtent),
        assert(exitDistance >= 0);

  final int itemCount;
  final double cardExtent;
  final double peekExtent;
  final double cornerRadius;
  final double shadowExtent;
  final int? hiddenIndex;
  final Animation<double>? exitAnimation;
  final double exitDistance;
  final double selectedTravelOffset;
  final bool Function(int index) isCardOpaque;

  @override
  RenderSliverWalletCards createRenderObject(BuildContext context) =>
      RenderSliverWalletCards(
        childManager: context as SliverMultiBoxAdaptorElement,
        itemCount: itemCount,
        cardExtent: cardExtent,
        peekExtent: peekExtent,
        cornerRadius: cornerRadius,
        shadowExtent: shadowExtent,
        hiddenIndex: hiddenIndex,
        exitAnimation: exitAnimation,
        exitDistance: exitDistance,
        selectedTravelOffset: selectedTravelOffset,
        isCardOpaque: isCardOpaque,
      );

  @override
  void updateRenderObject(
      BuildContext context, RenderSliverWalletCards renderObject) {
    renderObject.updateConfiguration(
      itemCount: itemCount,
      cardExtent: cardExtent,
      peekExtent: peekExtent,
      cornerRadius: cornerRadius,
      shadowExtent: shadowExtent,
      hiddenIndex: hiddenIndex,
      exitAnimation: exitAnimation,
      exitDistance: exitDistance,
      selectedTravelOffset: selectedTravelOffset,
      isCardOpaque: isCardOpaque,
    );
  }
}

class RenderSliverWalletCards extends RenderSliverMultiBoxAdaptor {
  RenderSliverWalletCards({
    required super.childManager,
    required int itemCount,
    required double cardExtent,
    required double peekExtent,
    double cornerRadius = 20,
    required double shadowExtent,
    required int? hiddenIndex,
    Animation<double>? exitAnimation,
    double exitDistance = 0,
    double selectedTravelOffset = 0,
    bool Function(int index)? isCardOpaque,
  })  : _itemCount = itemCount,
        _cardExtent = cardExtent,
        _peekExtent = peekExtent,
        _shadowExtent = shadowExtent,
        _hiddenIndex = hiddenIndex,
        _exitAnimation = exitAnimation,
        _exitDistance = exitDistance,
        _selectedTravelOffset = selectedTravelOffset {
    _lastExitOffset = _exitOffset;
    _lastCollapseProgress = _collapseProgress;
  }

  int _itemCount;
  double _cardExtent;
  double _peekExtent;
  double _shadowExtent;
  int? _hiddenIndex;
  Animation<double>? _exitAnimation;
  double _exitDistance;
  double _selectedTravelOffset;
  double _lastExitOffset = 0;
  double _lastCollapseProgress = 0;

  double get _exitOffset => _hiddenIndex == null
      ? 0
      : AccountDetailMotion.stackExit.transform(_exitAnimation?.value ?? 0) *
          _exitDistance;

  double get _collapseProgress => _hiddenIndex == null
      ? 0
      : AccountDetailMotion.cardTravel.transform(_exitAnimation?.value ?? 0);

  bool get _backgroundHidden => _hiddenIndex != null &&
      (_exitAnimation?.value ?? 0) >= AccountDetailMotion.secondStageEnd;

  double _cardTransitionOffset(int index) {
    final selected = _hiddenIndex;
    if (selected == null || index == selected) return 0;
    if (index < selected) {
      final originalGap = (selected - index) * _peekExtent;
      // Upper Y = selected flight Y - originalGap * (1 - travel).
      // Keep card sizes fixed while each gap closes behind the selected card.
      return (_selectedTravelOffset + originalGap) * _lastCollapseProgress;
    }
    return _lastExitOffset;
  }

  void _onExitChanged() {
    final offset = _exitOffset;
    final collapse = _collapseProgress;
    if (offset == _lastExitOffset && collapse == _lastCollapseProgress) return;
    _lastExitOffset = offset;
    _lastCollapseProgress = collapse;
    // Move retained whole-card layers without rebuilding or laying out cards.
    // After the exit interval finishes, detail-only frames do no card work.
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _lastExitOffset = _exitOffset;
    _lastCollapseProgress = _collapseProgress;
    _exitAnimation?.addListener(_onExitChanged);
  }

  @override
  void detach() {
    _exitAnimation?.removeListener(_onExitChanged);
    super.detach();
  }

  void updateConfiguration({
    required int itemCount,
    required double cardExtent,
    required double peekExtent,
    double cornerRadius = 20,
    required double shadowExtent,
    required int? hiddenIndex,
    Animation<double>? exitAnimation,
    double exitDistance = 0,
    double selectedTravelOffset = 0,
    bool Function(int index)? isCardOpaque,
  }) {
    final layoutChanged = _itemCount != itemCount ||
        _cardExtent != cardExtent ||
        _peekExtent != peekExtent ||
        _shadowExtent != shadowExtent;
    _itemCount = itemCount;
    _cardExtent = cardExtent;
    _peekExtent = peekExtent;
    _shadowExtent = shadowExtent;
    _hiddenIndex = hiddenIndex;
    if (!identical(_exitAnimation, exitAnimation)) {
      if (attached) _exitAnimation?.removeListener(_onExitChanged);
      _exitAnimation = exitAnimation;
      if (attached) _exitAnimation?.addListener(_onExitChanged);
    }
    _exitDistance = exitDistance;
    _selectedTravelOffset = selectedTravelOffset;
    _lastExitOffset = _exitOffset;
    _lastCollapseProgress = _collapseProgress;
    if (layoutChanged) markNeedsLayout();
    markNeedsPaint();
  }

  double get _totalExtent =>
      _itemCount == 0 ? 0 : (_itemCount - 1) * _peekExtent + _cardExtent;

  /// Resting coordinates remain available even when a card is not painted.
  /// Exit translations never change the source position for the return flight.
  Rect? cardRect(int index, {required RenderObject ancestor}) {
    if (geometry == null || index < 0 || index >= _itemCount) return null;
    return MatrixUtils.transformRect(
      getTransformTo(ancestor),
      Rect.fromLTWH(0, index * _peekExtent - constraints.scrollOffset,
          constraints.crossAxisExtent, _cardExtent),
    );
  }

  void _setGeometry() {
    final extent = _totalExtent;
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: calculatePaintOffset(constraints, from: 0, to: extent),
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: extent),
      maxPaintExtent: extent,
      hasVisualOverflow: constraints.scrollOffset > 0 ||
          extent > constraints.remainingPaintExtent,
    );
  }

  @override
  void performLayout() {
    assert(constraints.axisDirection == AxisDirection.down);
    assert(constraints.growthDirection == GrowthDirection.forward);
    childManager.didStartLayout();
    childManager.setDidUnderflow(false);
    try {
      if (_itemCount == 0) {
        collectGarbage(childCount, 0);
        geometry = SliverGeometry.zero;
        return;
      }
      final cacheStart =
          math.max(0.0, constraints.scrollOffset + constraints.cacheOrigin);
      final cacheEnd = cacheStart + constraints.remainingCacheExtent;
      // Keep cards that extend into the viewport from above, including shadows.
      final firstIndex =
          ((cacheStart - _cardExtent - _shadowExtent) / _peekExtent)
              .floor()
              .clamp(0, _itemCount - 1)
              .toInt();
      final lastIndex = ((cacheEnd + _shadowExtent) / _peekExtent)
          .floor()
          .clamp(firstIndex, _itemCount - 1)
          .toInt();
      collectGarbage(
        firstChild == null
            ? 0
            : calculateLeadingGarbage(firstIndex: firstIndex),
        firstChild == null ? 0 : calculateTrailingGarbage(lastIndex: lastIndex),
      );
      if (firstChild == null &&
          !addInitialChild(
              index: firstIndex, layoutOffset: firstIndex * _peekExtent)) {
        _setGeometry();
        return;
      }
      final childConstraints = constraints.asBoxConstraints(
        minExtent: _cardExtent,
        maxExtent: _cardExtent,
      );
      while (indexOf(firstChild!) > firstIndex) {
        final child = insertAndLayoutLeadingChild(childConstraints);
        if (child == null) break;
        final data = child.parentData! as SliverMultiBoxAdaptorParentData;
        data.layoutOffset = indexOf(child) * _peekExtent;
      }
      var child = firstChild!;
      child.layout(childConstraints);
      (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset =
          indexOf(child) * _peekExtent;
      for (var index = indexOf(child) + 1; index <= lastIndex; index++) {
        var next = childAfter(child);
        if (next == null || indexOf(next) != index) {
          next = insertAndLayoutChild(childConstraints, after: child);
          if (next == null) break;
        } else {
          next.layout(childConstraints);
        }
        (next.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset =
            index * _peekExtent;
        child = next;
      }
      _setGeometry();
      if (indexOf(lastChild!) == _itemCount - 1) {
        childManager.setDidUnderflow(true);
      }
    } finally {
      childManager.didFinishLayout();
    }
  }

  @override
  bool paintsChild(RenderBox child) =>
      !_backgroundHidden &&
      super.paintsChild(child) &&
      indexOf(child) != _hiddenIndex;

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    super.applyPaintTransform(child, transform);
    if (paintsChild(child)) {
      transform.translateByDouble(0, _cardTransitionOffset(indexOf(child)), 0, 1);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_backgroundHidden) return;
    var paintStart = 0.0;
    var paintEnd = constraints.remainingPaintExtent;
    if (_lastExitOffset != 0 || _lastCollapseProgress != 0) {
      final viewport = RenderAbstractViewport.maybeOf(this);
      if (viewport is RenderBox) {
        final viewportBox = viewport as RenderBox;
        if (viewportBox.hasSize) {
          // Upper cards can cross the header's original area. Cull against the
          // real viewport, not the card Sliver's original top edge.
          final bounds = MatrixUtils.transformRect(
            Matrix4.inverted(getTransformTo(viewportBox)),
            viewportBox.paintBounds,
          );
          paintStart = bounds.top;
          paintEnd = bounds.bottom;
        }
      }
    }
    var child = firstChild;
    while (child != null) {
      final index = indexOf(child);
      final restingDy = childMainAxisPosition(child);
      final dy = restingDy + _cardTransitionOffset(index);
      if (index != _hiddenIndex &&
          // Only cards belonging to the original viewport join the transition.
          restingDy - _shadowExtent < constraints.remainingPaintExtent &&
          restingDy + _cardExtent + _shadowExtent > 0 &&
          dy - _shadowExtent < paintEnd &&
          dy + _cardExtent + _shadowExtent > paintStart) {
        final cardOffset = offset + Offset(childCrossAxisPosition(child), dy);
        context.paintChild(child, cardOffset);
      }
      child = childAfter(child);
    }
  }
}
