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
// Message history for the Message screen.
//
// What this phone sends is recorded here, and so are the assistant
// replies that arrive on `/chat/subscribe` (`delta.text_append` and
// `delta.message_done`). The screen drives `GadgetService.sendChat`;
// this class never touches the network itself.

import 'dart:async';
import 'dart:typed_data';

/// Delivery state of one message.
enum ChatStatus { sending, sent, failed, queued }

/// Who wrote the bubble.
enum ChatRole { user, assistant }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.text,
    required this.sentAt,
    required this.status,
    this.error = '',
    this.role = ChatRole.user,
    this.streaming = false,
    this.serverId,
    this.attachmentBytes,
    this.attachmentMime,
    this.attachmentName,
    this.canvasDocId,
    this.canvasTitle,
    this.canvasUpdated = false,
  });

  final int id;
  String text;
  final DateTime sentAt;
  ChatStatus status;
  String error;
  final ChatRole role;
  bool streaming;

  /// Muse message id, so streamed deltas land on the same bubble.
  String? serverId;

  /// Optional attachment sent with this message (voice note WAV or photo
  /// JPEG). Stored on the message so bubbles can render playback/thumbnails
  /// without re-fetching.
  final Uint8List? attachmentBytes;
  final String? attachmentMime;
  final String? attachmentName;

  /// Set when this message is a tappable canvas document card: the
  /// document id to open on the Canvas screen.
  final String? canvasDocId;

  /// Title shown on the canvas card.
  final String? canvasTitle;

  /// True when the card represents an update to an existing document
  /// (vs. a newly created one).
  final bool canvasUpdated;

  /// True when this message carries an audio attachment.
  bool get hasAudio =>
      attachmentBytes != null && (attachmentMime ?? '').startsWith('audio/');

  /// True when this message carries an image attachment.
  bool get hasImage =>
      attachmentBytes != null && (attachmentMime ?? '').startsWith('image/');
}

/// Session-scoped outgoing messages, oldest first, bounded in memory.
class ChatHistory {
  ChatHistory({this.maxMessages = 100});

  final int maxMessages;
  final List<ChatMessage> _messages = <ChatMessage>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();
  int _nextId = 1;
  String _activity = '';

  /// Spoken when an assistant reply finishes.
  void Function(String text)? onAssistantDone;

  /// Live caption text while a reply is streaming or has just finished.
  void Function(String text)? onCaption;

  /// Activity code from `agent.status`, such as `thinking`.
  void Function(String code)? onActivity;

  /// Transcript Muse attached to the latest voice note.
  void Function(String text)? onHeard;

  /// Last finished assistant reply, for "say it again".
  String? get lastReply => _lastReply;
  String? _lastReply;

  /// Short Muse activity label from `agent.status`, or empty.
  String get activity => _activity;

  /// True while an assistant bubble is still receiving text.
  bool get assistantStreaming => _messages.any(
    (message) => message.role == ChatRole.assistant && message.streaming,
  );

  /// Fires on every add or status change.
  Stream<void> get stream => _changes.stream;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Record a message about to be sent; returns its id.
  int addSending(
    String text, {
    Uint8List? attachmentBytes,
    String? attachmentMime,
    String? attachmentName,
  }) {
    final message = ChatMessage(
      id: _nextId++,
      text: text,
      sentAt: DateTime.now(),
      status: ChatStatus.sending,
      attachmentBytes: attachmentBytes,
      attachmentMime: attachmentMime,
      attachmentName: attachmentName,
    );
    _messages.add(message);
    _trim();
    _emit();
    return message.id;
  }

  /// Post a finished local-AI reply as an assistant message. Used by
  /// the on-device LM Studio flow, which has no server turn to fold in.
  void addLocalAssistant(String text) {
    _messages.add(
      ChatMessage(
        id: _nextId++,
        text: text,
        sentAt: DateTime.now(),
        status: ChatStatus.sent,
        role: ChatRole.assistant,
      ),
    );
    _trim();
    _emit();
    if (text.trim().isNotEmpty) {
      _lastReply = text;
      onCaption?.call(text);
      onAssistantDone?.call(text);
    }
  }

  /// Post a tappable canvas document card as an assistant message. The
  /// bubble renders the card; tapping opens the document on the Canvas
  /// screen. [updated] marks an update to an existing document vs. a
  /// fresh creation.
  void addCanvasCard({
    required String docId,
    required String title,
    bool updated = false,
  }) {
    _messages.add(
      ChatMessage(
        id: _nextId++,
        text: updated
            ? 'Updated canvas document: $title'
            : 'Canvas document: $title',
        sentAt: DateTime.now(),
        status: ChatStatus.sent,
        role: ChatRole.assistant,
        canvasDocId: docId,
        canvasTitle: title,
        canvasUpdated: updated,
      ),
    );
    _trim();
    _emit();
  }

  /// Mark [id] delivered.
  void markSent(int id) {
    final message = _find(id);
    if (message == null) return;
    message.status = ChatStatus.sent;
    message.error = '';
    _emit();
  }

  /// Mark [id] failed with a human-readable [error].
  void markFailed(int id, String error) {
    final message = _find(id);
    if (message == null) return;
    message.status = ChatStatus.failed;
    message.error = error;
    _emit();
  }

  /// Queue [id] for the offline outbox: the send failed and the
  /// message waits in the outbox for the next flush. Keeps its place.
  void markQueued(int id, String error) {
    final message = _find(id);
    if (message == null) return;
    message.status = ChatStatus.queued;
    message.error = error;
    _emit();
  }

