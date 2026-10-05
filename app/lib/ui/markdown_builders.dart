// Rich markdown rendering for chat bubbles.
//
// Rendering behaviors (sortable tables, collapsible code blocks, tappable
// task lists, Obsidian-style callouts, colored diffs, mermaid viewer) are
// ported from the MIT-licensed hermes-mobile-app by Omar Qaterge
// (https://github.com/omarqaterge/hermes-mobile-app —
// web/src/components/Markdown.tsx and web/src/components/Diff.tsx) and
// reimplemented natively in Flutter. KaTeX math is rendered with
// flutter_math_fork.
//
// Stability contract: plain markdown rendering is unchanged. Tables,
// callouts and display-math blocks are extracted from the source before
// parsing (flutter_markdown renders tables itself with no override hook,
// so extraction is the only clean interception point); everything else is
// additive custom element builders / inline syntax on top of the existing
// flutter_markdown pipeline.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ── Segments ────────────────────────────────────────────────────────────────
// A chat message is split into segments before rendering: plain markdown
// runs through MarkdownBody; tables, callouts and display-math get their
// own widgets.

/// A chunk of a chat message after rich-block extraction.
sealed class RichSegment {}

/// Plain markdown, rendered by [MarkdownBody].
class TextSegment extends RichSegment {
  TextSegment(this.markdown);
  final String markdown;
}

/// A GFM table: sortable headers + TSV copy.
class TableSegment extends RichSegment {
  TableSegment({
    required this.headers,
    required this.rows,
    required this.aligns,
  });
  final List<String> headers;
  final List<List<String>> rows;
  final List<TextAlign> aligns;
}

/// An Obsidian-style callout (`> [!note] Title`).
class CalloutSegment extends RichSegment {
  CalloutSegment({
    required this.kind,
    required this.title,
    required this.body,
    required this.foldable,
    required this.open,
  });
  final String kind;
  final String title;

  /// Inner markdown (blockquote markers stripped).
  final String body;
  final bool foldable;
  final bool open;
}

/// A `$$...$$` display-math block, rendered with flutter_math_fork.
class MathBlockSegment extends RichSegment {
  MathBlockSegment(this.tex);
  final String tex;
}

final _fencePattern = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
final _calloutPattern = RegExp(
  r'^\s{0,3}>\s*\[!([a-zA-Z-]+)\]\s*([+-])?\s*(.*)$',
  caseSensitive: false,
);
final _blockquoteLine = RegExp(r'^\s{0,3}>');
final _blockquoteStrip = RegExp(r'^\s{0,3}>\s?');
final _mathBlockOpen = RegExp(r'^\s{0,3}\$\$');

/// Obsidian callout kinds (+ GitHub alert aliases). Unknown kinds fall back
/// to `note` styling.
const _calloutKinds = <String>{
  'note',
  'abstract',
  'summary',
  'tldr',
  'info',
  'todo',
  'tip',
  'hint',
  'important',
  'success',
  'check',
  'done',
  'question',
  'help',
  'faq',
  'warning',
  'caution',
  'attention',
  'failure',
  'fail',
  'missing',
  'danger',
  'error',
  'bug',
  'example',
  'quote',
  'cite',
};

bool _isTableDelimiter(String line) {
  final t = line.trim();
  if (t.isEmpty || !t.contains('-')) return false;
  if (RegExp(r'[^|\-:\s]').hasMatch(t)) return false;
  final cells =
      t.split('|').map((c) => c.trim()).where((c) => c.isNotEmpty);
  if (cells.isEmpty) return false;
  return cells.every((c) => RegExp(r'^:?-+:?$').hasMatch(c));
}

/// Split a table row on unescaped pipes (`\|` stays literal).
List<String> _splitRow(String line) {
  final cells = <String>[];
  final buf = StringBuffer();
  var i = 0;
  while (i < line.length) {
    final ch = line[i];
    if (ch == r'\') {
      if (i + 1 < line.length) {
        buf.write(line[i + 1]);
        i += 2;
        continue;
      }
    }
    if (ch == '|') {
      cells.add(buf.toString().trim());
      buf.clear();
      i++;
      continue;
    }
    buf.write(ch);
    i++;
  }
  cells.add(buf.toString().trim());
  // Drop the empty cells implied by leading/trailing pipes.
  if (cells.isNotEmpty && cells.first.isEmpty) cells.removeAt(0);
  if (cells.isNotEmpty && cells.last.isEmpty) cells.removeLast();
  return cells;
}

