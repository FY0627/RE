import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'widgets/liquid_dock.dart';
import 'widgets/gesture_add_button.dart';
import 'widgets/entry_modal.dart';
import 'pages/home_page.dart';
import 'pages/assets_page.dart';
import 'pages/stats_page.dart';
import 'pages/profile_page.dart';
import 'widgets/phone_screen_stage.dart';
import 'widgets/account_detail_motion.dart';
import 'widgets/app_design_layout.dart';

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

void main() {
  runApp(const BookkeepingApp());
}

class BookkeepingApp extends StatefulWidget {
  const BookkeepingApp({super.key});

  @override
  State<BookkeepingApp> createState() => _BookkeepingAppState();
}

class _BookkeepingAppState extends State<BookkeepingApp> {
  bool _isDark = true;

  void _toggleTheme(bool isDark) {
    setState(() => _isDark = isDark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '日常记账',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => AppDesignLayout(child: child!),
      home: BookkeepingShell(
        isDark: _isDark,
        onThemeToggle: _toggleTheme,
      ),
    );
  }
}

class BookkeepingShell extends StatefulWidget {
  const BookkeepingShell({
    super.key,
    required this.isDark,
    required this.onThemeToggle,
  });

  final bool isDark;
  final ValueChanged<bool> onThemeToggle;

  @override
  State<BookkeepingShell> createState() => _BookkeepingShellState();
}

class _BookkeepingShellState extends State<BookkeepingShell> {
  int _currentIndex = 0;
  final _pagePosition = ValueNotifier<double>(0);
  bool _isPageSwiping = false;
  bool _isAddInteracting = false;
  int _dockSettleRevision = 0;
  bool _isAssetsDetailOpen = false;
  final _assetsDetailProgress = ValueNotifier<double>(0);
  final _stageKey = GlobalKey<PhoneScreenStageState>();

  void _onTabSelected(int index) {
    if (_isAssetsDetailOpen || _isAddInteracting) return;
    if (_currentIndex == index && !_isPageSwiping) return;
    _stageKey.currentState?.animateToTab(index);
    setState(() {
      _currentIndex = index;
      _isAssetsDetailOpen = false;
      _assetsDetailProgress.value = 0;
      _isPageSwiping = false;
      _dockSettleRevision++;
    });
  }

  Future<void> _openEntryModal() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EntryModal(isDark: widget.isDark),
    );
  }

  Widget _buildPage(int index) {
    switch (index) {
      case 0:
        return HomePage(isDark: widget.isDark);
      case 1:
        return AssetsPage(
          isDark: widget.isDark,
          onDetailModeChanged: (isOpen) {
            setState(() => _isAssetsDetailOpen = isOpen);
          },
          onDetailProgressChanged: (progress) {
            if (_currentIndex == 1) _assetsDetailProgress.value = progress;
          },
        );
      case 2:
        return StatsPage(isDark: widget.isDark);
      case 3:
      default:
        return ProfilePage(
          isDark: widget.isDark,
          onThemeToggle: widget.onThemeToggle,
        );
    }
  }

  @override
  void dispose() {
    _pagePosition.dispose();
    _assetsDetailProgress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appBg = widget.isDark ? AppTheme.darkBg : AppTheme.lightBg;
    final systemStyle =
        (widget.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: appBg,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemStyle,
      child: Scaffold(
        backgroundColor: appBg,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: _isAddInteracting,
                      child: PhoneScreenStage(
                        key: _stageKey,
                        currentIndex: _currentIndex,
                        canSwipe: !(_currentIndex == 1 && _isAssetsDetailOpen),
                        pageCount: 4,
                        pageCacheKey: widget.isDark,
                        onSwipeStart: (position) {
                          setState(() {
                            _isPageSwiping = true;
                            _pagePosition.value = position;
                          });
                        },
                        onPagePositionChanged: (position) {
                          _pagePosition.value = position;
                        },
                        onPageChanged: (newIndex) {
                          setState(() {
                            _currentIndex = newIndex;
                            if (newIndex != 1) {
                              _isAssetsDetailOpen = false;
                              _assetsDetailProgress.value = 0;
                            }
                          });
                        },
                        onSwipeEnd: (target) {
                          setState(() {
                            _currentIndex = target;
                            if (target != 1) {
                              _isAssetsDetailOpen = false;
                              _assetsDetailProgress.value = 0;
                            }
                            _isPageSwiping = false;
                            _dockSettleRevision++;
                          });
                        },
                        pageBuilder: _buildPage,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 24,
                    child: IgnorePointer(
                      ignoring: _isAddInteracting ||
                          (_currentIndex == 1 && _isAssetsDetailOpen),
                      child: Row(
                        children: [
                          Expanded(
                            child: ValueListenableBuilder<double>(
                              valueListenable: _assetsDetailProgress,
                              builder: (context, progress, child) {
                                final collapse =
                                    AccountDetailMotion.dockCollapse.transform(
                                        _currentIndex == 1 ? progress : 0);
                                return CenteredControlTransition(
                                  progress: 1 - collapse,
                                  retainTransformLayer:
                                      AccountDetailMotion.retainDockTransformLayer,
                                  deferOpaqueByOneFrame:
                                      AccountDetailMotion.deferDockOpaqueOneFrame,
                                  opacityDiagnosticLabel: 'dock',
                                  child: child!,
                                );
                              },
                              child: LiquidDock(
                                currentIndex: _currentIndex,
                                pagePosition: _pagePosition,
                                isSwiping: _isPageSwiping,
                                settleRevision: _dockSettleRevision,
                                onTabSelected: _onTabSelected,
                                isDark: widget.isDark,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          ValueListenableBuilder<double>(
                            valueListenable: _assetsDetailProgress,
                            builder: (context, progress, child) {
                              final collapse = AccountDetailMotion.dockCollapse
                                  .transform(_currentIndex == 1 ? progress : 0);
                              return CenteredControlTransition(
                                progress: 1 - collapse,
                                isCircular: true,
                                retainTransformLayer:
                                    AccountDetailMotion.retainDockTransformLayer,
                                deferOpaqueByOneFrame:
                                    AccountDetailMotion.deferAddOpaqueOneFrame,
                                opacityDiagnosticLabel: 'add',
                                child: child!,
                              );
                            },
                            child: GestureAddButton(
                              onTrigger: _openEntryModal,
                              isDark: widget.isDark,
                              screenHeight: constraints.maxHeight,
                              onInteractionChanged: (active) {
                                if (active)
                                  _stageKey.currentState?.cancelMotion();
                                setState(() {
                                  _isAddInteracting = active;
                                  if (active && _isPageSwiping) {
                                    _isPageSwiping = false;
                                    _dockSettleRevision++;
                                  }
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
