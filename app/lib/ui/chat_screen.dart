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
// Message screen: text, hold-to-talk, and a camera frame.
//
// Replies arrive on the chat subscription and show up as assistant
// bubbles. A voice note and a photo go out as chat attachments, the
// same shape the Muse gadget firmware uses.

import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:muse_companion/src/gadget/chat_events.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

import '../app/avatar_motion.dart';
import '../app/chat.dart';
import '../src/gadget/service.dart';
import 'scope.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<ConnectionState>? _connectionSub;
  ConnectionState _connection = ConnectionState.unpaired;
  bool _listening = false;
  bool _capturing = false;
  String? _captionBeforeListen;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _connectionSub?.cancel();
    final scope = AppScope.of(context);
    _connection = scope.service.connectionState;
    _connectionSub = scope.service.onStateChanged.listen((state) {
      if (mounted) setState(() => _connection = state);
    });
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _ready =>
      _connection == ConnectionState.connected &&
      AppScope.of(context).service.isRegistered;

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    await _post(text);
  }

  Future<void> _post(String text,
      [List<ChatAttachment> attachments = const []]) async {
    final scope = AppScope.of(context);
    _controller.clear();
    final shown = text.isEmpty
        ? (attachments.any((item) => item.mimeType.startsWith('audio/'))
            ? 'Voice note'
            : 'Photo')
        : text;
    final id = scope.chat.addSending(shown);
    _scrollToEnd();
    final result = await scope.service.sendChat(text, null, attachments);
    if (!mounted) return;
    if (result['ok'] == true) {
      scope.chat.markSent(id);
    } else {
      final error = result['error'];
      scope.chat.markFailed(
          id, error is String && error.isNotEmpty ? error : 'send failed');
    }
    _scrollToEnd();
  }

  Future<void> _startVoice() async {
    if (_listening || !_ready) return;
    final scope = AppScope.of(context);
    _captionBeforeListen = scope.presentation.statusText;
    scope.presentation.applyPose(AvatarPose.listening);
    scope.presentation.applyStatus('Listening…');
    setState(() => _listening = true);
    try {
      await scope.phone.startRecording();
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      setState(() => _listening = false);
      scope.presentation.applyPose(AvatarPose.idle);
      _restoreCaption();
      _showError(e.message);
    }
  }

  void _restoreCaption() {
    final previous = _captionBeforeListen;
    _captionBeforeListen = null;
    if (previous == null) return;
    AppScope.of(context).presentation.applyStatus(previous);
  }

  Future<void> _stopVoice() async {
    if (!_listening) return;
    setState(() => _listening = false);
    final scope = AppScope.of(context);
    scope.presentation.applyPose(AvatarPose.thinking);
    if (scope.presentation.statusText == 'Listening…') _restoreCaption();
    try {
      final wav = await scope.phone.stopRecording();
      final note = _controller.text.trim();
      await _post(note, [
        ChatAttachment(
          mimeType: 'audio/wav',
          filename: 'voice_note.wav',
          bytes: wav,
        ),
      ]);
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
      _showError(e.message);
    }
  }

  Future<void> _capture() async {
    if (_capturing || !_ready) return;
    setState(() => _capturing = true);
    final scope = AppScope.of(context);
    try {
      final jpeg = await scope.phone.captureJpeg();
      final note = _controller.text.trim();
      await _post(
        note.isEmpty ? 'What do you see?' : note,
        [
          ChatAttachment(
            mimeType: 'image/jpeg',
            filename: 'camera.jpg',
            bytes: jpeg,
          ),
        ],
      );
    } on PhoneActionException catch (e) {
      if (mounted) _showError(e.message);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToEnd() {
    // After the list rebuilds with the new row.
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final agent = scope.service.agentName;
    return Scaffold(
      appBar: AppBar(
        title: Text(agent == null ? 'Message Muse' : 'Message $agent'),
        backgroundColor: theme.colorScheme.surface,
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!_ready) _OfflineBanner(connection: _connection),
            if (_listening || scope.chat.activity.isNotEmpty)
              _ActivityBanner(
                text: _listening
                    ? 'Listening… release to send'
                    : scope.chat.activity,
              ),
            Expanded(
              child: StreamBuilder<void>(
                stream: scope.chat.stream,
                builder: (context, _) {
                  final messages = scope.chat.messages;
                  if (messages.isEmpty) {
                    return _EmptyHint(ready: _ready);
                  }
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (context, i) =>
                        _Bubble(message: messages[i]),
                  );
                },
              ),
            ),
            _Composer(
              controller: _controller,
              ready: _ready,
              listening: _listening,
              capturing: _capturing,
              connection: _connection,
              onSend: _send,
              onListenStart: _startVoice,
              onListenEnd: _stopVoice,
              onCapture: _capture,
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.connection});

  final ConnectionState connection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (connection) {
      ConnectionState.unpaired => 'Not paired — messages will fail until you pair.',
      ConnectionState.connecting => 'Connecting — messages send once registered.',
      ConnectionState.waiting => 'Link down — messages send when it reconnects.',
      ConnectionState.stopped => 'Stopped — messages cannot send.',
      ConnectionState.connected => 'Registering — one moment…',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.outline),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              ready
                  ? 'Say hello, hold the mic, or show the camera. Replies show up here.'
                  : 'Messages you send appear here with their delivery state.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time =
        '${message.sentAt.hour.toString().padLeft(2, '0')}:${message.sentAt.minute.toString().padLeft(2, '0')}';
    final mine = message.role == ChatRole.user;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: message.status == ChatStatus.failed
              ? theme.colorScheme.errorContainer
              : mine
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.text.isEmpty && message.streaming ? '…' : message.text,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.error.isNotEmpty
                      ? '${message.error} · $time'
                      : time,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline),
                ),
                const SizedBox(width: 4),
                _StatusIcon(status: message.status),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final ChatStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (status) {
      ChatStatus.sent => Icon(Icons.done_all,
          size: 14, color: theme.colorScheme.primary),
      ChatStatus.failed => Icon(Icons.error_outline,
          size: 14, color: theme.colorScheme.error),
      ChatStatus.sending => SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: theme.colorScheme.outline),
        ),
    };
  }
}