List<TextAlign> _parseAligns(String delimiterLine, int count) {
  final cells = _splitRow(delimiterLine);
  return List<TextAlign>.generate(count, (i) {
    final c = i < cells.length ? cells[i].trim() : '';
    if (c.length > 2 && c.startsWith(':') && c.endsWith(':')) {
      return TextAlign.center;
    }
    if (c.endsWith(':')) return TextAlign.right;
    return TextAlign.left;
  });
}

/// Split [source] into rich segments. Fenced code blocks are never
/// scanned (tables/callouts/math inside code stay literal).
List<RichSegment> segmentMarkdown(String source) {
  final segments = <RichSegment>[];
  final lines = source.split('\n');
  final textBuf = StringBuffer();

  void flushText() {
    final t = textBuf.toString();
    if (t.trim().isNotEmpty) segments.add(TextSegment(t));
    textBuf.clear();
  }

  var inFence = false;
  var fenceChar = '';
  var fenceLen = 0;
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final fence = _fencePattern.firstMatch(line);
    if (fence != null) {
      final marker = fence.group(1)!;
      if (!inFence) {
        inFence = true;
        fenceChar = marker[0];
        fenceLen = marker.length;
      } else if (marker[0] == fenceChar && marker.length >= fenceLen) {
        inFence = false;
      }
      textBuf.writeln(line);
      i++;
      continue;
    }
    if (!inFence) {
      // Display math: a line starting with $$, up to the closing $$.
      if (_mathBlockOpen.hasMatch(line)) {
        flushText();
        final buf = StringBuffer();
        var rest = line.replaceFirst(_mathBlockOpen, '');
        while (true) {
          final closeIdx = rest.indexOf(r'$$');
          if (closeIdx >= 0) {
            buf.write(rest.substring(0, closeIdx));
            break;
          }
          buf.writeln(rest);
          i++;
          if (i >= lines.length) break;
          rest = lines[i];
        }
        segments.add(MathBlockSegment(buf.toString().trim()));
        i++;
        continue;
      }
      // Obsidian callout: > [!kind] Title, then contiguous > lines.
      final cm = _calloutPattern.firstMatch(line);
      if (cm != null) {
        flushText();
        var kind = cm.group(1)!.toLowerCase();
        if (!_calloutKinds.contains(kind)) kind = 'note';
        final fold = cm.group(2);
        final title = (cm.group(3) ?? '').trim();
        final bodyLines = <String>[];
        i++;
        while (i < lines.length && _blockquoteLine.hasMatch(lines[i])) {
          bodyLines.add(lines[i].replaceFirst(_blockquoteStrip, ''));
          i++;
        }
        segments.add(CalloutSegment(
          kind: kind,
          title: title.isEmpty
              ? kind[0].toUpperCase() + kind.substring(1)
              : title,
          body: bodyLines.join('\n'),
          foldable: fold != null,
          open: fold != '-',
        ));
        continue;
      }
      // GFM table: a pipe row followed by a delimiter row.
      if (line.contains('|') &&
          i + 1 < lines.length &&
          _isTableDelimiter(lines[i + 1])) {
        flushText();
        final headers = _splitRow(line);
        final aligns = _parseAligns(lines[i + 1], headers.length);
        final rows = <List<String>>[];
        i += 2;
        while (i < lines.length &&
            lines[i].trim().isNotEmpty &&
            lines[i].contains('|')) {
          final row = _splitRow(lines[i]);
          while (row.length < headers.length) {
            row.add('');
          }
          rows.add(row);
          i++;
        }
        segments.add(
            TableSegment(headers: headers, rows: rows, aligns: aligns));
        continue;
      }
    }
    textBuf.writeln(line);
    i++;
  }
  flushText();
  return segments;
}

// ── Sortable table ──────────────────────────────────────────────────────────

/// A markdown table with tappable sortable column headers and a
/// "Copy table" button (copies as TSV).
class SortableTable extends StatefulWidget {
  const SortableTable({
    super.key,
    required this.headers,
    required this.rows,
    required this.aligns,
    required this.textColor,
  });

  final List<String> headers;
  final List<List<String>> rows;
  final List<TextAlign> aligns;
  final Color textColor;

  @override
  State<SortableTable> createState() => _SortableTableState();
}

class _SortableTableState extends State<SortableTable> {
  int? _sortCol;
  bool _ascending = true;
  bool _copied = false;
  Timer? _copyTimer;

  static final _numCheck = RegExp(r'^[-+]?[\d.,\s$€£%]+$');
  static final _numClean = RegExp(r'[,\s$€£%]');

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  double? _asNumber(String t) {
    if (!_numCheck.hasMatch(t.trim())) return null;
    return double.tryParse(t.replaceAll(_numClean, ''));
  }

