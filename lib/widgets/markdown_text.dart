import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// An agent's answer, written in Markdown, drawn as it reads: paragraphs,
/// headings, lists, quotes, code blocks set in the terminal's font, tables
/// kept in their columns, and inline code, bold, italic and links.
///
/// Small on purpose: it is parsed again for each piece of an answer as it
/// is written, a few times a second, so it does no more than agents write.
class MarkdownText extends StatelessWidget {
  final String text;
  final double size;

  const MarkdownText(this.text, {super.key, this.size = 15});

  static const mono = 'JetBrains Mono';

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final blocks = _parsedOf(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, b) in blocks.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : b.gapAbove(size)),
            child: b.build(context, p, size),
          ),
      ],
    );
  }

  /// The answers last drawn, parsed. Every item of a chat on screen is
  /// built again whenever its feed changes — each new item, each piece of
  /// an answer being written — and parsing each finished answer afresh
  /// every time was most of what that cost.
  static final _parsed = <String, List<_Block>>{};

  static List<_Block> _parsedOf(String text) {
    final kept = _parsed.remove(text);
    final blocks = kept ?? _blocks(text);
    _parsed[text] = blocks;
    if (_parsed.length > 200) _parsed.remove(_parsed.keys.first);
    return blocks;
  }

  static List<_Block> _blocks(String text) {
    final out = <_Block>[];
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final para = <String>[];
    void endPara() {
      if (para.isEmpty) return;
      out.add(_Para(para.join('\n')));
      para.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      final fence = RegExp(r'^(```+|~~~+)\s*(\S*)').firstMatch(trimmed);
      if (fence != null) {
        endPara();
        final close = fence[1]!;
        final code = <String>[];
        for (i++; i < lines.length; i++) {
          if (lines[i].trimLeft().startsWith(close)) break;
          code.add(lines[i]);
        }
        out.add(_Code(code.join('\n')));
        continue;
      }
      if (trimmed.isEmpty) {
        endPara();
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        endPara();
        out.add(_Heading(heading[1]!.length, heading[2]!));
        continue;
      }
      if (RegExp(r'^([-*_])(\s*\1){2,}\s*$').hasMatch(trimmed)) {
        endPara();
        out.add(const _Rule());
        continue;
      }
      if (trimmed.startsWith('|')) {
        endPara();
        final rows = <String>[];
        for (; i < lines.length && lines[i].trimLeft().startsWith('|'); i++) {
          rows.add(lines[i].trim());
        }
        i--;
        out.add(_Table(rows));
        continue;
      }
      if (trimmed.startsWith('>')) {
        endPara();
        final quoted = <String>[];
        for (; i < lines.length && lines[i].trimLeft().startsWith('>'); i++) {
          quoted.add(lines[i].trimLeft().replaceFirst(RegExp(r'^>\s?'), ''));
        }
        i--;
        out.add(_Quote(quoted.join('\n')));
        continue;
      }
      final item = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$').firstMatch(line);
      if (item != null) {
        endPara();
        final indent = item[1]!.replaceAll('\t', '    ').length ~/ 2;
        final mark = item[2]!;
        out.add(
          _Item(
            mark.length == 1 ? '•' : mark.replaceAll(')', '.'),
            item[3]!,
            indent.clamp(0, 4),
          ),
        );
        continue;
      }
      // A line under a list item, indented, carries the item on.
      if (para.isEmpty &&
          out.isNotEmpty &&
          out.last is _Item &&
          line.startsWith('  ')) {
        final last = out.removeLast() as _Item;
        out.add(_Item(last.mark, '${last.text}\n$trimmed', last.indent));
        continue;
      }
      para.add(line);
    }
    endPara();
    return out;
  }
}

abstract class _Block {
  const _Block();
  Widget build(BuildContext context, AppPalette p, double size);
  double gapAbove(double size) => size * 0.6;
}

class _Para extends _Block {
  final String text;
  const _Para(this.text);

  @override
  Widget build(BuildContext context, AppPalette p, double size) => Text.rich(
    inline(
      context,
      text,
      TextStyle(color: p.text, fontSize: size, height: 1.4),
    ),
  );
}

class _Heading extends _Block {
  final int level;
  final String text;
  const _Heading(this.level, this.text);

  @override
  double gapAbove(double size) => size * 0.9;

  @override
  Widget build(BuildContext context, AppPalette p, double size) => Text.rich(
    inline(
      context,
      text,
      TextStyle(
        color: p.text,
        fontSize:
            size +
            (level == 1
                ? 4
                : level == 2
                ? 2
                : 0.5),
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
    ),
  );
}

class _Item extends _Block {
  final String mark;
  final String text;
  final int indent;
  const _Item(this.mark, this.text, this.indent);

  @override
  double gapAbove(double size) => size * 0.3;

