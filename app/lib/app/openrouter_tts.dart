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

import '../src/gadget/phone_actions.dart';

/// OpenRouter TTS endpoint (OpenAI-compatible shape).
const String kOpenRouterSpeechUrl = 'https://openrouter.ai/api/v1/audio/speech';

/// Default model when the user has not picked one. User-editable in
/// Settings; OpenRouter rotates free models, so it is never hard-coded
/// into a request path.
const String kDefaultOpenRouterModel = 'fish-audio/s2.1-pro-free:free';

/// Fish Audio S2.1 Pro, the free OpenRouter route (same id as
/// [kDefaultOpenRouterModel], named for the Settings picker).
const String kFishAudioFreeModel = 'fish-audio/s2.1-pro-free:free';

/// Drama 3, served LOCALLY by the Mac TTS server (Drama 3 is
/// local-only, never OpenRouter). The id is the local server's
/// model name; older saved settings holding the OpenRouter id
/// 'fish-audio/drama-3' route to the same local engine.
const String kDrama3Model = 'drama-3';

/// The OpenRouter id Drama 3 used before it went local-only.
/// Saved settings may still hold it; it routes locally too.
const String kDrama3OpenRouterId = 'fish-audio/drama-3';

/// Qwen3-TTS on the local Mac server: the fast, small engine.
const String kQwen3Model = 'qwen3-tts';

/// Default base URL of the local Mac TTS server (LAN). Editable
/// in Settings; the server speaks the same /v1/audio/speech shape.
const String kDefaultLocalTtsBase = 'http://192.168.1.96:8799';

/// Whether [model] is served by the local Mac TTS server.
bool isLocalTtsModel(String model) =>
    model == kDrama3Model ||
    model == kDrama3OpenRouterId ||
    model == kQwen3Model;

/// Whether [model] selects the local Drama 3 engine.
bool isDramaTtsModel(String model) =>
    model == kDrama3Model || model == kDrama3OpenRouterId;

/// The model id the local server expects for [model].
String localTtsModelId(String model) =>
    model == kQwen3Model ? kQwen3Model : kDrama3Model;

/// Built-in Fish Audio voices (public catalog reference ids), the
/// same preset list the watch offers. The Settings voice picker
/// writes one of these ids into the voice field; any other id can
/// still be typed by hand.
const Map<String, String> kFishVoicePresets = {
  'Sarah': '933563129e564b19a115bedd57b7406a',
  'Selene': 'b347db033a6549378b48d00acb0d06cd',
  'Hannah': '9a9cf47702da476aa4629e2506d4a857',
  'Friendly': 'b545c585f631496c914815291da4e893',
  'Polo': 'f48d143a59a946ab87c0130fd081f349',
  'Adrian': 'bf322df2096a46f18c579d0baa36f41d',
  'Ethan': '536d3a5e000945adb7038665781a4aca',
  'Elite': 'd8a1340984ee4b63ad1ffae27a6a4339',
  'Jordan': '79d0bd3e4e5444b18f7b6d89b5927bf1',
  'Energetic': '802e3bc2b27e49c2995d23ef70e6ac89',
  'Atomic': '4c6a6762e4ac4bdebdb4fa8525d054a2',
  'Announcer': '90e65eaaf50e4470b8e6d43ee6afd7d5',
};

/// Longest text sent in one TTS request. TTS models have per-request
/// character limits (a few thousand); longer replies are split on
/// sentence boundaries and played back to back.
const int kOpenRouterTtsChunkChars = 1800;

/// Local engines generate on the Mac; smaller chunks keep each
/// request (and the wait for the first audio) short.
const int kLocalTtsChunkChars = 600;

/// User-facing failure from an OpenRouter TTS call. Never carries the key.
/// Extends [PhoneActionException] so existing catch blocks handle it.
class OpenRouterTtsException extends PhoneActionException {
  const OpenRouterTtsException(super.message);
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
    String localBase = kDefaultLocalTtsBase,
  }) async {
    _stopped = false;
    final chunkLimit = isLocalTtsModel(model)
        ? kLocalTtsChunkChars
        : kOpenRouterTtsChunkChars;
    for (final chunk in _chunkText(text, chunkLimit)) {
      if (_stopped) break;
      final audio = await _synthesize(
        text: chunk,
        apiKey: apiKey,
        model: model,
        voice: voice,
        localBase: localBase,
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
    required String localBase,
  }) async {
    final local = isLocalTtsModel(model);
    final body = <String, Object?>{
      'model': local ? localTtsModelId(model) : model,
      'input': text,
      'response_format': 'mp3',
    };
    if (voice.isNotEmpty) body['voice'] = voice;
    http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(
              local
                  ? '$localBase/v1/audio/speech'
                  : kOpenRouterSpeechUrl,
            ),
            headers: {
              // The key is sent only in this header, never logged,
              // and never sent to the local server at all.
              if (!local) 'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(Duration(seconds: local ? 180 : 60));
    } on TimeoutException {
      throw OpenRouterTtsException(
        local
            ? 'The local TTS server timed out. Is it running on the Mac?'
            : 'OpenRouter timed out. Check the connection and try again.',
      );
    } catch (_) {
      throw OpenRouterTtsException(
        local
            ? 'Could not reach the local TTS server. Is it running on the Mac?'
            : 'Could not reach OpenRouter. Check the connection and try again.',
      );
    }
    if (response.statusCode == 200) {
      if (response.bodyBytes.isEmpty) {
        throw OpenRouterTtsException(
          local
              ? 'The local TTS server returned empty audio.'
              : 'OpenRouter returned empty audio.',
        );
      }
      return response.bodyBytes;
    }
    throw OpenRouterTtsException(
      local ? _friendlyLocalError(response) : _friendlyError(response),
    );
  }

  /// Error bodies are JSON; map the common failures to plain language.
  /// The key is never included in any message.
  /// The error detail string from a JSON error body, or ''.
  static String _errorDetail(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic> && error['message'] is String) {
          return error['message'] as String;
        } else if (decoded['message'] is String) {
          return decoded['message'] as String;
        }
      }
    } catch (_) {
      // Non-JSON error body; no detail to surface.
    }
    return '';
  }

  static String _friendlyError(http.Response response) {
    final code = response.statusCode;
    final detail = _errorDetail(response);
    if (code == 403 && detail.toLowerCase().contains('limit')) {
      // A $0-limit key is valid but may not spend; Drama 3 lands here.
      return 'OpenRouter: $detail Raise the key limit in OpenRouter '
          'to use this model.';
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

  /// Error mapping for the local Mac TTS server.
  static String _friendlyLocalError(http.Response response) {
    final detail = _errorDetail(response);
    if (detail.isNotEmpty && detail.length <= 200) {
      return 'Local TTS server: $detail';
    }
    return 'Local TTS server request failed (HTTP ${response.statusCode}).';
  }

  /// Split long text into request-sized chunks on sentence boundaries so
  /// no request exceeds the model's input limit.
  static List<String> _chunkText(
    String text, [
    int limit = kOpenRouterTtsChunkChars,
  ]) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.length <= limit) return [trimmed];
    final chunks = <String>[];
    final sentences = trimmed.split(RegExp(r'(?<=[.!?])\s+'));
    final current = StringBuffer();
    for (final sentence in sentences) {
      if (current.length + sentence.length + 1 > limit &&
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