  String _cell(int row, int col) =>
      col < widget.rows[row].length ? widget.rows[row][col] : '';

  List<int> _order() {
    final idx = List<int>.generate(widget.rows.length, (k) => k);
    final c = _sortCol;
    if (c == null) return idx;
    idx.sort((a, b) {
      final x = _cell(a, c);
      final y = _cell(b, c);
      final nx = _asNumber(x);
      final ny = _asNumber(y);
      final cmp = (nx != null && ny != null)
          ? nx.compareTo(ny)
          : x.toLowerCase().compareTo(y.toLowerCase());
      return _ascending ? cmp : -cmp;
    });
    return idx;
  }

  Future<void> _copyTsv() async {
    final buf = StringBuffer()
      ..writeln(widget.headers.join('\t'));
    for (final row in widget.rows) {
      buf.writeln(row.join('\t'));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    setState(() => _copied = true);
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Alignment _cellAlignment(int col) {
    final a = col < widget.aligns.length ? widget.aligns[col] : TextAlign.left;
    return switch (a) {
      TextAlign.center => Alignment.center,
      TextAlign.right => Alignment.centerRight,
      _ => Alignment.centerLeft,
    };
  }

  void _toggleSort(int i) {
    setState(() {
      if (_sortCol != i) {
        _sortCol = i;
        _ascending = true;
      } else if (_ascending) {
        _ascending = false;
      } else {
        _sortCol = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final order = _order();
    final color = widget.textColor;
    final headerStyle = TextStyle(
      fontWeight: FontWeight.bold,
      color: color,
      fontSize: 13,
    );
    final cellStyle = TextStyle(color: color, fontSize: 13);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _copyTsv,
              child: Text(
                _copied ? 'Copied' : 'Copy table',
                style: TextStyle(
                  fontSize: 12,
                  color: color.withValues(alpha: 0.75),
                ),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              border: TableBorder(
                horizontalInside: BorderSide(
                  color: color.withValues(alpha: 0.12),
                ),
              ),
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.08),
                  ),
                  children: [
                    for (var i = 0; i < widget.headers.length; i++)
                      _SortHeaderCell(
                        label: widget.headers[i],
                        alignment: _cellAlignment(i),
                        sorted: _sortCol == i,
                        ascending: _ascending,
                        style: headerStyle,
                        dim: color.withValues(alpha: 0.6),
                        onTap: () => _toggleSort(i),
                      ),
                  ],
                ),
                for (var k = 0; k < order.length; k++)
                  TableRow(
                    decoration: k.isOdd
                        ? BoxDecoration(
                            color: color.withValues(alpha: 0.04),
                          )
                        : null,
                    children: [
                      for (var i = 0; i < widget.headers.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          child: Align(
                            alignment: _cellAlignment(i),
                            child: Text(
                              _cell(order[k], i),
                              style: cellStyle,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tappable table header cell with a sort indicator (⇅ / ▲ / ▼).
class _SortHeaderCell extends StatelessWidget {
  const _SortHeaderCell({
    required this.label,
    required this.alignment,
    required this.sorted,
    required this.ascending,
    required this.style,
    required this.dim,
    required this.onTap,
  });

  final String label;
  final Alignment alignment;
  final bool sorted;
  final bool ascending;
  final TextStyle style;
  final Color dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Align(
          alignment: alignment,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label, style: style)),
              const SizedBox(width: 4),
              Text(
                sorted ? (ascending ? '▲' : '▼') : '⇅',
                style: TextStyle(fontSize: 10, color: dim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Callout card ────────────────────────────────────────────────────────────

/// Accent color + icon for an Obsidian callout kind.
(Color, IconData) _calloutLook(String kind) {
  switch (kind) {
    case 'tip':
    case 'hint':
      return (Colors.green, Icons.lightbulb_outline);
    case 'success':
    case 'check':
    case 'done':
      return (Colors.green, Icons.check_circle_outline);
    case 'question':
    case 'help':
    case 'faq':
      return (Colors.amber, Icons.help_outline);
    case 'warning':
    case 'caution':
    case 'attention':
      return (Colors.orange, Icons.warning_amber_outlined);
    case 'failure':
    case 'fail':
    case 'missing':
      return (Colors.red, Icons.cancel_outlined);
    case 'danger':
    case 'error':
      return (Colors.red, Icons.error_outline);
    case 'bug':
      return (Colors.red, Icons.bug_report_outlined);
    case 'example':
      return (Colors.purple, Icons.code_outlined);
    case 'quote':
    case 'cite':
      return (Colors.grey, Icons.format_quote_outlined);
    case 'abstract':
    case 'summary':
    case 'tldr':
      return (Colors.teal, Icons.article_outlined);
    case 'todo':
      return (Colors.blue, Icons.checklist_outlined);
    case 'info':
      return (Colors.lightBlue, Icons.info_outline);
    case 'important':
      return (Colors.deepOrange, Icons.priority_high_outlined);
    default:
      return (Colors.blue, Icons.info_outline);
  }
}

/// Colored callout card for `> [!kind] Title` blocks. The body renders with
/// the same rich pipeline (nested code blocks, tables, etc. work inside).
class _CalloutCard extends StatefulWidget {
  const _CalloutCard({
    required this.kind,
    required this.title,
    required this.bodyMarkdown,
    required this.foldable,
    required this.initiallyOpen,
    required this.config,
  });

  final String kind;
  final String title;
  final String bodyMarkdown;
  final bool foldable;
  final bool initiallyOpen;
  final _RichConfig config;

  @override
  State<_CalloutCard> createState() => _CalloutCardState();
}

class _CalloutCardState extends State<_CalloutCard> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final (accent, icon) = _calloutLook(widget.kind);
    final hasBody = widget.bodyMarkdown.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: accent, width: 4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap:
                widget.foldable ? () => setState(() => _open = !_open) : null,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: accent,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (widget.foldable)
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: accent,
                    ),
                ],
              ),
            ),
          ),
          if (_open && hasBody)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: _SegmentList(
                segments: segmentMarkdown(widget.bodyMarkdown),
                config: widget.config,
              ),
            ),
        ],
      ),
    );
  }
}

// ── Code blocks ─────────────────────────────────────────────────────────────

/// Copy button with "copied" feedback, shared by code/diff/mermaid blocks.
class _CopyIconButton extends StatefulWidget {
  const _CopyIconButton({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  State<_CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<_CopyIconButton> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _copy,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          _copied ? Icons.check : Icons.copy_outlined,
          size: 16,
          color: widget.color.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

TextStyle _monoStyle(Color color) => TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.4,
      color: color,
    );

/// Shared chrome for code-like blocks: language label + copy button.
class _CodeChrome extends StatelessWidget {
  const _CodeChrome({
    required this.code,
    required this.textColor,
    required this.language,
    required this.child,
    this.footer,
  });

  final String code;
  final Color textColor;
  final String language;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (language.isNotEmpty)
                Text(
                  language,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: textColor.withValues(alpha: 0.55),
                  ),
                ),
              const Spacer(),
              _CopyIconButton(text: code, color: textColor),
            ],
          ),
          child,
          footer ?? const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// Fenced code block: routes to mermaid / diff / collapsible / plain.
class RichCodeBlockBuilder extends MarkdownElementBuilder {
  RichCodeBlockBuilder({required this.textColor});