  @override
  Widget build(BuildContext context, AppPalette p, double size) {
    final style = TextStyle(color: p.text, fontSize: size, height: 1.4);
    return Padding(
      padding: EdgeInsets.only(left: indent * size * 1.2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: size * (mark == '•' ? 1.1 : 1.6),
            child: Text(mark, style: style.copyWith(color: p.muted)),
          ),
          Expanded(child: Text.rich(inline(context, text, style))),
        ],
      ),
    );
  }
}

class _Quote extends _Block {
  final String text;
  const _Quote(this.text);

  @override
  Widget build(BuildContext context, AppPalette p, double size) => Container(
    padding: const EdgeInsets.only(left: 10),
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: p.border, width: 3)),
    ),
    child: Text.rich(
      inline(
        context,
        text,
        TextStyle(color: p.muted, fontSize: size, height: 1.4),
      ),
    ),
  );
}

class _Rule extends _Block {
  const _Rule();

  @override
  Widget build(BuildContext context, AppPalette p, double size) =>
      Divider(height: size, thickness: 1, color: p.border);
}

/// A code block: its own lines kept, scrolled sideways rather than wrapped,
/// with a button that copies it whole.
class _Code extends _Block {
  final String code;
  const _Code(this.code);

  @override
  Widget build(BuildContext context, AppPalette p, double size) => Container(
    decoration: BoxDecoration(
      color: p.panel,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Stack(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 10, 36, 10),
          child: Text(
            code,
            style: TextStyle(
              fontFamily: MarkdownText.mono,
              fontSize: size - 2.5,
              height: 1.45,
              color: p.text,
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: Icon(Icons.copy_rounded, color: p.faint),
            tooltip: MaterialLocalizations.of(context).copyButtonLabel,
            onPressed: () {
              HapticFeedback.selectionClick();
              Clipboard.setData(ClipboardData(text: code));
            },
          ),
        ),
      ],
    ),
  );
}

/// A table, its cells laid out in columns as wide as their widest, scrolled
/// sideways if the screen is narrower; the line under the head left out.
class _Table extends _Block {
  final List<String> rows;
  const _Table(this.rows);

  static List<String> _cells(String row) {
    var r = row.trim();
    if (r.startsWith('|')) r = r.substring(1);
    if (r.endsWith('|')) r = r.substring(0, r.length - 1);
    return r.split('|').map((c) => c.trim()).toList();
  }

  @override
  Widget build(BuildContext context, AppPalette p, double size) {
    final cells = [
      for (final r in rows)
        if (!RegExp(r'^\|?[\s:|-]+\|?$').hasMatch(r)) _cells(r),
    ];
    if (cells.isEmpty) return const SizedBox.shrink();
    final columns = cells.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final style = TextStyle(color: p.text, fontSize: size - 1, height: 1.35);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: p.border, width: 0.8),
        children: [
          for (final (i, r) in cells.indexed)
            TableRow(
              decoration: i == 0 ? BoxDecoration(color: p.panel) : null,
              children: [
                for (var c = 0; c < columns; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: size * 18),
                      child: Text.rich(
                        inline(
                          context,
                          c < r.length ? r[c] : '',
                          i == 0
                              ? style.copyWith(fontWeight: FontWeight.w600)
                              : style,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

final _inline = RegExp(
  r'`([^`]+)`'
  r'|\*\*(.+?)\*\*'
  r'|__(.+?)__'
  r'|~~(.+?)~~'
  r'|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)'
  r'|(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)'
  r'|\[([^\]]+)\]\(([^)\s]+)\)',
);

/// [text]'s inline marks as spans over [base]: code in the terminal's font
/// on a raised grey, bold, italic, struck through, links underlined.
InlineSpan inline(BuildContext context, String text, TextStyle base) {
  final p = AppTheme.of(context);
  final spans = <InlineSpan>[];
  var at = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    at = m.end;
    if (m[1] != null) {
      spans.add(
        TextSpan(
          text: m[1],
          style: TextStyle(
            fontFamily: MarkdownText.mono,
            fontSize: (base.fontSize ?? 15) - 1.5,
            backgroundColor: p.panelHi,
          ),
        ),
      );
    } else if (m[2] != null || m[3] != null) {
      spans.add(
        TextSpan(
          children: [inline(context, m[2] ?? m[3]!, base)],
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      );
    } else if (m[4] != null) {
      spans.add(
        TextSpan(
          children: [inline(context, m[4]!, base)],
          style: const TextStyle(decoration: TextDecoration.lineThrough),
        ),
      );
    } else if (m[5] != null || m[6] != null) {
      spans.add(
        TextSpan(
          children: [inline(context, m[5] ?? m[6]!, base)],
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: m[7],
          style: const TextStyle(decoration: TextDecoration.underline),
        ),
      );
    }
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: base, children: spans);
}
