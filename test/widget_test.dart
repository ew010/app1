import 'package:app1/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('controller page renders key sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ControllerPage(autoRefresh: false)),
    );

    expect(find.text('Android Controller (adb + scrcpy)'), findsOneWidget);
    expect(find.text('Start scrcpy'), findsOneWidget);
    expect(
      find.text('Device IP:PORT (e.g. 192.168.1.10:5555)'),
      findsOneWidget,
    );
  });
}