class _ActivityBanner extends StatelessWidget {
  const _ActivityBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.primaryContainer,
      child: Text(text, style: theme.textTheme.bodySmall),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.ready,
    required this.listening,
    required this.capturing,
    required this.connection,
    required this.onSend,
    required this.onListenStart,
    required this.onListenEnd,
    required this.onCapture,
  });

  final TextEditingController controller;
  final bool ready;
  final bool listening;
  final bool capturing;
  final ConnectionState connection;
  final Future<void> Function() onSend;
  final VoidCallback onListenStart;
  final VoidCallback onListenEnd;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = ready
        ? 'Message your Muse…'
        : switch (connection) {
            ConnectionState.unpaired => 'Pair first to message…',
            ConnectionState.connecting ||
            ConnectionState.waiting =>
              'Waiting for the link…',
            _ => 'Unavailable right now…',
          };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Show the camera',
            onPressed: ready && !capturing ? onCapture : null,
            icon: capturing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.photo_camera_outlined),
          ),
          Listener(
            onPointerDown: ready ? (_) => onListenStart() : null,
            onPointerUp: (_) => onListenEnd(),
            onPointerCancel: (_) => onListenEnd(),
            child: IconButton(
              tooltip: 'Hold to talk',
              onPressed: ready ? () {} : null,
              icon: Icon(
                listening ? Icons.mic : Icons.mic_none,
                color: listening ? theme.colorScheme.error : null,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: hint,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              tooltip: 'Send',
              icon: Icon(Icons.send,
                  color: theme.colorScheme.onPrimary),
              onPressed: onSend,
            ),
          ),
        ],
      ),
    );
  }
}
