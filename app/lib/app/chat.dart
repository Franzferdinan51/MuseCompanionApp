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
// Outgoing message history for the Message screen.
//
// The link protocol carries device-to-Muse chat only; the Muse answers
// through display commands, not chat messages. So this history is
// honestly one-sided: what this device sent, when, and whether the
// send was acknowledged. It lives for the app session and never touches
// the network itself — the screen drives `GadgetService.sendChat`.

import 'dart:async';

/// Delivery state of one outgoing message.
enum ChatStatus {
  sending,
  sent,
  failed,
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.text,
    required this.sentAt,
    required this.status,
    this.error = '',
  });

  final int id;
  final String text;
  final DateTime sentAt;
  ChatStatus status;
  String error;
}

/// Session-scoped outgoing messages, oldest first, bounded in memory.
class ChatHistory {
  ChatHistory({this.maxMessages = 100});

  final int maxMessages;
  final List<ChatMessage> _messages = <ChatMessage>[];
  final StreamController<void> _changes =
      StreamController<void>.broadcast();
  int _nextId = 1;

  /// Fires on every add or status change.
  Stream<void> get stream => _changes.stream;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Record a message about to be sent; returns its id.
  int addSending(String text) {
    final message = ChatMessage(
      id: _nextId++,
      text: text,
      sentAt: DateTime.now(),
      status: ChatStatus.sending,
    );
    _messages.add(message);
    while (_messages.length > maxMessages) {
      _messages.removeAt(0);
    }
    _emit();
    return message.id;
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

  /// Retry a failed message: back to `sending`, keeps its place.
  void markRetrying(int id) {
    final message = _find(id);
    if (message == null) return;
    message.status = ChatStatus.sending;
    message.error = '';
    _emit();
  }

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
