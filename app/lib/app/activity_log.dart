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
// In-memory activity log: chat sends, gadget invokes, voice notes, photos.
// Feeds the Activity tab. Bounded (200 entries), session-scoped, never
// leaves the device.

import 'dart:async';

/// What kind of thing happened.
enum ActivityKind { chat, invoke, voice, photo, system }

/// One logged event.
class ActivityEntry {
  const ActivityEntry({
    required this.at,
    required this.kind,
    required this.summary,
    this.detail = '',
    this.ok = true,
  });

  final DateTime at;
  final ActivityKind kind;
  final String summary;
  final String detail;
  final bool ok;
}

/// Process-wide activity log. Add events from anywhere; the Activity tab
/// rebuilds on [stream].
class ActivityLog {
  ActivityLog._();

  static final ActivityLog instance = ActivityLog._();

  static const int maxEntries = 200;

  final List<ActivityEntry> _entries = <ActivityEntry>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Fires on every add or clear.
  Stream<void> get stream => _changes.stream;

  /// Newest first.
  List<ActivityEntry> get entries =>
      List.unmodifiable(_entries.reversed);

  void add(
    ActivityKind kind,
    String summary, {
    String detail = '',
    bool ok = true,
  }) {
    _entries.add(
      ActivityEntry(
        at: DateTime.now(),
        kind: kind,
        summary: summary,
        detail: detail,
        ok: ok,
      ),
    );
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  void clear() {
    _entries.clear();
    if (!_changes.isClosed) _changes.add(null);
  }
}