  final Color textColor;

  /// Blocks longer than this render collapsed.
  static const collapseThreshold = 15;

  /// Number of lines shown before the "Show more" toggle.
  static const previewLines = 15;

  String _language(md.Element element) {
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        final cls = child.attributes['class'] ?? '';
        final m = RegExp(r'language-([\w-]+)').firstMatch(cls);
        if (m != null) return m.group(1)!;
      }
    }
    return '';
  }

  /// flutter_markdown routes the code text through the registered `pre`
  /// builder's [visitText]; the default implementation returns null, which
  /// leaves the inline stack unbalanced and trips a debug assert
  /// (`_inlines.isEmpty`). Returning the text keeps the stack balanced —
  /// the widget itself is discarded in [visitElementAfter], which rebuilds
  /// the block from [md.Element.textContent].
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      Text(text.text);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    var code = element.textContent;
    if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }
    final lang = _language(element).toLowerCase();
    if (lang == 'mermaid') {
      return _MermaidBlock(source: code, textColor: textColor);
    }
    final isDiff =
        lang == 'diff' || lang == 'patch' || looksLikeDiff(code);
    if (isDiff) {
      return _DiffBlock(code: code, textColor: textColor);
    }
    final lines = code.split('\n');
    if (lines.length > collapseThreshold) {
      return _CollapsibleCodeBlock(
        code: code,
        textColor: textColor,
        language: lang,
      );
    }
    return _CodeChrome(
      code: code,
      textColor: textColor,
      language: lang,
      child: SelectableText(code, style: _monoStyle(textColor)),
    );
  }
}

