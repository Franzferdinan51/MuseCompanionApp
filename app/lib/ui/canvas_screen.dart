// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Shared canvas UI: document list, viewer/editor, version history with
// diffs and restore.
//
// UX concepts ported from the MIT-licensed hermes-mobile-app Canvas
// component by omarqaterge:
// https://github.com/omarqaterge/hermes-mobile-app
// (web/src/components/Canvas.tsx)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:webview_flutter/webview_flutter.dart';

import '../app/canvas_store.dart';
import 'muse_theme.dart';

/// Human-friendly relative timestamp, shared by the list and history.
String _relativeTime(DateTime at) {
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${at.month}/${at.day}/${at.year}';
}

IconData _typeIcon(CanvasDocType type) => switch (type) {
  CanvasDocType.markdown => Icons.article_outlined,
  CanvasDocType.html => Icons.language_outlined,
  CanvasDocType.code => Icons.code_outlined,
  CanvasDocType.text => Icons.notes_outlined,
  CanvasDocType.svg => Icons.brush_outlined,
};

/// Document list: the canvas entry point.
class CanvasListScreen extends StatefulWidget {
  const CanvasListScreen({super.key});

  @override
  State<CanvasListScreen> createState() => _CanvasListScreenState();
}

class _CanvasListScreenState extends State<CanvasListScreen> {
  CanvasStore? _store;
  List<CanvasDocMeta> _docs = const [];
  StreamSubscription<CanvasChange>? _sub;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final store = await CanvasStore.instance();
    if (!mounted) return;
    setState(() {
      _store = store;
      _loading = false;
    });
    if (store != null) {
      await _reload();
      _sub = store.changes.listen((_) {
        if (mounted) _reload();
      });
    }
  }

  Future<void> _reload() async {
    final store = _store;
    if (store == null) return;
    final docs = await store.list();
    if (mounted) setState(() => _docs = docs);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _createDialog() async {
    final store = _store;
    if (store == null) return;
    final titleController = TextEditingController();
    var type = CanvasDocType.markdown;
    final result = await showDialog<({String title, CanvasDocType type})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('New document'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Title',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<CanvasDocType>(
                initialValue: type,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final t in CanvasDocType.values)
                    DropdownMenuItem(value: t, child: Text(t.name)),
                ],
                onChanged: (t) {
                  if (t != null) setDialogState(() => type = t);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop((
                title: titleController.text.trim(),
                type: type,
              )),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    titleController.dispose();
    if (result == null || !mounted) return;
    try {
      final doc = await store.create(
        title: result.title.isEmpty ? 'Untitled' : result.title,
        type: result.type,
        by: 'user',
        note: 'created in app',
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CanvasScreen(docId: doc.id)),
      );
    } on CanvasStoreException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _rename(CanvasDocMeta meta) async {
    final store = _store;
    if (store == null) return;
    final controller = TextEditingController(text: meta.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename document'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty || !mounted) return;
    try {
      await store.rename(meta.id, title);
    } on CanvasStoreException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _delete(CanvasDocMeta meta) async {
    final store = _store;
    if (store == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text(
          '"${meta.title}" and its ${meta.rev} version(s) will be removed '
          'from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) await store.delete(meta.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MusePage(
      appBar: AppBar(title: const Text('Canvas')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _store == null
          ? const Center(child: Text('Canvas storage is unavailable.'))
          : _docs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.edit_note_outlined,
                      size: 64,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No documents yet.\nAsk Juno to draft one, or create one yourself.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _createDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('New document'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _docs.length,
                itemBuilder: (context, i) {
                  final meta = _docs[i];
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        _typeIcon(meta.type),
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(
                        meta.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${meta.type.name} · rev ${meta.rev} · '
                        '${_relativeTime(meta.updated)}',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'rename') _rename(meta);
                          if (value == 'delete') _delete(meta);
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'rename',
                            child: Text('Rename'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                        ],
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CanvasScreen(docId: meta.id),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// Viewer/editor for one document: renders by type, edits with version
/// history, diffs, and restore.
class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.docId});

  final String docId;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  CanvasStore? _store;
  CanvasDoc? _doc;
  StreamSubscription<CanvasChange>? _sub;
  bool _editing = false;
  bool _saving = false;
  late final TextEditingController _editor;

  @override
  void initState() {
    super.initState();
    _editor = TextEditingController();
    _init();
  }

  Future<void> _init() async {
    final store = await CanvasStore.instance();
    if (!mounted) return;
    setState(() => _store = store);
    if (store == null) return;
    await _reload();
    _sub = store.changes.listen((change) {
      // Another writer (e.g. the agent) touched our document: refresh,
      // but never clobber in-progress edits.
      if (change.docId == widget.docId && !_editing && mounted) _reload();
    });
  }

  Future<void> _reload() async {
    final store = _store;
    if (store == null) return;
    try {
      final doc = await store.read(widget.docId);
      if (!mounted) return;
      setState(() => _doc = doc);
    } on CanvasStoreException {
      if (mounted) setState(() => _doc = null);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _editor.dispose();
    super.dispose();
  }

  void _startEditing() {
    final doc = _doc;
    if (doc == null) return;
    _editor.text = doc.content;
    setState(() => _editing = true);
  }

  Future<void> _save() async {
    final store = _store;
    final doc = _doc;
    if (store == null || doc == null || _saving) return;
    setState(() => _saving = true);
    try {
      final updated = await store.update(
        doc.id,
        content: _editor.text,
        by: 'user',
        note: 'edited in app',
      );
      if (!mounted) return;
      setState(() {
        _doc = updated;
        _editing = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved as revision ${updated.rev}')),
      );
    } on CanvasStoreException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleNetwork() async {
    final store = _store;
    final doc = _doc;
    if (store == null || doc == null) return;
    final next = !doc.networkAllowed;
    if (next) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow network access?'),
          content: const Text(
            'This HTML document will be able to load remote scripts, '
            'images, fonts and other resources. Only enable this for '
            'documents you trust.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }
    final updated = await store.setNetworkAllowed(doc.id, next);
    if (mounted) setState(() => _doc = updated);
  }

  void _showHistory() {
    final doc = _doc;
    if (doc == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scroll) => _HistorySheet(
          doc: doc,
          scrollController: scroll,
          onOpenVersion: (rev) {
            Navigator.of(context).pop();
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    _VersionScreen(docId: widget.docId, rev: rev),
              ),
            );
          },
        ),
      ),
    ).then((_) {
      // The agent may have restored while we were browsing history.
      if (mounted && !_editing) _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return MusePage(
      appBar: AppBar(
        title: Text(doc?.title ?? 'Canvas'),
        actions: [
          if (doc != null && !_editing) ...[
            if (doc.type == CanvasDocType.html ||
                doc.type == CanvasDocType.svg)
              IconButton(
                tooltip: doc.networkAllowed
                    ? 'Network access on (tap to block)'
                    : 'Offline (tap to allow network)',
                icon: Icon(
                  doc.networkAllowed
                      ? Icons.wifi
                      : Icons.wifi_off_outlined,
                ),
                onPressed: _toggleNetwork,
              ),
            IconButton(
              tooltip: 'Version history',
              icon: const Icon(Icons.history),
              onPressed: _showHistory,
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _startEditing,
            ),
          ],
          if (_editing)
            IconButton(
              tooltip: 'Save',
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              onPressed: _save,
            ),
        ],
      ),
      body: _store == null
          ? const Center(child: CircularProgressIndicator())
          : doc == null
          ? const Center(
              child: Text('This document no longer exists.'),
            )
          : _editing
          ? Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _editor,
                expands: true,
                maxLines: null,
                style: TextStyle(
                  fontFamily: doc.type == CanvasDocType.code
                      ? 'monospace'
                      : null,
                  fontSize: 14,
                  height: 1.4,
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            )
          : _DocView(doc: doc),
    );
  }
}

/// Renders a document by type.
class _DocView extends StatelessWidget {
  const _DocView({required this.doc});

  final CanvasDoc doc;

  @override
  Widget build(BuildContext context) {
    switch (doc.type) {
      case CanvasDocType.markdown:
        return _MarkdownView(content: doc.content);
      case CanvasDocType.html:
        return _HtmlView(
          html: doc.content,
          networkAllowed: doc.networkAllowed,
        );
      case CanvasDocType.svg:
        // SVG renders inside the same offline sandbox as HTML.
        return _HtmlView(
          html: _svgPage(doc.content),
          networkAllowed: doc.networkAllowed,
        );
      case CanvasDocType.code:
        return _CodeView(content: doc.content, lang: doc.lang);
      case CanvasDocType.text:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            doc.content,
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
        );
    }
  }
}

String _svgPage(String svg) =>
    '<!DOCTYPE html><html><head>'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '</head><body style="margin:0;display:flex;align-items:center;'
    'justify-content:center;min-height:100vh">'
    '<div style="width:100%;max-width:100%">$svg</div>'
    '</body></html>';

/// Markdown rendering, same package and code-block treatment as the chat
/// bubbles.
class _MarkdownView extends StatelessWidget {
  const _MarkdownView({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final sheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: base?.copyWith(height: 1.5),
      code: base?.copyWith(
        fontFamily: 'monospace',
        fontSize: 13,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
    );
    return Markdown(
      data: content,
      selectable: true,
      styleSheet: sheet,
      padding: const EdgeInsets.all(16),
      builders: {'pre': _CanvasCodeBlockBuilder()},
    );
  }
}

class _CanvasCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () => Clipboard.setData(ClipboardData(text: code)),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.copy_outlined, size: 16),
              ),
            ),
          ),
          SelectableText(
            code,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Code view: monospace with a copy button.
class _CodeView extends StatelessWidget {
  const _CodeView({required this.content, required this.lang});

  final String content;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (lang.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    lang,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: content));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              content,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Sandboxed HTML view.
///
/// Security model (documented for review):
/// - JavaScript is ENABLED: agent-built pages are often interactive
///   (charts, toggles), and JS in a page cannot reach the app or the
///   file system from here.
/// - EVERY navigation is blocked via [NavigationDelegate]
///   ([NavigationDecision.prevent]): link taps, redirects, form posts
///   and top-level URL changes all stay inside the rendered page. The
///   WebView can never be steered to an attacker URL by tapping.
/// - OFFLINE BY DEFAULT: when [networkAllowed] is false, a strict
///   Content-Security-Policy meta tag is injected
///   (`default-src 'none'`, inline scripts/styles only, `img-src data:`,
///   `connect-src 'none'`), so remote scripts, fonts, images, `fetch()`
///   calls and websockets are refused by the engine. `data:` URIs still
///   work, so self-contained pages render fully.
/// - Opt-in per document: the user can flip [networkAllowed] on from the
///   overflow control; the choice is stored on the document and the
///   navigation block stays in force regardless.
/// - The HTML string is rendered with `loadHtmlString` (no base URL), so
///   relative URLs resolve to nothing.
class _HtmlView extends StatefulWidget {
  const _HtmlView({required this.html, required this.networkAllowed});

  final String html;
  final bool networkAllowed;

  @override
  State<_HtmlView> createState() => _HtmlViewState();
}

class _HtmlViewState extends State<_HtmlView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (_) => NavigationDecision.prevent,
        ),
      )
      ..loadHtmlString(_sandboxed(widget.html, widget.networkAllowed));
  }

  @override
  void didUpdateWidget(covariant _HtmlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.networkAllowed != widget.networkAllowed) {
      _controller.loadHtmlString(
        _sandboxed(widget.html, widget.networkAllowed),
      );
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}

/// Inject the offline CSP unless the user allowed network for this doc.
String _sandboxed(String html, bool networkAllowed) {
  if (networkAllowed) return html;
  const csp =
      '<meta http-equiv="Content-Security-Policy" '
      'content="default-src \'none\'; script-src \'unsafe-inline\'; '
      'style-src \'unsafe-inline\'; img-src data:; font-src data:; '
      'media-src data:; connect-src \'none\'">';
  final head = RegExp(r'<head[^>]*>', caseSensitive: false);
  if (head.hasMatch(html)) {
    return html.replaceFirstMapped(head, (m) => '${m.group(0)}$csp');
  }
  return csp + html;
}

/// Version history bottom sheet, newest first.
class _HistorySheet extends StatelessWidget {
  const _HistorySheet({
    required this.doc,
    required this.scrollController,
    required this.onOpenVersion,
  });

  final CanvasDoc doc;
  final ScrollController scrollController;
  final void Function(int rev) onOpenVersion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final versions = doc.versions.reversed.toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.outline.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            'Version history',
            style: theme.textTheme.titleMedium,
          ),
          Text(
            '${doc.versions.length} version(s) · current is rev ${doc.rev}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: versions.length,
              itemBuilder: (context, i) {
                final v = versions[i];
                final isCurrent = v.rev == doc.rev;
                return ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    child: Text(
                      '${v.rev}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isCurrent
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  title: Text(
                    v.note.isEmpty ? 'Revision ${v.rev}' : v.note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${_relativeTime(v.at)} · by ${v.by.isEmpty ? 'unknown' : v.by}'
                    '${isCurrent ? ' · current' : ''}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => onOpenVersion(v.rev),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One historical revision: line diff against the current content plus
/// a "Restore this version" button.
class _VersionScreen extends StatefulWidget {
  const _VersionScreen({required this.docId, required this.rev});

  final String docId;
  final int rev;

  @override
  State<_VersionScreen> createState() => _VersionScreenState();
}

class _VersionScreenState extends State<_VersionScreen> {
  CanvasDoc? _doc;
  CanvasVersion? _version;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await CanvasStore.instance();
    if (store == null || !mounted) return;
    try {
      final doc = await store.read(widget.docId);
      final version = doc.versions
          .where((v) => v.rev == widget.rev)
          .firstOrNull;
      if (mounted) {
        setState(() {
          _doc = doc;
          _version = version;
        });
      }
    } on CanvasStoreException {
      if (mounted) setState(() => _doc = null);
    }
  }

  Future<void> _restore() async {
    final store = await CanvasStore.instance();
    if (store == null || _restoring) return;
    setState(() => _restoring = true);
    try {
      final doc = await store.restore(widget.docId, widget.rev, by: 'user');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restored revision ${widget.rev} as revision ${doc.rev}',
          ),
        ),
      );
      Navigator.of(context).pop();
    } on CanvasStoreException catch (e) {
      if (!mounted) return;
      setState(() => _restoring = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    final version = _version;
    final isCurrent = doc != null && doc.rev == widget.rev;
    return MusePage(
      appBar: AppBar(title: Text('Revision ${widget.rev}')),
      body: doc == null
          ? const Center(child: CircularProgressIndicator())
          : version == null
          ? const Center(child: Text('This revision is no longer kept.'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_relativeTime(version.at)} · by '
                          '${version.by.isEmpty ? 'unknown' : version.by}'
                          '${version.note.isNotEmpty ? '\n${version.note}' : ''}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (!isCurrent)
                        FilledButton.icon(
                          onPressed: _restore,
                          icon: _restoring
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.restore, size: 18),
                          label: const Text('Restore this version'),
                        )
                      else
                        const Chip(label: Text('Current')),
                    ],
                  ),
                ),
                const Divider(height: 8),
                Expanded(
                  child: _DiffView(
                    oldText: version.content,
                    newText: doc.content,
                  ),
                ),
              ],
            ),
    );
  }
}

