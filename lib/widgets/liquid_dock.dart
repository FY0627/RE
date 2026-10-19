import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import 'liquid_glass_surface.dart';

class NavItem {
  final IconData icon;
  final String label;
  const NavItem({required this.icon, required this.label});
}

class _IndicatorFrame {
  const _IndicatorFrame(this.offset, this.center, this.width);
  final double offset;
  final double center;
  final double width;
}

class LiquidDock extends StatefulWidget {
  const LiquidDock({
    super.key,
    required this.currentIndex,
    required this.pagePosition,
    this.isSwiping = false,
    this.settleRevision = 0,
    required this.onTabSelected,
    required this.isDark,
  });

  final int currentIndex;
  final ValueListenable<double> pagePosition;
  final bool isSwiping;
  final int settleRevision;
  final ValueChanged<int> onTabSelected;
  final bool isDark;

  static const items = [
    NavItem(icon: Icons.home_outlined, label: '首页'),
    NavItem(icon: Icons.account_balance_wallet_outlined, label: '资产'),
    NavItem(icon: Icons.bar_chart_outlined, label: '统计'),
    NavItem(icon: Icons.person_outline, label: '我的'),
  ];

  @override
  State<LiquidDock> createState() => LiquidDockState();
}

class LiquidDockState extends State<LiquidDock>
    with SingleTickerProviderStateMixin {
  static const _easeCurve = Cubic(.22, .7, .35, 1);
  static const _contentInset = 5.0;
  static const _indicatorInset = 3.0;
  static const _indicatorHeight = 52.0 - _indicatorInset * 2;
  late final AnimationController _controller;
  late Listenable _indicatorRepaint;
  Widget? _cachedItems;
  int? _cachedItemsIndex;
  bool? _cachedItemsDark;
  double _itemWidth = 0;
  List<_IndicatorFrame> _frames = const [];
  _IndicatorFrame? _swipeOrigin;
  double _swipePageOrigin = 0;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 560),
    );
    _indicatorRepaint = Listenable.merge([_controller, widget.pagePosition]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _controller.stop();
      _frames = const [];
    }
  }

  double get _restWidth => math.max(
      _indicatorHeight, _itemWidth + (_contentInset - _indicatorInset) * 2);
  double _center(int index) => (index + .5) * _itemWidth;

  _IndicatorFrame _swipeFrame(LiquidDock config) {
    final position = config.pagePosition.value
        .clamp(0.0, LiquidDock.items.length - 1.0)
        .toDouble();
    final start =
        _swipePageOrigin.clamp(0.0, LiquidDock.items.length - 1.0).toDouble();
    final origin = _swipeOrigin ??
        _IndicatorFrame(0, _center(config.currentIndex), _restWidth);
    final travel = (position - start).abs();
    final blend = (travel / .35).clamp(0.0, 1.0).toDouble();
    final center = (position + .5) * _itemWidth;
    final originOffset = origin.center - (start + .5) * _itemWidth;
    final fraction = position - position.floorToDouble();
    final width = _restWidth * (1 + math.sin(fraction * math.pi) * .72);
    return _IndicatorFrame(
      0,
      center + originOffset * (1 - blend),
      lerpDouble(origin.width, width, blend)!,
    );
  }

  _IndicatorFrame _animationFrame() {
    final progress = _easeCurve.transform(_controller.value);
    for (var i = 0; i < _frames.length - 1; i++) {
      final from = _frames[i];
      final to = _frames[i + 1];
      if (progress <= to.offset) {
        final t = ((progress - from.offset) / (to.offset - from.offset))
            .clamp(0.0, 1.0)
            .toDouble();
        return _IndicatorFrame(
          progress,
          lerpDouble(from.center, to.center, t)!,
          lerpDouble(from.width, to.width, t)!,
        );
      }
    }
    return _frames.last;
  }

  _IndicatorFrame _currentFrame(LiquidDock config) {
    if (config.isSwiping) return _swipeFrame(config);
    if (_frames.isNotEmpty) return _animationFrame();
    return _IndicatorFrame(0, _center(config.currentIndex), _restWidth);
  }

  @override
  void didUpdateWidget(covariant LiquidDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.pagePosition, oldWidget.pagePosition)) {
      _indicatorRepaint = Listenable.merge([_controller, widget.pagePosition]);
    }
    if (widget.isSwiping) {
      if (!oldWidget.isSwiping) {
        _swipeOrigin = _currentFrame(oldWidget);
        _swipePageOrigin = widget.pagePosition.value;
      }
      _controller.stop();
      _frames = const [];
    } else if (widget.currentIndex != oldWidget.currentIndex ||
        widget.settleRevision != oldWidget.settleRevision ||
        oldWidget.isSwiping) {
      // Continue from the actual stretched shape, also on rapid taps.
      final from = _currentFrame(oldWidget);
      _animateToTab(widget.currentIndex, from);
      _swipeOrigin = null;
    }
  }

  void _animateToTab(int targetIndex, _IndicatorFrame from) {
    _controller.stop();
    final to = _center(targetIndex);
    final size = _restWidth;
    final delta = to - from.center;
    final direction = delta.sign;
    if (_itemWidth == 0 ||
        _reduceMotion ||
        (delta.abs() < .2 && (from.width - size).abs() < .2)) {
      _frames = const [];
      return;
    }
    final stretch = 1 + math.min(delta.abs() / size * .7, 1.65);
    _frames = [
      _IndicatorFrame(0, from.center, from.width),
      _IndicatorFrame(.30, from.center + delta * .36, size * stretch),
      _IndicatorFrame(.55, to + direction * 3, size * 1.14),
      _IndicatorFrame(.72, to - direction * 1.4, size),
      _IndicatorFrame(.87, to + direction * .5, size * 1.035),
      _IndicatorFrame(1, to, size),
    ];
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _IndicatorFrame _paintFrame() => _currentFrame(widget);

  Widget _navigationItems() {
    if (_cachedItems != null &&
        _cachedItemsIndex == widget.currentIndex &&
        _cachedItemsDark == widget.isDark) {
      return _cachedItems!;
    }
    _cachedItemsIndex = widget.currentIndex;
    _cachedItemsDark = widget.isDark;
    final selectedInk = widget.isDark ? Colors.white : const Color(0xFF141416);
    final muted = widget.isDark ? AppTheme.darkMuted : AppTheme.lightMuted;
    return _cachedItems = RepaintBoundary(
      child: Row(
        children: List.generate(LiquidDock.items.length, (index) {
          final selected = widget.currentIndex == index;
          final color = selected ? selectedInk : muted;
          return Expanded(
            child: Semantics(
              button: true,
              selected: selected,
              label: LiquidDock.items[index].label,
              onTap: () => widget.onTabSelected(index),
              excludeSemantics: true,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  overlayColor: Colors.transparent,
                  shape: const StadiumBorder(),
                ),
                onPressed: () => widget.onTabSelected(index),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    LiquidSymbol(index: index, color: color),
                    const SizedBox(height: 2),
                    Text(
                      LiquidDock.items[index].label,
                      style: TextStyle(
                        fontSize: 9,
                        height: 1.2,
                        fontWeight: FontWeight.w400,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final delta = event.logicalKey == LogicalKeyboardKey.arrowRight
            ? 1
            : event.logicalKey == LogicalKeyboardKey.arrowLeft
                ? -1
                : 0;
        if (delta == 0) return KeyEventResult.ignored;
        widget.onTabSelected((widget.currentIndex + delta)
            .clamp(0, LiquidDock.items.length - 1)
            .toInt());
        return KeyEventResult.handled;
      },
      child: LiquidGlassSurface(
        isDark: widget.isDark,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = (constraints.maxWidth - _contentInset * 2) /
                LiquidDock.items.length;
            if ((_itemWidth - itemWidth).abs() > .01) {
              _controller.stop();
              _frames = const [];
              _itemWidth = itemWidth;
            }
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _DockIndicatorPainter(
                      frame: _paintFrame,
                      repaint: _indicatorRepaint,
                      contentInset: _contentInset,
                      indicatorInset: _indicatorInset,
                      indicatorHeight: _indicatorHeight,
                      color: widget.isDark
                          ? AppTheme.darkIndicator
                          : AppTheme.lightIndicator,
                    ),
                  ),
                ),
                Positioned.fill(
                  top: 4,
                  bottom: 4,
                  left: _contentInset,
                  right: _contentInset,
                  child: _navigationItems(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The selected capsule repaints independently of the glass and tab contents.
class _DockIndicatorPainter extends CustomPainter {
  _DockIndicatorPainter({
    required this.frame,
    required Listenable repaint,
    required this.contentInset,
    required this.indicatorInset,
    required this.indicatorHeight,
    required Color color,
  })  : _fill = Paint()..color = color,
        super(repaint: repaint);

  final _IndicatorFrame Function() frame;
  final double contentInset;
  final double indicatorInset;
  final double indicatorHeight;
  final Paint _fill;

  @override
  void paint(Canvas canvas, Size size) {
    final current = frame();
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          contentInset + current.center - current.width / 2,
          indicatorInset,
          current.width,
          indicatorHeight,
        ),
        Radius.circular(indicatorHeight / 2),
      ),
      _fill,
    );
  }

  @override
  bool shouldRepaint(covariant _DockIndicatorPainter oldDelegate) => true;
}