/// Long code block: first 15 lines + "Show more (N lines)" toggle.
class _CollapsibleCodeBlock extends StatefulWidget {
  const _CollapsibleCodeBlock({
    required this.code,
    required this.textColor,
    required this.language,
  });

  final String code;
  final Color textColor;
  final String language;

  @override
  State<_CollapsibleCodeBlock> createState() => _CollapsibleCodeBlockState();
}

class _CollapsibleCodeBlockState extends State<_CollapsibleCodeBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.code.split('\n');
    final hidden = lines.length - RichCodeBlockBuilder.previewLines;
    final shown = _open
        ? widget.code
        : lines.take(RichCodeBlockBuilder.previewLines).join('\n');
    return _CodeChrome(
      code: widget.code,
      textColor: widget.textColor,
      language: widget.language,
      footer: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => setState(() => _open = !_open),
          child: Text(
            _open ? 'Show less' : 'Show more ($hidden lines)',
            style: TextStyle(
              fontSize: 12,
              color: widget.textColor.withValues(alpha: 0.75),
            ),
          ),
        ),
      ),
      child: SelectableText(shown, style: _monoStyle(widget.textColor)),
    );
  }
}

// ── Colored diffs ───────────────────────────────────────────────────────────
// Ported from hermes-mobile-app (MIT) web/src/components/Diff.tsx.

/// Strip ANSI color codes (Hermes renders inline diffs for its terminal UI).
String stripAnsi(String t) =>
    t.replaceAll(RegExp('\x1b\\[[0-9;?]*[A-Za-z]'), '');

/// True when the text reads like a unified diff.
bool looksLikeDiff(String raw) {
  final text = stripAnsi(raw);
  if (!RegExp(r'^(@@ .* @@|diff --git |--- \S)', multiLine: true)
      .hasMatch(text)) {
    return false;
  }
  return RegExp(r'^[+-](?![+-]{2} )', multiLine: true).hasMatch(text);
}

enum _DiffLineClass { hunk, file, add, del, warn, meta, ctx }

_DiffLineClass _diffLineClass(String l) {
  if (l.startsWith('@@')) return _DiffLineClass.hunk;
  if (l.startsWith('┊')) return _DiffLineClass.meta;
  if (RegExp(r'^a\/.* → b\/').hasMatch(l)) return _DiffLineClass.file;
  if (RegExp(
          r'^(diff --git |index |--- |\+\+\+ |new file mode|deleted file mode|similarity index|rename (from|to) )')
      .hasMatch(l)) {
    return _DiffLineClass.file;
  }
  if (l.startsWith('+')) return _DiffLineClass.add;
  if (l.startsWith('-')) return _DiffLineClass.del;
  if (l.startsWith('!')) return _DiffLineClass.warn;
  if (l.startsWith(r'\')) return _DiffLineClass.meta;
  return _DiffLineClass.ctx;
}

/// ```diff block: green/red rows, blue hunk headers, bold file headers,
/// yellow `!` lines. Long diffs collapse like long code blocks.
class _DiffBlock extends StatefulWidget {
  const _DiffBlock({required this.code, required this.textColor});

  final String code;
  final Color textColor;

  @override
  State<_DiffBlock> createState() => _DiffBlockState();
}

class _DiffBlockState extends State<_DiffBlock> {
  bool _open = false;

  static const _maxChars = 20000;

  Color? _rowColor(_DiffLineClass c) {
    switch (c) {
      case _DiffLineClass.add:
        return Colors.green.withValues(alpha: 0.16);
      case _DiffLineClass.del:
        return Colors.red.withValues(alpha: 0.16);
      case _DiffLineClass.hunk:
        return Colors.blue.withValues(alpha: 0.14);
      case _DiffLineClass.warn:
        return Colors.amber.withValues(alpha: 0.18);
      case _DiffLineClass.file:
      case _DiffLineClass.meta:
      case _DiffLineClass.ctx:
        return null;
    }
  }

  TextStyle _lineStyle(_DiffLineClass c) {
    final base = _monoStyle(widget.textColor);
    switch (c) {
      case _DiffLineClass.hunk:
        return base.copyWith(
          color: Colors.lightBlue,
          fontWeight: FontWeight.bold,
        );
      case _DiffLineClass.file:
        return base.copyWith(fontWeight: FontWeight.bold);
      case _DiffLineClass.meta:
        return base.copyWith(
          color: widget.textColor.withValues(alpha: 0.55),
        );
      case _DiffLineClass.add:
      case _DiffLineClass.del:
      case _DiffLineClass.warn:
      case _DiffLineClass.ctx:
        return base;
    }
  }

  @override
  Widget build(BuildContext context) {
    final raw = stripAnsi(widget.code);
    final body = raw.length > _maxChars ? raw.substring(0, _maxChars) : raw;
    final truncated = body != raw;
    final allLines = body.split('\n');
    if (allLines.isNotEmpty && allLines.last.isEmpty) allLines.removeLast();
    final hidden = allLines.length - RichCodeBlockBuilder.previewLines;
    final lines = (_open || allLines.length <= RichCodeBlockBuilder.previewLines)
        ? allLines
        : allLines.take(RichCodeBlockBuilder.previewLines).toList();
    final diffLines = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in lines)
          Container(
            width: double.infinity,
            color: _rowColor(_diffLineClass(l)),
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: SelectableText(
              l.isEmpty ? ' ' : l,
              style: _lineStyle(_diffLineClass(l)),
            ),
          ),
        if (truncated)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '… (truncated)',
              style: TextStyle(
                fontSize: 12,
                color: widget.textColor.withValues(alpha: 0.55),
              ),
            ),
          ),
      ],
    );
    return _CodeChrome(
      code: widget.code,
      textColor: widget.textColor,
      language: 'diff',
      footer: hidden > 0
          ? Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _open = !_open),
                child: Text(
                  _open ? 'Show less' : 'Show more ($hidden lines)',
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.textColor.withValues(alpha: 0.75),
                  ),
                ),
              ),
            )
          : null,
      child: diffLines,
    );
  }
}

