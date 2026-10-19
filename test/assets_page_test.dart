import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bookkeeping_app/pages/assets_page.dart';
import 'package:bookkeeping_app/widgets/liquid_glass_surface.dart';

void main() {
  testWidgets('AssetsPage renders standalone top assets card and 10 stacked cards, hides redundant elements', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    bool detailModeState = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssetsPage(
            isDark: true,
            onDetailModeChanged: (isOpen) => detailModeState = isOpen,
          ),
        ),
      ),
    );

    // 1. Verify redundant elements are removed
    expect(find.text('资产与卡包'), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);

    // 2. Verify standalone Top Asset Overview Card is present
    expect(find.text('净资产总值'), findsOneWidget);
    expect(find.text('总资产'), findsOneWidget);
    expect(find.text('总负债'), findsOneWidget);
    expect(find.text('资金账户与卡包'), findsOneWidget);
    expect(find.text('共 50 张'), findsOneWidget);

    // 3. Verify cards from the 10-card deck are present
    expect(find.text('中国银行 · 线条小狗金卡'), findsOneWidget);
    expect(find.text('微信支付 · 零钱通'), findsOneWidget);
    expect(find.text('支付宝 · 余额宝'), findsOneWidget);
    expect(find.text('HSBC 汇丰银行 · 卓越理财'), findsOneWidget);
    expect(find.text('Wise · 多币种国际卡'), findsOneWidget);
    expect(find.text('Suica · 西瓜交通卡'), findsOneWidget);
    expect(find.text('清华大学 · 校园一卡通'), findsOneWidget);
    expect(find.text('八达通 · 动漫限定 NFC 卡'), findsOneWidget);

    // 4. Tap on first card (中国银行 · 线条小狗金卡) to enter Detail view
    await tester.tap(find.text('中国银行 · 线条小狗金卡').first);
    await tester.pumpAndSettle();

    // Verify detailMode callback was triggered
    expect(detailModeState, isTrue);

    // Verify detail view components
    expect(find.text('账户当前余额'), findsOneWidget);
    expect(find.text('来自：中国银行'), findsOneWidget);
    expect(find.text('近期交易记录'), findsOneWidget);
    expect(find.text('星巴克秋季限定拿铁'), findsOneWidget);

    // Verify redundant 123/pin icon is removed in detail top bar
    expect(find.byIcon(Icons.pin_outlined), findsNothing);
    // Search and More icons remain in the merged capsule button
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    // Verify action buttons use the exact same LiquidGlassSurface as the navigation dock
    expect(find.byType(LiquidGlassSurface), findsNWidgets(2));

    // 5. Test that pinned buttons stay fixed when list scrolls
    final initialClosePosition = tester.getTopLeft(find.byIcon(Icons.close_rounded));
    final initialSearchPosition = tester.getTopLeft(find.byIcon(Icons.search_rounded));

    // Drag / scroll the list up
    await tester.drag(find.text('账户当前余额'), const Offset(0, -200));
    await tester.pumpAndSettle();

    final scrolledClosePosition = tester.getTopLeft(find.byIcon(Icons.close_rounded));
    final scrolledSearchPosition = tester.getTopLeft(find.byIcon(Icons.search_rounded));

    // The buttons must remain at the exact same position!
    expect(scrolledClosePosition, equals(initialClosePosition));
    expect(scrolledSearchPosition, equals(initialSearchPosition));

    // 6. Tap close button (✕) to exit Detail view
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    // Verify detailMode callback restored
    expect(detailModeState, isFalse);
    expect(find.text('资金账户与卡包'), findsOneWidget);
    expect(find.text('账户当前余额'), findsNothing);
  });

  testWidgets('AssetsPage works in light mode without issues', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssetsPage(isDark: false),
        ),
      ),
    );

    expect(find.text('净资产总值'), findsOneWidget);
    expect(find.text('资金账户与卡包'), findsOneWidget);

    await tester.tap(find.text('中国银行 · 线条小狗金卡').first);
    await tester.pumpAndSettle();

    expect(find.text('来自：中国银行'), findsOneWidget);
    expect(find.text('星巴克秋季限定拿铁'), findsOneWidget);
  });
}
