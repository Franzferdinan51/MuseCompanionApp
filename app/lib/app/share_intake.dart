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
// Share-to-app intake ("Share to Juno").
//
// Concept ported from hermes-mobile-app (MIT licensed, Omar Qaterge,
// https://github.com/omarqaterge/hermes-mobile-app — their `web/src/share.ts`
// lands shares in the composer as attachments, never auto-sent). Here the
// `receive_sharing_intent` plugin feeds shared content into the chat
// composer: shared text is pre-filled in the text field, shared images join
// the pending-attachment tray. Nothing is ever auto-sent.

import 'dart:async';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// One batch of shared content from another app.
class SharedBatch {
  SharedBatch({required this.text, required this.files});

  /// Shared text (plain text or URL), '' when the batch has none.
  final String text;

  /// Shared images (ACTION_SEND / ACTION_SEND_MULTIPLE), empty when none.
  final List<SharedMediaFile> files;
}

/// Listens for Android share intents, cold start and warm, and turns them
/// into [SharedBatch]es. Single shared instance; call [arm] once (e.g. from
/// the chat screen) and [dispose] when it goes away.
class ShareIntake {
  ShareIntake._();

  static final ShareIntake instance = ShareIntake._();

  StreamSubscription<List<SharedMediaFile>>? _warmSub;
  bool _armed = false;

  /// Start listening. [onBatch] fires once per share batch, whether the app
  /// was cold-started by the share intent or was already running.
  void arm(void Function(SharedBatch batch) onBatch) {
    if (_armed) return;
    _armed = true;
    // Cold start: the app was launched by the share intent.
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty) {
        onBatch(_toBatch(files));
        ReceiveSharingIntent.instance.reset();
      }
    });
    // Warm: the app is already running and a new share intent arrives
    // (delivered via the activity's onNewIntent).
    _warmSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) {
        if (files.isEmpty) return;
        onBatch(_toBatch(files));
        ReceiveSharingIntent.instance.reset();
      },
      onError: (_) {
        // A broken share must never take the chat screen down with it.
      },
    );
  }

  SharedBatch _toBatch(List<SharedMediaFile> files) {
    // NOTE (verified against receive_sharing_intent 1.9.0 source):
    // SharedMediaFile has no `.text` getter — text shares arrive with
    // type == SharedMediaType.text and the text itself in `path`.
    // `message` only carries the iOS share-extension post message.
    final texts = <String>[];
    final images = <SharedMediaFile>[];
    for (final file in files) {
      switch (file.type) {
        case SharedMediaType.text:
        case SharedMediaType.url:
          final candidate = (file.message?.trim().isNotEmpty ?? false)
              ? file.message!.trim()
              : file.path.trim();
          if (candidate.isNotEmpty) texts.add(candidate);
        case SharedMediaType.image:
          images.add(file);
        case SharedMediaType.video:
        case SharedMediaType.file:
          // Not in our intent filters; ignore.
          break;
      }
    }
    return SharedBatch(text: texts.join('\n\n'), files: images);
  }

  Future<void> dispose() async {
    await _warmSub?.cancel();
    _warmSub = null;
    _armed = false;
  }
}
