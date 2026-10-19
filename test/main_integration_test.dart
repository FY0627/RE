import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bookkeeping_app/main.dart';
import 'package:bookkeeping_app/widgets/liquid_dock.dart';

void main() {
  testWidgets('Dock hides when entering assets detail and restores on close', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              height: 720,
              child: PhoneDeviceFrame(
                isDark: true,
                initialTab: 1, // 直接启动在资产 Tab
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 确认在一级堆叠界面下，Dock 是正常显示的
    expect(find.byType(LiquidDock), findsOneWidget);

    // 2. 点击卡片进入二级详情页
    await tester.tap(find.text('中国银行 · 线条小狗金卡').first);
    await tester.pumpAndSettle();

    // 确认进入二级界面
    expect(find.text('账户当前余额'), findsOneWidget);

    // 3. 点击 ✕ 关闭按钮返回
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    // 确认返回一级界面
    expect(find.text('净资产总值'), findsOneWidget);
  });

  testWidgets('Horizontal drag in assets detail does not switch tabs, right swipe pops detail', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              height: 720,
              child: PhoneDeviceFrame(
                isDark: true,
                initialTab: 1,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 进入二级详情页
    await tester.tap(find.text('中国银行 · 线条小狗金卡').first);
    await tester.pumpAndSettle();
    expect(find.text('账户当前余额'), findsOneWidget);

    // 尝试向左滑动（之前会导致切到统计 Tab）
    await tester.fling(find.text('账户当前余额'), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();

    // 验证：绝对不会切到统计页，依然停留在详情页
    expect(find.text('账户当前余额'), findsOneWidget);
    expect(find.text('收支走势分析'), findsNothing);

    // 尝试向右滑动手势（返回上一级）
    await tester.fling(find.text('账户当前余额'), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();

    // 验证：成功退回一级堆叠卡片，并且恢复主界面
    expect(find.text('净资产总值'), findsOneWidget);
    expect(find.text('账户当前余额'), findsNothing);
  });
}
