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
// OpenRouter cloud text-to-speech, an OPT-IN alternative to the native
// Android TTS engine. The Android path stays the default and is untouched;
// this service only runs when the user picks "OpenRouter" in Settings and
// has saved an API key.
//
// API shape follows OpenAI's /v1/audio/speech:
//   POST https://openrouter.ai/api/v1/audio/speech
//   {"model": "<model id>", "input": "<text>", "voice": "<voice id>",
//    "response_format": "mp3"}
// The response body is the audio bytes (error responses are JSON).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;

/// OpenRouter TTS endpoint (OpenAI-compatible shape).
const String kOpenRouterSpeechUrl = 'https://openrouter.ai/api/v1/audio/speech';

/// Default model when the user has not picked one. User-editable in
/// Settings; OpenRouter rotates free models, so it is never hard-coded
/// into a request path.
const String kDefaultOpenRouterModel = 'fish-audio/s2.1-pro-free:free';

/// Longest text sent in one TTS request. TTS models have per-request
/// character limits (a few thousand); longer replies are split on
/// sentence boundaries and played back to back.
const int kOpenRouterTtsChunkChars = 1800;

/// User-facing failure from an OpenRouter TTS call. Never carries the key.
class OpenRouterTtsException implements Exception {
  const OpenRouterTtsException(this.message);
  final String message;
  @override
  String toString() => 'OpenRouterTtsException: $message';
}

/// Synthesizes text through OpenRouter and plays the audio on the phone
/// speaker. One instance per app; [stop] interrupts playback and the
/// pending [synthesizeAndPlay] returns promptly.
class OpenRouterTts {
  OpenRouterTts() {
    _completeSub = _player.onPlayerComplete.listen((_) {
      _finishPlayback();
    });
  }

  final AudioPlayer _player = AudioPlayer();
  late final StreamSubscription<void> _completeSub;

  Completer<void>? _playbackDone;
  bool _stopped = false;

  void _finishPlayback() {
    final done = _playbackDone;
    _playbackDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Synthesize [text] and play it. Throws [OpenRouterTtsException] with a
  /// user-readable message when the key, model, or network fails.
  Future<void> synthesizeAndPlay({
    required String text,
    required String apiKey,
    required String model,
    String voice = '',
  }) async {
    _stopped = false;
    for (final chunk in _chunkText(text)) {
      if (_stopped) break;
      final audio = await _synthesize(
        text: chunk,
        apiKey: apiKey,
        model: model,
        voice: voice,
      );
      if (_stopped) break;
      await _playBytes(audio);
    }
  }

  /// Stop playback immediately; a pending [synthesizeAndPlay] returns.
  Future<void> stop() async {
    _stopped = true;
    try {
      await _player.stop();
    } catch (_) {
      // The player may already be idle; stopping is best-effort.
    }
    _finishPlayback();
  }

  Future<void> _playBytes(Uint8List audio) async {
    _playbackDone = Completer<void>();
    await _player.play(BytesSource(audio));
    await _playbackDone!.future;
  }

  Future<Uint8List> _synthesize({
    required String text,
    required String apiKey,
    required String model,
    required String voice,
  }) async {
    final body = <String, Object?>{
      'model': model,
      'input': text,
      'response_format': 'mp3',
    };
    if (voice.isNotEmpty) body['voice'] = voice;
    http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(kOpenRouterSpeechUrl),
            headers: {
              // The key is sent only in this header, never logged.
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw const OpenRouterTtsException(
        'OpenRouter timed out. Check the connection and try again.',
      );
    } catch (_) {
      throw const OpenRouterTtsException(
        'Could not reach OpenRouter. Check the connection and try again.',
      );
    }
    if (response.statusCode == 200) {
      if (response.bodyBytes.isEmpty) {
        throw const OpenRouterTtsException('OpenRouter returned empty audio.');
      }
      return response.bodyBytes;
    }
    throw OpenRouterTtsException(_friendlyError(response));
  }

  /// Error bodies are JSON; map the common failures to plain language.
  /// The key is never included in any message.
  static String _friendlyError(http.Response response) {
    final code = response.statusCode;
    String detail = '';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic> && error['message'] is String) {
          detail = error['message'] as String;
        } else if (decoded['message'] is String) {
          detail = decoded['message'] as String;
        }
      }
    } catch (_) {
      // Non-JSON error body; fall through to the generic message.
    }
    if (code == 401 || code == 403) {
      return 'OpenRouter rejected the API key. Check it in Settings.';
    }
    if (code == 402) {
      return 'OpenRouter reports insufficient credit for this request.';
    }
    if (code == 429) {
      return 'OpenRouter rate-limited the request. Wait a moment and try again.';
    }
    if (code == 404) {
      return 'OpenRouter has no such model. Update the model id in Settings.';
    }
    if (detail.isNotEmpty && detail.length <= 200) return 'OpenRouter: $detail';
    return 'OpenRouter request failed (HTTP $code).';
  }

  /// Split long text into request-sized chunks on sentence boundaries so
  /// no request exceeds the model's input limit.
  static List<String> _chunkText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.length <= kOpenRouterTtsChunkChars) return [trimmed];
    final chunks = <String>[];
    final sentences = trimmed.split(RegExp(r'(?<=[.!?])\s+'));
    final current = StringBuffer();
    for (final sentence in sentences) {
      if (current.length + sentence.length + 1 > kOpenRouterTtsChunkChars &&
          current.isNotEmpty) {
        chunks.add(current.toString().trim());
        current.clear();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(sentence);
    }
    if (current.isNotEmpty) chunks.add(current.toString().trim());
    return chunks;
  }

  Future<void> dispose() async {
    await _completeSub.cancel();
    await _player.dispose();
  }
}
