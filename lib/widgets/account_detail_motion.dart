import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Shared timing for the wallet card, detail controls, and floating dock.
abstract final class AccountDetailMotion {
  static const duration = Duration(milliseconds: 800);
  static const reverseDuration = Duration(milliseconds: 620);
  // Keep the old transform-layer diagnostic off for the opacity comparison.
  static const retainDockTransformLayer = bool.fromEnvironment(
    'WALLET_RETAIN_DOCK_TRANSFORM_LAYER',
    defaultValue: false,
  );
  // Current comparison: defer the navigation capsule only, leaving the add
  // button's opacity endpoint at its original time.
  static const deferDockOpaqueOneFrame = bool.fromEnvironment(
    'WALLET_DEFER_DOCK_OPAQUE_ONE_FRAME',
    defaultValue: true,
  );
  static const deferAddOpaqueOneFrame = bool.fromEnvironment(
    'WALLET_DEFER_ADD_OPAQUE_ONE_FRAME',
    defaultValue: false,
  );
  static const firstStageEnd = .24;
  static const secondStageEnd = .70;
  // The card travels continuously while the bottom controls retract.
  static const cardTravel =
      Interval(0, secondStageEnd, curve: Cubic(.2, .85, .2, 1));
  static const dockCollapse =
      Interval(0, firstStageEnd, curve: Curves.easeInOutCubic);

  // The remaining cards leave as soon as the selected card starts moving.
  static const stackExit =
      Interval(0, secondStageEnd, curve: Cubic(.4, .15, .7, 1));
  // Reveal the top buttons after the bottom controls have retracted.
  static const topButtons =
      Interval(firstStageEnd, secondStageEnd, curve: Curves.easeInOutCubic);

  // 3. The account content enters only after the card and controls settle.
  static const contentEntrance =
      Interval(secondStageEnd, 1, curve: Curves.easeOutCubic);
}

/// Shared centered expansion/retraction for capsule and circular glass controls.
class CenteredControlTransition extends StatelessWidget {
  const CenteredControlTransition({
    super.key,
    required this.progress,
    required this.child,
    this.isCircular = false,
    this.retainTransformLayer = false,
    this.deferOpaqueByOneFrame = false,
    this.opacityDiagnosticLabel,
  });

  final double progress;
  final bool isCircular;
  final bool retainTransformLayer;
  final bool deferOpaqueByOneFrame;
  final String? opacityDiagnosticLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visible = progress.clamp(0.0, 1.0).toDouble();
    final scaleX = isCircular ? .12 + .88 * visible : .1 + .9 * visible;
    final scaleY = isCircular ? scaleX : .75 + .25 * visible;
    final scaledChild = retainTransformLayer
        ? _RetainedCenteredScale(
            scaleX: scaleX,
            scaleY: scaleY,
            child: child,
          )
        : Transform.scale(
            alignment: Alignment.center,
            scaleX: scaleX,
            scaleY: scaleY,
            child: child,
          );
    final diagnosticLabel = opacityDiagnosticLabel;
    if (diagnosticLabel != null) {
      // A and B keep the same widget/render structure. Only the alpha used
      // for the first fully opaque frame differs; top controls use no wrapper.
      return _DeferredControlOpacity(
        opacity: visible,
        enabled: deferOpaqueByOneFrame &&
            !MediaQuery.disableAnimationsOf(context),
        diagnosticLabel: diagnosticLabel,
        child: scaledChild,
      );
    }
    return Opacity(opacity: visible, child: scaledChild);
  }
}

/// Hold alpha 254 for the first frame that would otherwise round to 255.
/// The next frame restores the requested alpha; initial idle content stays 1.
class _DeferredControlOpacity extends StatefulWidget {
  const _DeferredControlOpacity({
    required this.opacity,
    required this.enabled,
    required this.diagnosticLabel,
    required this.child,
  });

  final double opacity;
  final bool enabled;
  final String diagnosticLabel;
  final Widget child;

  @override
  State<_DeferredControlOpacity> createState() =>
      _DeferredControlOpacityState();
}

class _DeferredControlOpacityState extends State<_DeferredControlOpacity> {
  bool _holdingOpaque = false;
  bool _restoreTracePending = false;
  int _generation = 0;
  int _holdTraceGeneration = -1;
  int _transitionId = 0;

