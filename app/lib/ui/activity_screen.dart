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
// Activity tab: chronological log of chat sends, gadget invokes, voice
// notes, and photos. Useful when debugging link/invoke problems.

import 'package:flutter/material.dart';

import '../app/activity_log.dart';
import 'muse_theme.dart';

/// Activity log screen: newest-first event list with kind icons and
/// success/failure coloring.
class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key, this.onMenu});

  /// Opens the navigation drawer; null hides the menu button.
  final VoidCallback? onMenu;

  IconData _icon(ActivityKind kind) {
    return switch (kind) {
      ActivityKind.chat => Icons.chat_bubble_outline,
      ActivityKind.invoke => Icons.bolt_outlined,
      ActivityKind.voice => Icons.mic_none_outlined,
      ActivityKind.photo => Icons.photo_camera_outlined,
      ActivityKind.system => Icons.info_outline,
    };
  }

  String _label(ActivityKind kind) {
    return switch (kind) {
      ActivityKind.chat => 'Chat',
      ActivityKind.invoke => 'Invoke',
      ActivityKind.voice => 'Voice',
      ActivityKind.photo => 'Photo',
      ActivityKind.system => 'System',
    };
  }

  String _time(DateTime at) {
    final now = DateTime.now();
    final diff = now.difference(at);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${at.month}/${at.day} '
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MusePage(
      appBar: AppBar(
        leading: onMenu == null
            ? null
            : IconButton(
                tooltip: 'Menu',
                icon: const Icon(Icons.menu),
                onPressed: onMenu,
              ),
        title: const Text('Activity'),
        actions: [
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => ActivityLog.instance.clear(),
          ),
        ],
      ),
      body: StreamBuilder<void>(
        stream: ActivityLog.instance.stream,
        builder: (context, _) {
          final entries = ActivityLog.instance.entries;
          if (entries.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No activity yet.\nSend a message or run a command and it shows up here.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final entry = entries[i];
              return MuseBubble(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _icon(entry.kind),
                      size: 20,
                      color: entry.ok
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                _label(entry.kind),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _time(entry.at),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                              if (!entry.ok) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.error_outline,
                                  size: 14,
                                  color: theme.colorScheme.error,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            entry.summary,
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (entry.detail.isNotEmpty)
                            Text(
                              entry.detail,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
