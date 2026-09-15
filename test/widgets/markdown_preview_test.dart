import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sysai/adwaita.dart';
import 'package:sysai/widgets/markdown_preview.dart';

void main() {
  testWidgets('renders the first Markdown summary line without syntax markers', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: adwaitaDarkTheme(),
        home: const SizedBox(
          width: 500,
          child: MarkdownPreview(
            data: '### Execution Summary\n\n✓ **Run completed**',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Execution Summary'), findsOneWidget);
    expect(find.textContaining('###'), findsNothing);
  });
}
