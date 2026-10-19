import 'package:bookkeeping_app/app/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App builds', (tester) async {
    await tester.pumpWidget(const App());
    expect(find.text('项目骨架'), findsOneWidget);
  });
}
