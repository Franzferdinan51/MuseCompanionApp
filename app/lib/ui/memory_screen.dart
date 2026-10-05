// Concepts inspired by hermes-mobile-app's MemoryScreen
// (https://github.com/omarqaterge/hermes-mobile-app — MIT licensed,
// Copyright 2026 Omar Qaterge).
//
// Shows what the on-device agent remembers: every stored fact with its
// write history as old -> new diffs. Swipe a card to forget it; the
// trash action clears everything (with confirmation). Everything here
// lives only on this phone.

import 'package:flutter/material.dart';

import '../app/agent_memory.dart';
import 'muse_theme.dart';

/// Memory screen: the agent's long-term facts, each expandable to its
/// write history. Refreshes live when the agent writes while open.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  @override
  void initState() {
    super.initState();
    // Loads from disk; notifyListeners rebuilds the ListenableBuilder.
    AgentMemory.instance.init();
  }

  String _time(DateTime at) {
    final now = DateTime.now();
    final diff = now.difference(at);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${at.month}/${at.day}/${at.year}';
  }

  Future<void> _confirmClearAll() async {
    final memory = AgentMemory.instance;
    if (memory.recallAll().isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget everything?'),
        content: const Text(
          'This erases all facts the agent remembers. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget all'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await memory.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Memory cleared.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MusePage(
      appBar: AppBar(
        title: const Text('Agent memory'),
        actions: [
          IconButton(
            tooltip: 'Forget everything',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _confirmClearAll,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: AgentMemory.instance,
        builder: (context, _) {
          final entries = AgentMemory.instance.recallAll();
          if (entries.isEmpty) return _emptyState(theme);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  '${entries.length} ${entries.length == 1 ? 'fact' : 'facts'} '
                  'stored only on this phone. Nothing here is synced or '
                  'sent anywhere.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) =>
                      _entryCard(context, theme, entries[i]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Nothing remembered yet.\n\n'
          'Ask the local agent to remember facts about you '
          '(your name, preferences, routines) and they show up here. '
          'Everything is stored only on this phone.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  Widget _entryCard(BuildContext context, ThemeData theme, MemoryEntry entry) {
    return Dismissible(
      key: ValueKey('memory-${entry.key}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Forget "${entry.key}"?'),
          content: const Text(
            'The agent will no longer remember this. '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Forget'),
            ),
          ],
        ),
      ),
      onDismissed: (_) => AgentMemory.instance.forget(entry.key),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Icon(
          Icons.delete_outline,
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
      child: MuseBubble(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ExpansionTile(
          shape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: Text(
            entry.key,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: Text(
            'updated ${_time(entry.updatedAt)}'
            '${entry.source == 'agent' ? '' : ' · by you'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                entry.value,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (entry.history.isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Write history',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              for (final w in entry.history.reversed) _historyRow(theme, w),
            ],
          ],
        ),
      ),
    );
  }

  Widget _historyRow(ThemeData theme, MemoryWrite write) {
    final created = write.oldValue == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            created ? Icons.add_circle_outline : Icons.edit_outlined,
            size: 18,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_time(write.at)}'
                  '${write.source == 'agent' ? '' : ' · by you'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 2),
                if (!created)
                  Text(
                    'was: ${write.oldValue}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                Text(
                  created
                      ? 'added: ${write.newValue}'
                      : 'now: ${write.newValue}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: created
                        ? theme.colorScheme.outline
                        : theme.colorScheme.primary,
                    fontWeight: created ? null : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