// ── Mermaid diagrams ────────────────────────────────────────────────────────
// ```mermaid blocks render to SVG in a hidden WebView (bundled
// mermaid.min.js, MIT — no network needed), then display in a fullscreen
// viewer with pinch-to-zoom via InteractiveViewer.

/// Placeholder card for a ```mermaid block; tap opens the fullscreen viewer.
class _MermaidBlock extends StatelessWidget {
  const _MermaidBlock({required this.source, required this.textColor});

  final String source;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withValues(alpha: 0.18)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showDialog(
          context: context,
          builder: (_) => _MermaidViewerDialog(source: source),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 18,
                color: textColor.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Diagram',
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              _CopyIconButton(text: source, color: textColor),
              const SizedBox(width: 4),
              Icon(
                Icons.fullscreen,
                size: 18,
                color: textColor.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fullscreen diagram viewer: pinch/pan to zoom, +/− buttons, copy source.
class _MermaidViewerDialog extends StatefulWidget {
  const _MermaidViewerDialog({required this.source});

  final String source;

  @override
  State<_MermaidViewerDialog> createState() => _MermaidViewerDialogState();
}

class _MermaidViewerDialogState extends State<_MermaidViewerDialog> {
  // Nullable: widget tests (and any device without a WebView platform)
  // can't create the controller. Degrades to the error view instead of
  // crashing — the diagram source stays visible and copyable.
  WebViewController? _controller;
  final TransformationController _zoom = TransformationController();
  String? _svg;
  String? _error;
  bool _loadingStarted = false;
  Timer? _timeout;

  static String? _mermaidJs;

  @override
  void initState() {
    super.initState();
    try {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..addJavaScriptChannel('Mermaid', onMessageReceived: _onMessage);
    } catch (_) {
      _error = 'Diagram rendering is unavailable on this device.';
    }
    _timeout = Timer(const Duration(seconds: 20), () {
      if (mounted && _svg == null && _error == null) {
        setState(() => _error = 'Renderer timed out.');
      }
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _zoom.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loadingStarted) {
      _loadingStarted = true;
      _render();
    }
  }

  void _onMessage(JavaScriptMessage message) {
    if (!mounted) return;
    final text = message.message;
    setState(() {
      if (text.startsWith('ERROR:')) {
        _error = text.substring('ERROR:'.length);
      } else {
        _svg = text;
      }
    });
  }

  Future<void> _render() async {
    final controller = _controller;
    if (controller == null) return; // _error already set in initState.
    final dark = Theme.of(context).brightness != Brightness.light;
    try {
      _mermaidJs ??= await rootBundle.loadString('assets/js/mermaid.min.js');
      await controller.loadHtmlString(
        _viewerHtml(_mermaidJs!, widget.source, dark: dark),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to start renderer: $e');
    }
  }

  /// HTML shell: bundled mermaid renders the diagram to SVG and posts it
  /// back over the `Mermaid` JS channel. `htmlLabels: false` keeps labels
  /// as SVG text elements so flutter_svg can draw them (no foreignObject).
  static String _viewerHtml(String mermaidJs, String source,
      {required bool dark}) {
    final srcJson = jsonEncode(source);
    return '''
<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
</head><body style="margin:0;background:transparent">
<script>$mermaidJs</script>
<script>
mermaid.initialize({
  startOnLoad: false,
  securityLevel: 'strict',
  theme: '${dark ? 'dark' : 'default'}',
  flowchart: { htmlLabels: false }
});
var src = $srcJson;
mermaid.render('mmd', src).then(function(r) {
  Mermaid.postMessage(r.svg);
}).catch(function(e) {
  Mermaid.postMessage('ERROR:' + (e && e.message ? e.message : e));
});
</script></body></html>''';
  }

  double get _scale => _zoom.value.getMaxScaleOnAxis();

  void _zoomBy(double factor) {
    final s = (_scale * factor).clamp(0.5, 6.0);
    setState(() {
      _zoom.value = Matrix4.identity()..scaleByDouble(s, s, 1.0, 1.0);
    });
  }

  Future<void> _copySource() async {
    await Clipboard.setData(ClipboardData(text: widget.source));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diagram source copied'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Diagram'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            if (_svg != null) ...[
              IconButton(
                icon: const Icon(Icons.remove),
                tooltip: 'Zoom out',
                onPressed: () => _zoomBy(1 / 1.35),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Zoom in',
                onPressed: () => _zoomBy(1.35),
              ),
              IconButton(
                icon: const Icon(Icons.fit_screen_outlined),
                tooltip: 'Fit',
                onPressed: () => setState(() {
                  _zoom.value = Matrix4.identity();
                }),
              ),
            ],
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: 'Copy source',
              onPressed: _copySource,
            ),
          ],
        ),
        body: _error != null
            ? _errorView(theme)
            : _svg != null
                ? Container(
                    color: theme.scaffoldBackgroundColor,
                    child: InteractiveViewer(
                      transformationController: _zoom,
                      minScale: 0.5,
                      maxScale: 6.0,
                      child: Center(
                        child: SvgPicture.string(
                          _svg!,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      // The WebView must be mounted for the render JS to run;
                      // it stays 1px until the SVG arrives.
                      SizedBox(
                        width: 1,
                        height: 1,
                        // Non-null here: a null controller sets _error,
                        // which takes the _errorView branch above.
                        child: WebViewWidget(controller: _controller!),
                      ),
                      const Center(child: CircularProgressIndicator()),
                    ],
                  ),
      ),
    );
  }

  Widget _errorView(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(Icons.broken_image_outlined,
            size: 40, color: theme.colorScheme.error),
        const SizedBox(height: 12),
        Text(
          'Couldn\u2019t render this diagram.',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          _error ?? '',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 12),
        const Text('Source:'),
        const SizedBox(height: 4),
        SelectableText(
          widget.source,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ],
    );
  }
}

// ── KaTeX math (flutter_math_fork) ──────────────────────────────────────────
// Inline `$...$` is parsed by a custom inline syntax (same delimiter rules
// as the reference: no space after the opener, no space/digit before/after
// the closer). Display `$$...$$` blocks are extracted in segmentMarkdown
// because flutter_markdown has no override point for custom block tags.

/// Inline math: `$...$` → `math_inline` element. Runs before the standard
/// inline syntaxes, so `$` inside code spans is never touched (the code
/// span is consumed first) and `\$` is still an escaped dollar.
class InlineMathSyntax extends md.InlineSyntax {
  InlineMathSyntax()
      : super(
          r'\$(?![\s$])([^$\n]*?[^\s$\\])\$(?![\d$])',
          startCharacter: 0x24, // $
        );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('math_inline', match.group(1)!));
    return true;
  }
}