enum _DiffOp { same, added, removed }

class _DiffLine {
  const _DiffLine(this.op, this.text);

  final _DiffOp op;
  final String text;
}

/// Simple line diff (LCS-based). For very large inputs the quadratic
/// table gets too big, so beyond ~500x500 lines it falls back to a
/// coarse prefix/suffix diff rather than stalling the UI.
List<_DiffLine> _lineDiff(String oldText, String newText) {
  final a = oldText.split('\n');
  final b = newText.split('\n');
  if (a.length * b.length > 250000) return _coarseDiff(a, b);
  final n = a.length;
  final m = b.length;
  final lens = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lens[i][j] = a[i] == b[j]
          ? lens[i + 1][j + 1] + 1
          : (lens[i + 1][j] >= lens[i][j + 1]
                ? lens[i + 1][j]
                : lens[i][j + 1]);
    }
  }
  final out = <_DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(_DiffLine(_DiffOp.same, a[i]));
      i++;
      j++;
    } else if (lens[i + 1][j] >= lens[i][j + 1]) {
      out.add(_DiffLine(_DiffOp.removed, a[i]));
      i++;
    } else {
      out.add(_DiffLine(_DiffOp.added, b[j]));
      j++;
    }
  }
  while (i < n) {
    out.add(_DiffLine(_DiffOp.removed, a[i]));
    i++;
  }
  while (j < m) {
    out.add(_DiffLine(_DiffOp.added, b[j]));
    j++;
  }
  return out;
}

