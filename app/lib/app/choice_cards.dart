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
// Interactive display cards: title + text + up to 4 buttons with a TTL.
//
// The agent shows a card with `display.show_card`; the user taps a button
// on the phone (or the card expires). The choice is recorded, not
// pushed: the agent reads it back with `display.card_status`, which
// reports the current card (if any) and the last choice. One card at a
// time — showing a new card replaces the old one. Cards are ephemeral
// (in-memory only, never persisted).

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Thrown for invalid card definitions.
class ChoiceCardException implements Exception {
  ChoiceCardException(this.message);

  final String message;

  @override
  String toString() => 'ChoiceCardException: $message';
}

/// One tappable button on a card.
class CardButton {
  const CardButton({required this.id, required this.label});

  final String id;
  final String label;

  Map<String, Object?> toJson() => {'id': id, 'label': label};

  static CardButton fromJson(Map<String, Object?> json) {
    final id = json['id']?.toString().trim() ?? '';
    final label = json['label']?.toString().trim() ?? '';
    if (id.isEmpty || label.isEmpty) {
      throw ChoiceCardException('card buttons need an id and a label');
    }
    return CardButton(id: id, label: label);
  }
}

/// A shown card: content plus expiry.
class ChoiceCard {
  const ChoiceCard({
    required this.id,
    required this.title,
    required this.text,
    this.imageUrl = '',
    this.buttons = const [],
    required this.expiresAt,
  });

  final String id;
  final String title;
  final String text;
  final String imageUrl;
  final List<CardButton> buttons;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
    'card_id': id,
    'title': title,
    'text': text,
    if (imageUrl.isNotEmpty) 'image_url': imageUrl,
    'buttons': [for (final b in buttons) b.toJson()],
    'expires_at': expiresAt.toIso8601String(),
  };
}

/// A recorded button tap.
class CardChoice {
  const CardChoice({
    required this.cardId,
    required this.buttonId,
    required this.at,
  });

  final String cardId;
  final String buttonId;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'card_id': cardId,
    'button_id': buttonId,
    'at': at.toIso8601String(),
  };
}

/// Current card + choice history. A [ChangeNotifier] so the companion
/// screen overlay rebuilds on show/choose/expire/clear.
class ChoiceCardStore extends ChangeNotifier {
  /// Process-wide instance the UI observes.
  static final ChoiceCardStore instance = ChoiceCardStore();

  /// Max buttons per card: a phone stage, not a web page.
  static const int maxButtons = 4;

  /// Max card lifetime in seconds.
  static const int maxTtlSeconds = 3600;

  ChoiceCard? _current;
  CardChoice? _lastChoice;
  Timer? _expiry;

  ChoiceCard? get current => _current;
  CardChoice? get lastChoice => _lastChoice;

  /// Show a card, replacing any current one. Returns the shown card.
  /// Non-positive [ttlSeconds] means no expiry (tests, persistent info).
  ChoiceCard show({
    required String title,
    String text = '',
    String imageUrl = '',
    List<CardButton> buttons = const [],
    int ttlSeconds = 60,
  }) {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw ChoiceCardException('card title is required');
    }
    if (buttons.length > maxButtons) {
      throw ChoiceCardException('at most $maxButtons buttons per card');
    }
    final ids = buttons.map((b) => b.id).toList();
    if (ids.toSet().length != ids.length) {
      throw ChoiceCardException('card button ids must be unique');
    }
    final ttl = ttlSeconds <= 0
        ? null
        : Duration(seconds: ttlSeconds.clamp(1, maxTtlSeconds));
    _expiry?.cancel();
    _expiry = null;
    _current = ChoiceCard(
      id: 'card_${DateTime.now().microsecondsSinceEpoch}',
      title: cleanTitle,
      text: text.trim(),
      imageUrl: imageUrl.trim(),
      buttons: List.unmodifiable(buttons),
      expiresAt: ttl == null
          ? DateTime.fromMillisecondsSinceEpoch(1 << 62)
          : DateTime.now().add(ttl),
    );
    if (ttl != null) {
      _expiry = Timer(ttl, () {
        _current = null;
        _expiry = null;
        notifyListeners();
      });
    }
    notifyListeners();
    return _current!;
  }

  /// Record the user's tap on [buttonId] and dismiss the card.
  /// Returns false when there is no current card or the button is
  /// unknown (stale taps never fabricate a choice).
  bool choose(String buttonId) {
    final card = _current;
    if (card == null) return false;
    if (!card.buttons.any((b) => b.id == buttonId)) return false;
    _lastChoice = CardChoice(
      cardId: card.id,
      buttonId: buttonId,
      at: DateTime.now(),
    );
    _expiry?.cancel();
    _expiry = null;
    _current = null;
    notifyListeners();
    return true;
  }

  /// Dismiss the current card without recording a choice.
  void clear() {
    if (_current == null) return;
    _expiry?.cancel();
    _expiry = null;
    _current = null;
    notifyListeners();
  }

  Map<String, Object?> status() => {
    'card': _current?.toJson(),
    'last_choice': _lastChoice?.toJson(),
  };

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }
}