/// Renders a `math_inline` element with flutter_math_fork. Falls back to
/// the raw TeX on parse errors.
class InlineMathBuilder extends MarkdownElementBuilder {
  InlineMathBuilder({required this.textColor});

  final Color textColor;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final tex = element.textContent;
    final style = (preferredStyle ?? const TextStyle()).copyWith(
      color: textColor,
    );
    return Math.tex(
      tex,
      mathStyle: MathStyle.text,
      textStyle: style,
      onErrorFallback: (_) => Text(
        '\$$tex\$',
        style: _monoStyle(textColor),
      ),
    );
  }
}

/// Centered display-math block.
class _MathBlock extends StatelessWidget {
  const _MathBlock({required this.tex, required this.textColor});

  final String tex;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Math.tex(
          tex,
          mathStyle: MathStyle.display,
          textStyle: TextStyle(color: textColor, fontSize: 16),
          onErrorFallback: (_) => SelectableText(
            tex,
            style: _monoStyle(textColor),
          ),
        ),
      ),
    );
  }
}

// ── Tappable task-list checkbox ─────────────────────────────────────────────

/// A `- [ ]` / `- [x]` checkbox that toggles its visual state locally on tap.
class TappableCheckbox extends StatefulWidget {
  const TappableCheckbox({super.key, required this.initial});

