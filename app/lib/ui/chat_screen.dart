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
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'package:muse_companion/src/gadget/chat_events.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

import '../app/avatar_motion.dart';
import '../app/activity_log.dart';
import '../app/chat.dart';
import '../app/chat_store.dart';
import '../app/lmstudio_client.dart';
import '../src/gadget/service.dart';
import 'muse_theme.dart';
import 'scope.dart';
import 'slash_autocomplete.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<ConnectionState>? _connectionSub;
  StreamSubscription<void>? _chatSub;
  ConnectionState _connection = ConnectionState.unpaired;
  bool _listening = false;
  bool _capturing = false;
  String? _captionBeforeListen;
  ChatStore? _store;
  bool _storeArmed = false;
  Timer? _saveTimer;
  bool _searching = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  /// Current slash-command query, or null when the autocomplete popup is
  /// hidden. Driven by the composer controller listener.
  String? _slashQuery;

  /// Pin/archive flags for this conversation, restored from ChatStore.
  bool _pinned = false;
  bool _archived = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onComposerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _connectionSub?.cancel();
    final scope = AppScope.of(context);
    _armStore(scope);
    _connection = scope.service.connectionState;
    _connectionSub = scope.service.onStateChanged.listen((state) {
      if (mounted) setState(() => _connection = state);
    });
  }

  /// One-time: restore persisted history, then debounce-save on changes.
  void _armStore(AppScope scope) {
    if (_storeArmed) return;
    _storeArmed = true;
    final store = ChatStore(scope.chat);
    _store = store;
    store.restore().then((_) {
      if (mounted) _scrollToEnd();
    });
    store.restoreMeta().then((_) {
      if (mounted) {
        setState(() {
          _pinned = store.meta.pinned;
          _archived = store.meta.archived;
        });
      }
    });
    _chatSub = scope.chat.stream.listen((_) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(seconds: 2), () => store.save());
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _store?.save();
    _chatSub?.cancel();
    _connectionSub?.cancel();
    _controller.dispose();
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _ready =>
      _connection == ConnectionState.connected &&
      AppScope.of(context).service.isRegistered;

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (text.startsWith('/')) {
      await _handleSlash(text);
      return;
    }
    await _post(text);
  }

  /// Power-user shortcuts (see [kSlashCommands] for the full list).
  /// Unknown slashes fall through as normal messages.
  Future<void> _handleSlash(String text) async {
    final parts = text.substring(1).split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();
    final arg = parts.length > 1 ? parts.sublist(1).join(' ').trim() : '';
    switch (cmd) {
      case 'photo':
        _controller.clear();
        await _capture();
      case 'voice':
        _controller.clear();
        _showError('Hold the mic button to record a voice note.');
      case 'local':
        if (arg.isEmpty) {
          _showError('Usage: /local <what should the local model do>');
        } else {
          _controller.clear();
          await _askLocalAiWith(arg);
        }
      case 'speak':
        _controller.clear();
        final reply = AppScope.of(context).chat.lastReply;
        if (reply != null && reply.trim().isNotEmpty) {
          await _speakMessage(reply);
        } else {
          _showError('Nothing to speak yet.');
        }
      default:
        await _post(text);
    }
  }

  /// Composer listener: show the slash-command popup while a leading
  /// `/` token is being typed; hide it otherwise (backspaced past `/`,
  /// command finished, text sent/cleared).
  void _onComposerChanged() {
    final query = slashCommandQuery(
      _controller.text,
      _controller.selection.baseOffset,
    );
    if (query != _slashQuery) setState(() => _slashQuery = query);
  }

  /// Insert a picked slash command, leaving a trailing space so arguments
  /// can follow (e.g. `/local ...`). The listener then hides the popup.
  void _insertSlashCommand(SlashCommand command) {
    _controller.text = '${command.trigger} ';
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  /// Clear-history with a confirm step. Clears memory and disk.
  Future<void> _clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat history?'),
        content: const Text(
          'This deletes the conversation from this device. '
          'It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      AppScope.of(context).chat.clearAll();
      await _store?.clear();
      ActivityLog.instance.add(ActivityKind.chat, 'Chat history cleared');
    }
  }

  /// Pin/unpin this conversation. Persisted via ChatStore.
  Future<void> _togglePin() async {
    final next = !_pinned;
    setState(() => _pinned = next);
    await _store?.setPinned(next);
  }

  /// Archive/unarchive this conversation. Archived chats hide their
  /// messages behind [_ArchivedPlaceholder] until unarchived.
  Future<void> _toggleArchive() async {
    final next = !_archived;
    setState(() => _archived = next);
    await _store?.setArchived(next);
  }

  /// Run the composer's text (or a prompted instruction) through the local
  /// AI model via LM Studio. The model can use phone tools to act.
  Future<void> _askLocalAi() => _askLocalAiWith('');

  /// Same as [_askLocalAi] but with a pre-supplied instruction (slash cmd).
  Future<void> _askLocalAiWith(String preset) async {
    final scope = AppScope.of(context);
    final settings = scope.presentation.settings;
    if (!settings.lmStudioEnabled) {
      _showError('Local AI is disabled. Turn it on in Settings.');
      return;
    }
    var instruction = preset.trim().isNotEmpty
        ? preset.trim()
        : _controller.text.trim();
    if (instruction.isEmpty) {
      instruction = await _promptInstruction() ?? '';
      if (instruction.trim().isEmpty) return;
      instruction = instruction.trim();
    }
    _controller.clear();
    final id = scope.chat.addSending('Local AI: $instruction');
    _scrollToEnd();
    scope.presentation.applyStatus('Asking local AI...');
    final service = LocalAiService(
      baseUrl: settings.lmStudioUrl,
      model: settings.lmStudioAgentModel,
      phone: scope.phone,
      usbStorageEnabled: settings.usbStorageEnabled,
      usbSerialEnabled: settings.usbSerialEnabled,
      cameraFacing: settings.cameraFacing,
      systemOneEnabled: settings.systemOneEnabled,
      systemOneUrl: settings.systemOneUrl,
      speakAllowed: settings.speakReplies,
    );
    final result = await service.runTask(instruction);
    if (!mounted) return;
    scope.chat.markSent(id);
    scope.presentation.applyStatus('');
    if (result.ok) {
      final answer = result.text.isEmpty
          ? '(local AI finished with no text)'
          : result.text;
      scope.chat.addLocalAssistant(answer);
    } else {
      scope.chat.addLocalAssistant('Local AI error: ${result.error}');
    }
    _scrollToEnd();
  }

  /// Prompt for a task instruction when the composer is empty.
  Future<String?> _promptInstruction() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ask local AI'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(
            hintText: 'What should the local model do?',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Ask'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  static String _short(String text) {
    final t = text.trim();
    return t.length > 60 ? '${t.substring(0, 60)}...' : t;
  }

  Future<void> _post(
    String text, [
    List<ChatAttachment> attachments = const [],
  ]) async {
    final scope = AppScope.of(context);
    _controller.clear();
    final shown = text.isEmpty
        ? (attachments.any((item) => item.mimeType.startsWith('audio/'))
              ? 'Voice note'
              : 'Photo')
        : text;
    final first = attachments.isNotEmpty ? attachments.first : null;
    final id = scope.chat.addSending(
      shown,
      attachmentBytes: first?.bytes,
      attachmentMime: first?.mimeType,
      attachmentName: first?.filename,
    );
    _scrollToEnd();
    final result = await scope.service.sendChat(text, null, attachments);
    if (!mounted) return;
    final isVoice = attachments.any((a) => a.mimeType.startsWith('audio/'));
    final isPhoto = attachments.any((a) => a.mimeType.startsWith('image/'));
    final kind = isVoice
        ? ActivityKind.voice
        : isPhoto
        ? ActivityKind.photo
        : ActivityKind.chat;
    if (result['ok'] == true) {
      scope.chat.markSent(id);
      ActivityLog.instance.add(
        kind,
        isVoice
            ? 'Voice note sent'
            : isPhoto
            ? 'Photo sent'
            : 'Message sent: ${_short(text)}',
      );
    } else {
      final error = result['error'];
      final msg = error is String && error.isNotEmpty ? error : 'send failed';
      scope.chat.markFailed(id, msg);
      ActivityLog.instance.add(
        kind,
        isVoice
            ? 'Voice note failed'
            : isPhoto
            ? 'Photo failed'
            : 'Message failed: ${_short(text)}',
        detail: msg,
        ok: false,
      );
    }
    _scrollToEnd();
  }

  /// Tap-to-retry on a failed bubble: re-sends the original text and
  /// attachment through the normal send path.
  Future<void> _retryMessage(int id) async {
    final scope = AppScope.of(context);
    final message = scope.chat.find(id);
    if (message == null || message.status != ChatStatus.failed) return;
    scope.chat.markRetrying(id);
    final attachments = <ChatAttachment>[];
    if (message.attachmentBytes != null) {
      attachments.add(
        ChatAttachment(
          mimeType: message.attachmentMime ?? 'application/octet-stream',
          filename: message.attachmentName ?? 'attachment',
          bytes: message.attachmentBytes!,
        ),
      );
    }
    final result = await scope.service.sendChat(
      message.text,
      null,
      attachments,
    );
    if (!mounted) return;
    if (result['ok'] == true) {
      scope.chat.markSent(id);
    } else {
      final error = result['error'];
      scope.chat.markFailed(
        id,
        error is String && error.isNotEmpty ? error : 'send failed',
      );
    }
    _scrollToEnd();
  }

  /// Long-press delete with a confirm step.
  Future<void> _deleteMessage(int id) async {
    final scope = AppScope.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('This removes the message from this device.'),
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
    if (confirm == true && mounted) {
      scope.chat.deleteMessage(id);
    }
  }

  Future<void> _speakMessage(String text) async {
    final scope = AppScope.of(context);
    try {
      await scope.phone.speak(text);
    } on PhoneActionException catch (e) {
      if (mounted) _showError(e.message);
    }
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
      final message = note.isEmpty ? '\u{1F3A4} Voice note' : note;
      await _post(message, [
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
      final jpeg = await scope.phone.captureJpeg(
        facing: scope.presentation.settings.cameraFacing,
      );
      final note = _controller.text.trim();
      await _post(note.isEmpty ? 'What do you see?' : note, [
        ChatAttachment(
          mimeType: 'image/jpeg',
          filename: 'camera.jpg',
          bytes: jpeg,
        ),
      ]);
    } on PhoneActionException catch (e) {
      if (mounted) _showError(e.message);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  /// Flatten messages into divider + bubble widgets.
  List<Widget> _buildListItems(List<ChatMessage> messages) {
    final items = <Widget>[];
    DateTime? lastDay;
    for (final message in messages) {
      final day = DateTime(
        message.sentAt.year,
        message.sentAt.month,
        message.sentAt.day,
      );
      if (lastDay == null || day != lastDay) {
        items.add(_DayDivider(date: day));
        lastDay = day;
      }
      items.add(
        _Bubble(
          message: message,
          onRetry: () => _retryMessage(message.id),
          onDelete: () => _deleteMessage(message.id),
          onSpeak: () => _speakMessage(message.text),
        ),
      );
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final agent = scope.service.agentName;
    return MusePage(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pinned)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.push_pin, size: 18),
              ),
            Flexible(
              child: Text(agent == null ? 'Message Muse' : 'Message $agent'),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search messages',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) {
                _searchQuery = '';
                _searchController.clear();
              }
            }),
          ),
          PopupMenuButton<String>(
            tooltip: 'Chat options',
            onSelected: (value) {
              switch (value) {
                case 'pin':
                  _togglePin();
                case 'archive':
                  _toggleArchive();
                case 'clear':
                  _clearHistory();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'pin',
                child: Text(_pinned ? 'Unpin chat' : 'Pin chat'),
              ),
              PopupMenuItem(
                value: 'archive',
                child: Text(_archived ? 'Unarchive chat' : 'Archive chat'),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Text('Clear history'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_ready) _OfflineBanner(connection: _connection),
          if (_listening || scope.chat.activity.isNotEmpty)
            _ActivityBanner(
              text: _listening
                  ? 'Listening… release to send'
                  : scope.chat.activity,
            ),
          if (_searching && !_archived)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search messages…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onChanged: (q) => setState(() => _searchQuery = q),
              ),
            ),
          if (_ready && !_listening && !_searching && !_archived) _QuickReplies(
            onPhoto: _capture,
            onSayAgain: () async {
              final reply = scope.chat.lastReply;
              if (reply != null && reply.trim().isNotEmpty) {
                await _speakMessage(reply);
              } else {
                _showError('Nothing to say yet.');
              }
            },
            onCapabilities: () => _post('What can you do?'),
          ),
          Expanded(
            child: _buildMessageArea(),
          ),
          if (_listening)
            _RecordingWaveform(
              amplitude: () =>
                  AppScope.of(context).phone.recordingAmplitude(),
            ),
          if (_slashQuery != null)
            Builder(
              builder: (context) {
                final matches = matchingSlashCommands(_slashQuery!);
                if (matches.isEmpty) return const SizedBox.shrink();
                return SlashCommandMenu(
                  commands: matches,
                  onSelect: _insertSlashCommand,
                );
              },
            ),
          if (!_archived)
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
              onLocalAi: _askLocalAi,
            ),
        ],
      ),
    );
  }

  /// Message-list area: an archived placeholder when the conversation is
  /// archived, otherwise the message list wrapped in a tap-away detector
  /// that dismisses the slash-command popup.
  Widget _buildMessageArea() {
    if (_archived) return _ArchivedPlaceholder(onUnarchive: _toggleArchive);
    final scope = AppScope.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        // Tapping the message list dismisses the slash popup ("tap away");
        // the keyboard and composer are left alone.
        if (_slashQuery != null) setState(() => _slashQuery = null);
      },
      child: StreamBuilder<void>(
        stream: scope.chat.stream,
        builder: (context, _) {
          final all = scope.chat.messages;
          final messages = _searchQuery.trim().isEmpty
              ? all
              : scope.chat.search(_searchQuery);
          if (messages.isEmpty) {
            return _searchQuery.trim().isEmpty
                ? _EmptyHint(ready: _ready)
                : Center(
                    child: Text(
                      'No messages match "$_searchQuery".',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  );
          }
          final items = _buildListItems(messages);
          return ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: items.length,
            itemBuilder: (context, i) => items[i],
          );
        },
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
      ConnectionState.unpaired =>
        'Not paired — messages will fail until you pair.',
      ConnectionState.connecting =>
        'Connecting — messages send once registered.',
      ConnectionState.waiting =>
        'Link down — messages send when it reconnects.',
      ConnectionState.stopped => 'Stopped — messages cannot send.',
      ConnectionState.connected => 'Registering — one moment…',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
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
            const MuseLogo(size: 96),
            const SizedBox(height: 12),
            Text(
              ready
                  ? 'Say hello, hold the mic, or show the camera. Replies show up here.'
                  : 'Messages you send appear here with their delivery state.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: museMist.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown instead of the message list while the conversation is
/// archived. The app-bar menu (or the button below) unarchives it —
/// archived chats are hidden, never deleted.
class _ArchivedPlaceholder extends StatelessWidget {
  const _ArchivedPlaceholder({required this.onUnarchive});

  final VoidCallback onUnarchive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.archive_outlined,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('This chat is archived', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Messages are hidden until you unarchive.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onUnarchive,
              child: const Text('Unarchive chat'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Human-friendly timestamp: "just now" / "5m ago" / "3h ago" / "14:22".
String _relativeTime(DateTime sentAt) {
  final diff = DateTime.now().difference(sentAt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${sentAt.hour.toString().padLeft(2, '0')}:'
      '${sentAt.minute.toString().padLeft(2, '0')}';
}

/// "Today" / "Yesterday" / "Oct 3" divider label.
String _dayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(day.year, day.month, day.day);
  final diff = today.difference(that).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[day.month - 1]} ${day.day}';
}

/// Placeholder bubble labels that the attachment UI already communicates.
bool _isPlaceholderLabel(String text) =>
    text == 'Voice note' ||
    text == '\u{1F3A4} Voice note' ||
    text == 'Photo';

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _dayLabel(date),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// Three bouncing dots while the assistant is streaming.
class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});

  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_controller.value * 3 - i).clamp(0.0, 1.0);
            final scale = 0.5 + 0.5 * (0.5 + 0.5 * (1 - (t - 0.5).abs() * 2));
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.4 + 0.6 * t),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// In-bubble voice note player: play/pause + progress + duration.
class _VoiceNotePlayer extends StatefulWidget {
  const _VoiceNotePlayer({required this.bytes});