  @override
  void didUpdateWidget(covariant _DeferredControlOpacity oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetAlpha = Color.getAlphaFromOpacity(widget.opacity);
    if (!widget.enabled || targetAlpha < 255) {
      // Invalidate a pending callback if another gesture/transition takes over.
      if (_holdingOpaque || _restoreTracePending) _generation++;
      _holdingOpaque = false;
      _restoreTracePending = false;
      return;
    }
    if (Color.getAlphaFromOpacity(oldWidget.opacity) == 255) return;
    _holdingOpaque = true;
    _restoreTracePending = false;
    _transitionId++;
    final generation = ++_generation;
    // Called during build: hold for this rendered frame, then request exactly
    // one following frame. No timer or continuously ticking animation is used.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _generation ||
          !_holdingOpaque ||
          !widget.enabled) {
        return;
      }
      setState(() {
        _holdingOpaque = false;
        _restoreTracePending = true;
      });
    });
  }

  void _traceOpacityFrame(String name, int paintedAlpha) {
    developer.Timeline.instantSync(name, arguments: {
      'control': widget.diagnosticLabel,
      'transitionId': _transitionId,
      'schedulerFrameUs':
          WidgetsBinding.instance.currentFrameTimeStamp.inMicroseconds,
      'targetOpacity': widget.opacity,
      'targetAlpha': Color.getAlphaFromOpacity(widget.opacity),
      'paintedAlpha': paintedAlpha,
      'deferOpaqueOneFrame': widget.enabled,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_holdingOpaque && _holdTraceGeneration != _generation) {
      _holdTraceGeneration = _generation;
      _traceOpacityFrame('WalletReturn.OpacityHoldFrame', 254);
    }
    if (_restoreTracePending) {
      _restoreTracePending = false;
      _traceOpacityFrame('WalletReturn.OpacityRestoreFrame',
          Color.getAlphaFromOpacity(widget.opacity));
    }
    return Opacity(
      opacity: _holdingOpaque ? 254 / 255 : widget.opacity,
      child: widget.child,
    );
  }
}

/// The centered scale has the same geometry and hit testing as RenderTransform,
/// but does not switch to direct painting when its matrix reaches identity.
class _RetainedCenteredScale extends SingleChildRenderObjectWidget {
  const _RetainedCenteredScale({
    required this.scaleX,
    required this.scaleY,
    required super.child,
  });

  final double scaleX;
  final double scaleY;

  @override
  _RenderRetainedCenteredScale createRenderObject(BuildContext context) =>
      _RenderRetainedCenteredScale(scaleX, scaleY);

  @override
  void updateRenderObject(
      BuildContext context, _RenderRetainedCenteredScale renderObject) {
    renderObject.updateScale(scaleX, scaleY);
  }
}

class _RenderRetainedCenteredScale extends RenderTransform {
  _RenderRetainedCenteredScale(double scaleX, double scaleY)
      : _scaleX = scaleX,
        _scaleY = scaleY,
        super(
          transform: Matrix4.diagonal3Values(scaleX, scaleY, 1),
          alignment: Alignment.center,
        );

  double _scaleX;
  double _scaleY;

  @override
  bool get alwaysNeedsCompositing => child != null;

  void updateScale(double scaleX, double scaleY) {
    if (_scaleX == scaleX && _scaleY == scaleY) return;
    _scaleX = scaleX;
    _scaleY = scaleY;
    // Keep the superclass's matrix in sync for hit testing, semantics and
    // local/global coordinate conversion. This does not change layout.
    transform = Matrix4.diagonal3Values(scaleX, scaleY, 1);
  }

  void _paintChild(PaintingContext context, Offset offset) {
    context.paintChild(child!, offset);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final center = Alignment.center.alongSize(size);
    final effectiveTransform = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..multiply(Matrix4.diagonal3Values(_scaleX, _scaleY, 1))
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    layer = context.pushTransform(
      needsCompositing,
      offset,
      effectiveTransform,
      _paintChild,
      oldLayer: layer is TransformLayer ? layer as TransformLayer? : null,
    );
  }
}