  final bool initial;

  @override
  State<TappableCheckbox> createState() => _TappableCheckboxState();
}

class _TappableCheckboxState extends State<TappableCheckbox> {
  late bool _on = widget.initial;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: () => setState(() => _on = !_on),
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: accent, width: 1.6),
          color: _on ? accent.withValues(alpha: 0.2) : Colors.transparent,
        ),
        child: _on
            ? Icon(Icons.check, size: 14, color: accent)
            : null,
      ),
    );
  }
}

// ── RichMarkdown: the bubble renderer ───────────────────────────────────────

/// Shared style/behavior config for one message bubble.
class _RichConfig {
  _RichConfig({
    required this.textColor,
    required this.mine,
    required this.onTapLink,
  });

  final Color textColor;
  final bool mine;
  final Future<void> Function(String? href) onTapLink;

  /// The exact stylesheet the bubble used before rich rendering.
  MarkdownStyleSheet styleSheet(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium?.copyWith(color: textColor);
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: base,
      h1: theme.textTheme.titleLarge?.copyWith(color: textColor),
      h2: theme.textTheme.titleMedium?.copyWith(color: textColor),
      h3: theme.textTheme.titleSmall?.copyWith(color: textColor),
      em: base?.copyWith(fontStyle: FontStyle.italic),
      strong: base?.copyWith(fontWeight: FontWeight.bold),
      listBullet: base,
      a: base?.copyWith(
        color: mine ? Colors.white : theme.colorScheme.primary,
        decoration: TextDecoration.underline,
      ),
      code: base?.copyWith(
        fontFamily: 'monospace',
        fontSize: 13,
        backgroundColor: textColor.withValues(alpha: 0.12),
      ),
    );
  }

  Map<String, MarkdownElementBuilder> builders() => {
        'pre': RichCodeBlockBuilder(textColor: textColor),
        'math_inline': InlineMathBuilder(textColor: textColor),
      };
}

/// Renders a list of [RichSegment]s with one shared config.
class _SegmentList extends StatelessWidget {
  const _SegmentList({required this.segments, required this.config});

  final List<RichSegment> segments;
  final _RichConfig config;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final s in segments) _build(context, s)],
    );
  }

  Widget _build(BuildContext context, RichSegment s) {
    return switch (s) {
      TextSegment(:final markdown) => MarkdownBody(
          data: markdown,
          selectable: true,
          styleSheet: config.styleSheet(context),
          builders: config.builders(),
          inlineSyntaxes: [InlineMathSyntax()],
          checkboxBuilder: (val) => TappableCheckbox(initial: val),
          onTapLink: (text, href, title) => config.onTapLink(href),
        ),
      TableSegment(
        :final headers,
        :final rows,
        :final aligns
      ) =>
        SortableTable(
          headers: headers,
          rows: rows,
          aligns: aligns,
          textColor: config.textColor,
        ),
      CalloutSegment(
        :final kind,
        :final title,
        :final body,
        :final foldable,
        :final open
      ) =>
        _CalloutCard(
          kind: kind,
          title: title,
          bodyMarkdown: body,
          foldable: foldable,
          initiallyOpen: open,
          config: config,
        ),
      MathBlockSegment(:final tex) => _MathBlock(
          tex: tex,
          textColor: config.textColor,
        ),
    };
  }
}

/// Drop-in replacement for the chat bubble's markdown renderer: plain
/// markdown renders exactly as before, plus sortable tables, collapsible
/// code blocks, tappable task lists, callouts, colored diffs, KaTeX math
/// and mermaid diagrams.
class RichMarkdown extends StatelessWidget {
  const RichMarkdown({
    super.key,
    required this.text,
    required this.color,
    required this.mine,
  });

  final String text;
  final Color color;
  final bool mine;

  Future<void> _openLink(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Link open is best-effort.
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _RichConfig(
      textColor: color,
      mine: mine,
      onTapLink: _openLink,
    );
    return _SegmentList(segments: segmentMarkdown(text), config: config);
  }
}