  final Uint8List bytes;

  @override
  State<_VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<_VoiceNotePlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _playing = state == PlayerState.playing);
      }
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
      } else {
        if (_position >= _duration && _duration > Duration.zero) {
          await _player.seek(Duration.zero);
        } else if (_position == Duration.zero) {
          await _player.play(BytesSource(widget.bytes));
          return;
        }
        await _player.resume();
      }
    } catch (_) {
      // Playback is best-effort; the bubble stays readable.
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final sec = d.inSeconds % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle),
          iconSize: 36,
          color: theme.colorScheme.primary,
          onPressed: _toggle,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 4),
              Text(
                '${_fmt(_position)} / ${_fmt(_duration)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Photo thumbnail; tap opens the full image.
class _PhotoThumbnail extends StatelessWidget {
  const _PhotoThumbnail({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: InteractiveViewer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(
          bytes,
          width: 200,
          height: 200,
          fit: BoxFit.cover,
          errorBuilder: (context, _, _) => const SizedBox(
            width: 200,
            height: 120,
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.onRetry,
    required this.onDelete,
    required this.onSpeak,
  });

  final ChatMessage message;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback onSpeak;

  void _showActions(BuildContext context) {
    final failed = message.status == ChatStatus.failed;
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Retry send'),
                onTap: () {
                  Navigator.of(context).pop();
                  onRetry();
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy text'),
              onTap: () {
                Navigator.of(context).pop();
                Clipboard.setData(ClipboardData(text: message.text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.volume_up_outlined),
              title: const Text('Speak it'),
              onTap: () {
                Navigator.of(context).pop();
                onSpeak();
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              onTap: () {
                Navigator.of(context).pop();
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = _relativeTime(message.sentAt);
    final mine = message.role == ChatRole.user;
    final failed = message.status == ChatStatus.failed;
    final ink = failed
        ? theme.colorScheme.onErrorContainer
        : mine
        ? Colors.white
        : theme.colorScheme.onSurface;
    final meta = mine && !failed
        ? Colors.white.withValues(alpha: 0.78)
        : failed
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.outline;
    final fill = failed
        ? theme.colorScheme.errorContainer
        : mine
        ? theme.colorScheme.primary
        : (theme.brightness == Brightness.dark
              ? const Color(0xFF14305A)
              : Colors.white);
    final showText =
        message.text.isNotEmpty && !_isPlaceholderLabel(message.text);
    final streamingEmpty = message.text.isEmpty && message.streaming;
    final bubble = Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showActions(context),
        onTap: failed ? onRetry : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(fill, Colors.white, mine ? 0.22 : 0.08)!,
                fill,
                Color.lerp(fill, museBlueDeep, 0.28)!,
              ],
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withValues(alpha: mine ? 0.34 : 0.18),
            ),
            boxShadow: [
              BoxShadow(
                color: museBlue.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.hasImage) ...[
                _PhotoThumbnail(bytes: message.attachmentBytes!),
                const SizedBox(height: 8),
              ],
              if (streamingEmpty)
                _TypingDots(color: ink)
              else if (showText)
                _BubbleText(text: message.text, color: ink, mine: mine)
              else if (message.hasAudio)
                const SizedBox.shrink(),
              if (message.hasAudio) ...[
                const SizedBox(height: 4),
                SizedBox(
                  width: 220,
                  child: _VoiceNotePlayer(bytes: message.attachmentBytes!),
                ),
              ],
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.error.isNotEmpty
                        ? '${message.error} · $time'
                        : failed
                        ? 'Tap to retry · $time'
                        : time,
                    style: theme.textTheme.labelSmall?.copyWith(color: meta),
                  ),
                  const SizedBox(width: 4),
                  _StatusIcon(status: message.status),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return bubble;
  }
}

/// Message text with markdown rendering: bold, italic, lists, links,
/// and fenced code blocks with a copy button.
class _BubbleText extends StatelessWidget {
  const _BubbleText({
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
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium?.copyWith(color: color);
    final sheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: base,
      h1: theme.textTheme.titleLarge?.copyWith(color: color),
      h2: theme.textTheme.titleMedium?.copyWith(color: color),
      h3: theme.textTheme.titleSmall?.copyWith(color: color),
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
        backgroundColor: color.withValues(alpha: 0.12),
      ),
    );
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: sheet,
      builders: {
        'pre': _CodeBlockBuilder(textColor: color),
      },
      onTapLink: (text, href, title) => _openLink(href),
    );
  }
}

/// Fenced code block with a tap-to-copy button.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.textColor});

  final Color textColor;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () => Clipboard.setData(ClipboardData(text: code)),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.copy_outlined,
                  size: 16,
                  color: textColor.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
          SelectableText(
            code,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.4,
              color: textColor,
            ),
          ),
        ],
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
      ChatStatus.sent => Icon(
        Icons.done_all,
        size: 14,
        color: theme.colorScheme.primary,
      ),
      ChatStatus.failed => Icon(
        Icons.error_outline,
        size: 14,
        color: theme.colorScheme.error,
      ),
      ChatStatus.sending => SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: theme.colorScheme.outline,
        ),
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

/// One-tap suggestion chips above the composer.
class _QuickReplies extends StatelessWidget {
  const _QuickReplies({
    required this.onPhoto,
    required this.onSayAgain,
    required this.onCapabilities,
  });

  final VoidCallback onPhoto;
  final VoidCallback onSayAgain;
  final VoidCallback onCapabilities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          _chip(theme, Icons.photo_camera_outlined, 'Take a photo', onPhoto),
          const SizedBox(width: 8),
          _chip(theme, Icons.replay, 'Say it again', onSayAgain),
          const SizedBox(width: 8),
          _chip(
            theme,
            Icons.lightbulb_outline,
            'What can you do?',
            onCapabilities,
          ),
        ],
      ),
    );
  }

  Widget _chip(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return ActionChip(
      avatar: Icon(icon, size: 16, color: theme.colorScheme.primary),
      label: Text(label),
      onPressed: onTap,
    );
  }
}

