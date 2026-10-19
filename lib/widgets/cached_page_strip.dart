import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A retained page strip: movement changes paint offsets, never page layout.
class CachedPageStrip extends MultiChildRenderObjectWidget {
  const CachedPageStrip({
    super.key,
    required this.position,
    required this.ignoreContent,
    required super.children,
  });

  final ValueListenable<double> position;
  final bool ignoreContent;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPageStrip(
        position: position,
        ignoreContent: ignoreContent,
      );

  @override
  void updateRenderObject(BuildContext context, _RenderPageStrip renderObject) {
    renderObject
      ..position = position
      ..ignoreContent = ignoreContent;
  }
}

class _PageStripParentData extends ContainerBoxParentData<RenderBox> {
  int index = 0;
}

class _RenderPageStrip extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PageStripParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PageStripParentData> {
  _RenderPageStrip({
    required ValueListenable<double> position,
    required bool ignoreContent,
  })  : _position = position,
        _ignoreContent = ignoreContent;

  ValueListenable<double> _position;
  bool _ignoreContent;

  @override
  bool get isRepaintBoundary => true;

  set position(ValueListenable<double> value) {
    if (identical(value, _position)) return;
    if (attached) _position.removeListener(_onPositionChanged);
    _position = value;
    if (attached) _position.addListener(_onPositionChanged);
    _onPositionChanged();
  }

  set ignoreContent(bool value) {
    if (value == _ignoreContent) return;
    _ignoreContent = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position.addListener(_onPositionChanged);
  }

  @override
  void detach() {
    _position.removeListener(_onPositionChanged);
    super.detach();
  }

  void _onPositionChanged() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PageStripParentData) {
      child.parentData = _PageStripParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
    final pageConstraints = BoxConstraints.tight(size);
    var index = 0;
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _PageStripParentData;
      data.index = index++;
      child.layout(pageConstraints);
      child = data.nextSibling;
    }
  }

  Offset _pageOffset(RenderBox child) {
    final data = child.parentData! as _PageStripParentData;
    return Offset((data.index - _position.value) * size.width, 0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _PageStripParentData;
      if ((data.index - _position.value).abs() < 0.999) {
        // Static RepaintBoundary layers are reused while their offsets change.
        context.paintChild(child, offset + _pageOffset(child));
      }
      child = data.nextSibling;
    }
  }

  RenderBox? get _activeChild {
    if (childCount == 0) return null;
    final index = _position.value.round().clamp(0, childCount - 1);
    var child = firstChild;
    for (var i = 0; child != null && i < index; i++) {
      child = (child.parentData! as _PageStripParentData).nextSibling;
    }
    return child;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_ignoreContent) return false;
    final child = _activeChild;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _pageOffset(child),
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _pageOffset(child);
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_ignoreContent) return;
    final child = _activeChild;
    if (child != null) visitor(child);
  }
}

/// Only visibility changes update TickerMode; page content stays identical.
class RetainedStagePage extends StatefulWidget {
  const RetainedStagePage({
    super.key,
    required this.index,
    required this.position,
    required this.child,
  });

  final int index;
  final ValueListenable<double> position;
  final Widget child;

  @override
  State<RetainedStagePage> createState() => _RetainedStagePageState();
}

class _RetainedStagePageState extends State<RetainedStagePage> {
  late bool _visible;

  bool get _isVisible => (widget.index - widget.position.value).abs() < 0.999;

  @override
  void initState() {
    super.initState();
    _visible = _isVisible;
    widget.position.addListener(_onPositionChanged);
  }

  void _onPositionChanged() {
    final visible = _isVisible;
    if (visible != _visible) setState(() => _visible = visible);
  }

  @override
  void didUpdateWidget(covariant RetainedStagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.position, oldWidget.position)) {
      oldWidget.position.removeListener(_onPositionChanged);
      widget.position.addListener(_onPositionChanged);
    }
    _visible = _isVisible;
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPositionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TickerMode(
        enabled: _visible,
        child: widget.child,
      );
}
