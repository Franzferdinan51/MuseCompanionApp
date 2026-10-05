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
// Media tab: gallery of captured photos and voice notes from the chat
// history, with playback and resend-to-chat.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../app/chat.dart';
import '../src/gadget/chat_events.dart';
import 'muse_theme.dart';
import 'scope.dart';

/// Media gallery: photos as a thumbnail grid, voice notes as a playable
/// list. Both come from the in-memory chat history.
class MediaScreen extends StatelessWidget {
  const MediaScreen({super.key, this.onMenu});

  /// Opens the navigation drawer; null hides the menu button.
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
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
        title: const Text('Media'),
      ),
      body: StreamBuilder<void>(
        stream: scope.chat.stream,
        builder: (context, _) {
          final messages = scope.chat.messages;
          final photos = messages.where((m) => m.hasImage).toList();
          final notes = messages.where((m) => m.hasAudio).toList();
          if (photos.isEmpty && notes.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No photos or voice notes yet.\nUse the camera and mic buttons in chat.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              if (photos.isNotEmpty) ...[
                _SectionTitle(title: 'Photos (${photos.length})'),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                  itemCount: photos.length,
                  itemBuilder: (context, i) =>
                      _PhotoTile(message: photos[i]),
                ),
                const SizedBox(height: 16),
              ],
              if (notes.isNotEmpty) ...[
                _SectionTitle(title: 'Voice notes (${notes.length})'),
                const SizedBox(height: 8),
                ...notes.map((m) => _VoiceTile(message: m)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final bytes = message.attachmentBytes!;
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: InteractiveViewer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.send_outlined),
                label: const Text('Resend to chat'),
                onPressed: () {
                  Navigator.of(context).pop();
                  _resend(context);
                },
              ),
            ],
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (context, _, _) =>
              const Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }

  Future<void> _resend(BuildContext context) async {
    final scope = AppScope.of(context);
    final id = scope.chat.addSending(
      'Photo',
      attachmentBytes: message.attachmentBytes,
      attachmentMime: message.attachmentMime,
      attachmentName: message.attachmentName,
    );
    final result = await scope.service.sendChat('Photo', null, [
      ChatAttachment(
        mimeType: message.attachmentMime ?? 'image/jpeg',
        filename: message.attachmentName ?? 'photo.jpg',
        bytes: message.attachmentBytes!,
      ),
    ]);
    if (!context.mounted) return;
    if (result['ok'] == true) {
      scope.chat.markSent(id);
    } else {
      final error = result['error'];
      scope.chat.markFailed(
        id,
        error is String && error.isNotEmpty ? error : 'send failed',
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Photo resent to chat')),
    );
  }
}

class _VoiceTile extends StatefulWidget {
  const _VoiceTile({required this.message});

  final ChatMessage message;

  @override
  State<_VoiceTile> createState() => _VoiceTileState();
}

class _VoiceTileState extends State<_VoiceTile> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _playing = state == PlayerState.playing);
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = widget.message.sentAt;
    final time =
        '${at.month}/${at.day} ${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MuseBubble(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: Icon(
                _playing ? Icons.pause_circle : Icons.play_circle,
              ),
              iconSize: 32,
              color: theme.colorScheme.primary,
              onPressed: () async {
                try {
                  if (_playing) {
                    await _player.pause();
                  } else {
                    await _player.play(
                      BytesSource(widget.message.attachmentBytes!),
                    );
                  }
                } catch (_) {}
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Voice note', style: theme.textTheme.bodyMedium),
                  Text(
                    time,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Note: ChatAttachment comes from src/gadget/chat_events.dart.