/// Live mic-level waveform shown while hold-to-talk is active.
/// Polls the native recording amplitude ~10x/sec and renders bars.
class _RecordingWaveform extends StatefulWidget {
  const _RecordingWaveform({required this.amplitude});

  /// Called to sample the current mic amplitude (0..1).
  final Future<double> Function() amplitude;

  @override
  State<_RecordingWaveform> createState() => _RecordingWaveformState();
}

class _RecordingWaveformState extends State<_RecordingWaveform> {
  static const int _bars = 24;
  final List<double> _levels = List.filled(_bars, 0.0);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final level = await widget.amplitude();
      if (!mounted) return;
      setState(() {
        _levels.removeAt(0);
        // Amplify for visibility; real silence stays near zero.
        _levels.add((level * 2.5).clamp(0.0, 1.0));
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.mic,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          ..._levels.map(
            (level) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: 3,
                height: 4 + level * 28,
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(
                    alpha: 0.35 + 0.65 * level,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Release to send',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
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
    required this.onLocalAi,
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
  final Future<void> Function() onLocalAi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = ready
        ? 'Message your Muse…'
        : switch (connection) {
            ConnectionState.unpaired => 'Pair first to message…',
            ConnectionState.connecting ||
            ConnectionState.waiting => 'Waiting for the link…',
            _ => 'Unavailable right now…',
          };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Ask local AI (LM Studio)',
            onPressed: ready ? onLocalAi : null,
            icon: const Icon(Icons.smart_toy_outlined),
          ),
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
                  horizontal: 16,
                  vertical: 12,
                ),
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
              icon: Icon(Icons.send, color: theme.colorScheme.onPrimary),
              onPressed: onSend,
            ),
          ),
        ],
      ),
    );
  }
}
