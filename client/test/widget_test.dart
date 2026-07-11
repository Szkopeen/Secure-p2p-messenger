import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('basic Flutter shell renders', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('Secure P2P'),
        ),
      ),
    );

    expect(find.text('Secure P2P'), findsOneWidget);
  });
}
