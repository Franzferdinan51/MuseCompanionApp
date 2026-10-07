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
// Audio playback queue for the agent.
//
// [MediaQueue] is pure queue logic (add/remove/reorder, capped at 50
// http(s) tracks). [MediaQueuePlayer] binds a queue to an audio backend
// and auto-advances on track completion. The production backend drives
// audioplayers; unit tests inject a fake. The agent reaches this through
// the `media.enqueue/queue/play/control/clear` commands and the matching
// media_* local tools. Audio only in v1: video needs a visible surface.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

/// Thrown for invalid queue operations.
class MediaQueueException implements Exception {
  MediaQueueException(this.message);

  final String message;

  @override
  String toString() => 'MediaQueueException: $message';
}

/// One queued audio track.
class MediaTrack {
  const MediaTrack({required this.url, this.title = '', this.mime = ''});

  final String url;
  final String title;
  final String mime;

  Map<String, Object?> toJson() => {
    'url': url,
    'title': title,
    'mime': mime,
  };

  static bool isPlayableUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }
}

/// Pure playback order. Index -1 means nothing selected yet.
class MediaQueue {
  final List<MediaTrack> _tracks = [];
  int _index = -1;

  /// Max queued tracks; oldest-upcoming entries are refused past this.
  static const int maxTracks = 50;

  List<MediaTrack> get tracks => List.unmodifiable(_tracks);
  int get index => _index;
  int get length => _tracks.length;
  bool get isEmpty => _tracks.isEmpty;

  MediaTrack? get current =>
      (_index >= 0 && _index < _tracks.length) ? _tracks[_index] : null;

  /// Add to the end, or right after the current track when [next] is
  /// true. Selects the first track added to an empty queue.
  void add(MediaTrack track, {bool next = false}) {
    if (!MediaTrack.isPlayableUrl(track.url)) {
      throw MediaQueueException('only http(s) audio URLs can be queued');
    }
    if (_tracks.length >= maxTracks) {
      throw MediaQueueException('queue is full ($maxTracks tracks)');
    }
    if (next && _index >= 0) {
      _tracks.insert(_index + 1, track);
    } else {
      _tracks.add(track);
    }
    if (_index < 0) _index = 0;
  }

  /// Drop the track at [at]. The selection follows the music: removing
  /// the current track selects whatever slides into its place.
  void removeAt(int at) {
    if (at < 0 || at >= _tracks.length) {
      throw MediaQueueException('no track at index $at');
    }
    _tracks.removeAt(at);
    if (_tracks.isEmpty) {
      _index = -1;
    } else if (_index >= _tracks.length) {
      _index = _tracks.length - 1;
    }
  }

  void clear() {
    _tracks.clear();
    _index = -1;
  }

  /// Select [at] without playing. Returns the selected track.
  MediaTrack select(int at) {
    if (at < 0 || at >= _tracks.length) {
      throw MediaQueueException('no track at index $at');
    }
    _index = at;
    return _tracks[at];
  }

  /// Move the selection forward. Returns null at the end of the queue.
  MediaTrack? advance() {
    if (_index + 1 >= _tracks.length) return null;
    _index++;
    return _tracks[_index];
  }

  /// Move the selection back. Returns null at the start of the queue.
  MediaTrack? back() {
    if (_index - 1 < 0) return null;
    _index--;
    return _tracks[_index];
  }
}

/// Player states reported by [MediaQueuePlayer.status].
enum QueuePlayerState { stopped, playing, paused }

/// Audio backend behind [MediaQueuePlayer]; the real one is audioplayers.
abstract class QueueAudioBackend {
  Future<void> playUrl(String url);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();

  /// Called once per finished track.
  void onComplete(void Function() cb);
  Future<void> dispose();
}

/// audioplayers backend for [MediaQueuePlayer].
class AudioPlayersBackend implements QueueAudioBackend {
  AudioPlayersBackend() : _player = AudioPlayer();

  final AudioPlayer _player;
  void Function()? _done;

  @override
  Future<void> playUrl(String url) => _player.play(UrlSource(url));

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  void onComplete(void Function() cb) {
    _done = cb;
    _player.onPlayerComplete.listen((_) => _done?.call());
  }

  @override
  Future<void> dispose() => _player.dispose();
}

/// Binds a [MediaQueue] to a backend: play/pause/resume/stop/next/
/// previous plus auto-advance when a track completes. Failures leave
/// the state stopped with [lastError] set; they never throw.
class MediaQueuePlayer {
  MediaQueuePlayer({MediaQueue? queue, QueueAudioBackend? backend})
    : queue = queue ?? MediaQueue(),
      _backend = backend ?? AudioPlayersBackend() {
    _backend.onComplete(_onTrackComplete);
  }

  final MediaQueue queue;
  final QueueAudioBackend _backend;

  QueuePlayerState _state = QueuePlayerState.stopped;
  String _lastError = '';

  QueuePlayerState get state => _state;
  String get lastError => _lastError;

  void _onTrackComplete() {
    final next = queue.advance();
    if (next == null) {
      _state = QueuePlayerState.stopped;
      return;
    }
    unawaited(
      _backend.playUrl(next.url).catchError((Object e) {
        _state = QueuePlayerState.stopped;
        _lastError = '$e';
      }),
    );
  }

  Future<bool> _playCurrent() async {
    final track = queue.current;
    if (track == null) {
      _lastError = 'queue is empty';
      return false;
    }
    try {
      await _backend.playUrl(track.url);
      _state = QueuePlayerState.playing;
      _lastError = '';
      return true;
    } catch (e) {
      _state = QueuePlayerState.stopped;
      _lastError = '$e';
      return false;
    }
  }

  /// Play the current track, or select [index] first when given.
  Future<bool> play([int? index]) async {
    if (index != null) {
      try {
        queue.select(index);
      } catch (e) {
        _lastError = '$e';
        return false;
      }
    }
    return _playCurrent();
  }

  Future<bool> pause() async {
    if (_state != QueuePlayerState.playing) return false;
    try {
      await _backend.pause();
      _state = QueuePlayerState.paused;
      return true;
    } catch (e) {
      _lastError = '$e';
      return false;
    }
  }

  Future<bool> resume() async {
    if (_state != QueuePlayerState.paused) return play();
    try {
      await _backend.resume();
      _state = QueuePlayerState.playing;
      return true;
    } catch (e) {
      _lastError = '$e';
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _backend.stop();
    } catch (e) {
      _lastError = '$e';
    }
    _state = QueuePlayerState.stopped;
  }

  Future<bool> next() async {
    if (queue.advance() == null) {
      await stop();
      return false;
    }
    return _playCurrent();
  }

  Future<bool> previous() async {
    if (queue.back() == null) return false;
    return _playCurrent();
  }

  Map<String, Object?> status() => {
    'state': _state.name,
    'index': queue.index,
    'queue_length': queue.length,
    'track': queue.current?.toJson(),
    if (_lastError.isNotEmpty) 'last_error': _lastError,
  };

  Future<void> dispose() => _backend.dispose();
}