  /// Retry a failed message: back to `sending`, keeps its place.
  void markRetrying(int id) {
    final message = _find(id);
    if (message == null) return;
    message.status = ChatStatus.sending;
    message.error = '';
    _emit();
  }

  /// Remove a message (long-press delete). Returns true when removed.
  bool deleteMessage(int id) {
    final index = _messages.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    _messages.removeAt(index);
    _emit();
    return true;
  }

  /// Find a message by id, or null.
  ChatMessage? find(int id) => _find(id);

  /// Restore one persisted message (used by ChatStore). The id is
  /// reassigned so it cannot collide with live messages.
  void restoreMessage(ChatMessage message) {
    _messages.add(
      ChatMessage(
        id: _nextId++,
        text: message.text,
        sentAt: message.sentAt,
        status: message.status == ChatStatus.sending
            ? ChatStatus.sent
            : message.status,
        role: message.role,
        canvasDocId: message.canvasDocId,
        canvasTitle: message.canvasTitle,
        canvasUpdated: message.canvasUpdated,
      ),
    );
    _trim();
    _emit();
  }

  /// Remove all messages (clear-history action).
  void clearAll() {
    _messages.clear();
    _emit();
  }

  /// Case-insensitive text search over message bodies.
  List<ChatMessage> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _messages.where((m) => m.text.toLowerCase().contains(q)).toList();
  }

  /// Fold one `/chat/subscribe` event into the history.
  void applyServerEvent(String name, Map<String, Object?> payload) {
    final role = _text(payload['role']) ?? _text(payload['author']);
    if (role == 'user' ||
        role == 'human' ||
        name == 'transcript' ||
        name == 'message.user') {
      final heard =
          _text(payload['transcript']) ??
          _text(payload['display_text']) ??
          _text(payload['content']) ??
          _text(payload['text']);
      if (heard != null) _applyHeard(heard);
      return;
    }
    if (name == 'agent.status' || name == 'task.status') {
      final code = _text(payload['activity_code']) ?? _text(payload['status']);
      _activity = code ?? '';
      _emit();
      if (code != null) onActivity?.call(code);
      return;
    }
    final serverId =
        _text(payload['message_id']) ?? _text(payload['id']) ?? 'assistant';
    if (name == 'delta.message_start') {
      _beginAssistant(serverId);
    } else if (name == 'delta.text_append') {
      final text = _text(payload['text']);
      if (text != null && text.isNotEmpty) _appendAssistant(serverId, text);
    } else if (name == 'delta.message_done' || name == 'message.assistant') {
      final full =
          _text(payload['display_text']) ??
          _text(payload['content']) ??
          _text(payload['text']);
      _finishAssistant(serverId, full);
    }
  }

  void _beginAssistant(String serverId) {
    if (_byServer(serverId) != null) return;
    _messages.add(
      ChatMessage(
        id: _nextId++,
        text: '',
        sentAt: DateTime.now(),
        status: ChatStatus.sending,
        role: ChatRole.assistant,
        streaming: true,
        serverId: serverId,
      ),
    );
    _trim();
    _emit();
  }

  void _appendAssistant(String serverId, String chunk) {
    final message = _byServer(serverId) ?? _createAssistant(serverId);
    message.text = message.text + chunk;
    message.streaming = true;
    message.status = ChatStatus.sending;
    _emit();
    if (message.text.trim().isNotEmpty) onCaption?.call(message.text);
  }

  void _finishAssistant(String serverId, String? full) {
    final message = _byServer(serverId) ?? _createAssistant(serverId);
    if (full != null && full.length >= message.text.length) {
      message.text = full;
    }
    final finishedNow = message.streaming || message.status != ChatStatus.sent;
    message.streaming = false;
    message.status = ChatStatus.sent;
    _emit();
    if (message.text.trim().isNotEmpty) {
      _lastReply = message.text;
      // Streaming is already false, so this caption does not move the face.
      onCaption?.call(message.text);
    }
    // Including an empty finish, so a turn that produced no text still
    // leaves the face. A repeat of the same message does not.
    if (finishedNow) onAssistantDone?.call(message.text);
  }

  /// Replace the latest "Voice note" bubble with what Muse heard.
  ///
  /// Typed messages are left alone, so an echo of the user's own text
  /// does not add a second bubble.
  void _applyHeard(String text) {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final message = _messages[i];
      if (message.role != ChatRole.user) continue;
      if (message.text != 'Voice note') return;
      message.text = text;
      _emit();
      onHeard?.call(text);
      return;
    }
  }

  ChatMessage _createAssistant(String serverId) {
    final message = ChatMessage(
      id: _nextId++,
      text: '',
      sentAt: DateTime.now(),
      status: ChatStatus.sending,
      role: ChatRole.assistant,
      streaming: true,
      serverId: serverId,
    );
    _messages.add(message);
    _trim();
    return message;
  }

  ChatMessage? _byServer(String serverId) {
    for (final message in _messages) {
      if (message.serverId == serverId) return message;
    }
    return null;
  }

  void _trim() {
    while (_messages.length > maxMessages) {
      _messages.removeAt(0);
    }
  }

  String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  ChatMessage? _find(int id) {
    for (final message in _messages) {
      if (message.id == id) return message;
    }
    return null;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void close() {
    if (!_changes.isClosed) _changes.close();
  }
}