List<_DiffLine> _coarseDiff(List<String> a, List<String> b) {
  var prefix = 0;
  while (prefix < a.length &&
      prefix < b.length &&
      a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  return [
    for (var i = 0; i < prefix; i++) _DiffLine(_DiffOp.same, a[i]),
    for (var i = prefix; i < a.length - suffix; i++)
      _DiffLine(_DiffOp.removed, a[i]),
    for (var i = prefix; i < b.length - suffix; i++)
      _DiffLine(_DiffOp.added, b[i]),
    for (var i = a.length - suffix; i < a.length; i++)
      _DiffLine(_DiffOp.same, a[i]),
  ];
}

/// Renders a line diff: added lines green, removed lines red.
class _DiffView extends StatelessWidget {
  const _DiffView({required this.oldText, required this.newText});

  final String oldText;
  final String newText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = _lineDiff(oldText, newText);
    if (lines.length == 1 && lines.single.op == _DiffOp.same) {
      return const Center(child: Text('Identical to the current version.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final line = lines[i];
        final (bg, fg, marker) = switch (line.op) {
          _DiffOp.added => (
            Colors.green.withValues(alpha: 0.15),
            Colors.green.shade300,
            '+',
          ),
          _DiffOp.removed => (
            Colors.red.withValues(alpha: 0.15),
            Colors.red.shade300,
            '-',
          ),
          _DiffOp.same => (
            Colors.transparent,
            theme.colorScheme.outline,
            ' ',
          ),
        };
        return Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: SelectableText.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$marker ',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: fg,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextSpan(
                  text: line.text.isEmpty ? ' ' : line.text,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.35,
                    color: line.op == _DiffOp.same
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.75)
                        : fg,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
