import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'cached_page_strip.dart';

typedef PageBuilder = Widget Function(int index);

class PhoneScreenStage extends StatefulWidget {
  const PhoneScreenStage({
    super.key,
    required this.currentIndex,
    required this.pageCount,
    required this.pageBuilder,
    this.pageCacheKey,
    required this.onPageChanged,
    this.onPagePositionChanged,
    this.onSwipeStart,
    this.onSwipeEnd,
    this.canSwipe = true,
  });

  final int currentIndex;
  final int pageCount;
  final PageBuilder pageBuilder;
  // Change this only when page configuration (such as appearance) changes.
  final Object? pageCacheKey;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<double>? onPagePositionChanged;
  final ValueChanged<double>? onSwipeStart;
  final ValueChanged<int>? onSwipeEnd;
  final bool canSwipe;

  @override
  State<PhoneScreenStage> createState() => PhoneScreenStageState();
}

class PhoneScreenStageState extends State<PhoneScreenStage>
    with SingleTickerProviderStateMixin {
  static const _pageCurve = Cubic(.2, .8, .2, 1);
  static const _bounceCurve = Cubic(.2, .9, .3, 1);
  late final AnimationController _controller;
  late List<Widget> _pages;
  final _paintPosition = ValueNotifier<double>(0);
  late int _selectedIndex;
  double _position = 0;
  double _motionFrom = 0;
  double _motionTo = 0;
  double _dragStartX = 0;
  double _dragStartRawPosition = 0;
  double _rawDragOffset = 0;
  int _dragAnchorIndex = 0;
  bool _dragPending = false;
  bool _dragInterruptedMotion = false;
  bool _isDragging = false;
  bool _isSettling = false;
  bool _reduceMotion = false;
  bool _notificationQueued = false;
  Curve _curve = _pageCurve;

  int get _lastIndex => widget.pageCount - 1;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.currentIndex;
    _position = _selectedIndex.toDouble();
    _paintPosition.value = _position;
    _rebuildPages();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )
      ..addListener(_tick)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && _isSettling) {
          setState(_completeMotion);
          _notifyPosition();
        }
      });
  }

  void _rebuildPages() {
    _pages = List.generate(
      widget.pageCount,
      (index) => RetainedStagePage(
        key: ValueKey(index),
        index: index,
        position: _paintPosition,
        child: RepaintBoundary(child: widget.pageBuilder(index)),
      ),
    );
  }

  @override
  void reassemble() {
    super.reassemble();
    _rebuildPages();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion && _isSettling) {
      _controller.stop();
      _completeMotion();
      _notifyPosition();
    }
  }

  @override
  void didUpdateWidget(covariant PhoneScreenStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageCount != oldWidget.pageCount ||
        widget.pageCacheKey != oldWidget.pageCacheKey) {
      _rebuildPages();
    }
    if (widget.currentIndex != _selectedIndex) {
      animateToTab(widget.currentIndex);
    }
  }

  void _tick() {
    if (!_isSettling) return;
    final progress = _curve.transform(_controller.value);
    _position = _motionFrom + (_motionTo - _motionFrom) * progress;
    _notifyPosition();
  }

  void _notifyPosition() {
    _paintPosition.value = _position;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notificationQueued) return;
      _notificationQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notificationQueued = false;
        if (mounted) widget.onPagePositionChanged?.call(_position);
      });
    } else {
      widget.onPagePositionChanged?.call(_position);
    }
  }

  void _completeMotion() {
    _position = _selectedIndex.toDouble();
    _isSettling = false;
    _isDragging = false;
    _dragPending = false;
    _dragInterruptedMotion = false;
    _rawDragOffset = 0;
  }

  /// Explicit cancellation is reserved for leaving the page or opening entry.
  void cancelMotion() {
    final hadGesture = _isDragging || (_dragPending && _dragInterruptedMotion);
    _controller.stop();
    setState(_completeMotion);
    _notifyPosition();
    if (hadGesture) widget.onSwipeEnd?.call(_selectedIndex);
  }

  /// Navigation taps also continue from the visible position.
  void animateToTab(int targetIndex) {
    if (targetIndex < 0 || targetIndex >= widget.pageCount) return;
    _startMotion(targetIndex, bounce: false);
  }

  void _startMotion(int targetIndex, {required bool bounce}) {
    _controller.stop();
    _motionFrom = _position;
    _motionTo = targetIndex.toDouble();
    _selectedIndex = targetIndex;
    _curve = bounce ? _bounceCurve : _pageCurve;
    _controller.duration = Duration(milliseconds: bounce ? 300 : 280);
    _isDragging = false;
    _dragPending = false;
    _dragInterruptedMotion = false;
    _isSettling = true;
    if (_reduceMotion || (_motionFrom - _motionTo).abs() < .0001) {
      setState(_completeMotion);
      _notifyPosition();
    } else {
      setState(() {});
      _controller.forward(from: 0);
    }
  }

  double _unresistedPosition(double position) {
    if (position < 0) return position / .2;
    if (position > _lastIndex) {
      return _lastIndex + (position - _lastIndex) / .2;
    }
    return position;
  }

  double _displayPosition(double rawPosition, double width) {
    if (rawPosition < 0) {
      return -math.min(-rawPosition * .2, 38 / width);
    }
    if (rawPosition > _lastIndex) {
      return _lastIndex + math.min((rawPosition - _lastIndex) * .2, 38 / width);
    }
    return rawPosition;
  }

  void _onHorizontalDragDown(DragDownDetails details, double width) {
    if (width <= 0) return;
    // Stop on contact, before gesture recognition, without settling or rebasing.
    final interruptedMotion = _isSettling ||
        _isDragging ||
        _controller.isAnimating ||
        (_position - _selectedIndex).abs() >= .0001;
    _controller.stop();
    _dragStartX = details.localPosition.dx;
    _dragStartRawPosition = _unresistedPosition(_position);
    _dragAnchorIndex = _position.round().clamp(0, _lastIndex).toInt();
    _rawDragOffset = 0;
    _dragPending = true;
    _dragInterruptedMotion = interruptedMotion;
    _isDragging = false;
    _isSettling = false;
    // A pointer down also precedes taps and vertical scrolling. At rest it
    // only records the drag origin; those gestures must not rebuild the shell
    // or put the dock into its horizontal-swipe state.
    if (interruptedMotion) {
      widget.onSwipeStart?.call(_position);
      setState(() {});
    }
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (!_dragPending) return;
    if (!_dragInterruptedMotion) widget.onSwipeStart?.call(_position);
    setState(() {
      _dragPending = false;
      _isDragging = true;
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details, double width) {
    if (!_isDragging || width <= 0) return;
    _rawDragOffset = details.localPosition.dx - _dragStartX;
    final movement = _rawDragOffset.clamp(-width, width).toDouble() / width;
    _position = _displayPosition(_dragStartRawPosition - movement, width);
    _notifyPosition();
  }

  void _finishDrag(double width,
      {bool cancelled = false, double velocity = 0}) {
    if ((!_isDragging && !_dragPending) || width <= 0) return;
    if (!_isDragging && !_dragInterruptedMotion) {
      // The horizontal recognizer lost to a tap or vertical scroll while the
      // page was already settled. There is no page/dock motion to complete.
      _dragPending = false;
      _rawDragOffset = 0;
      return;
    }
    final distance = _rawDragOffset.abs();
    final threshold = math.max(48.0, width * .18);
    final commit = !cancelled &&
        _isDragging &&
        (distance >= threshold || (distance > 28 && velocity.abs() > 500));
    var target = cancelled
        ? _selectedIndex
        : _position.round().clamp(0, _lastIndex).toInt();
    if (commit) {
      final direction = _rawDragOffset < 0 ? 1 : -1;
      target = (_dragAnchorIndex + direction).clamp(0, _lastIndex).toInt();
    }
    final bounce = !commit || target == _selectedIndex;
    _startMotion(target, bounce: bounce);
    if (target != widget.currentIndex) widget.onPageChanged(target);
    widget.onSwipeEnd?.call(target);
  }

  @override
  void dispose() {
    _controller.dispose();
    _paintPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragDown: widget.canSwipe
              ? (details) => _onHorizontalDragDown(details, width)
              : null,
          onHorizontalDragStart:
              widget.canSwipe ? _onHorizontalDragStart : null,
          onHorizontalDragUpdate: widget.canSwipe
              ? (details) => _onHorizontalDragUpdate(details, width)
              : null,
          onHorizontalDragEnd: widget.canSwipe
              ? (details) =>
                  _finishDrag(width, velocity: details.primaryVelocity ?? 0)
              : null,
          onHorizontalDragCancel: widget.canSwipe
              ? () => _finishDrag(width, cancelled: true)
              : null,
          child: ClipRect(
            child: CachedPageStrip(
              position: _paintPosition,
              ignoreContent: _isDragging || _isSettling,
              children: _pages,
            ),
          ),
        );
      },
    );
  }
}
