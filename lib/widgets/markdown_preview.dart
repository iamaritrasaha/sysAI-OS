import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Compact, single-line rendering for Markdown summaries in list cards.
///
/// Outcomes are stored as Markdown so the detail view can preserve headings,
/// emphasis, lists, and code. List cards intentionally render only the first
/// meaningful line, but still pass it through the Markdown renderer so raw
/// markers such as `###` and `**bold**` never leak into the UI.
class MarkdownPreview extends StatelessWidget {
  final String data;
  final TextStyle style;

  const MarkdownPreview({super.key, required this.data, required this.style});

  @override
  Widget build(BuildContext context) {
    final rawLine = data
        .split('\n')
        .map((value) => value.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (rawLine.isEmpty) return const SizedBox.shrink();

    // A list card is a one-line preview, so a heading marker should not turn
    // this small row into a full heading block with its own vertical margins.
    final line = rawLine.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
    final lineHeight = ((style.fontSize ?? 14) * 1.5).clamp(20.0, 24.0);

    final sheet = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: style,
      h1: style,
      h2: style,
      h3: style,
      blockSpacing: 0,
      pPadding: EdgeInsets.zero,
      h1Padding: EdgeInsets.zero,
      h2Padding: EdgeInsets.zero,
      h3Padding: EdgeInsets.zero,
      listIndent: 0,
    );
    return ClipRect(
      child: SizedBox(
        height: lineHeight,
        child: MarkdownBody(
          data: line,
          shrinkWrap: true,
          fitContent: true,
          styleSheet: sheet,
        ),
      ),
    );
  }
}
