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

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/lmstudio_tools.dart';
import 'package:muse_companion/app/media_queue.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

class _FakePhone implements PhoneActions {
  @override
  Future<Uint8List> captureJpeg({String facing = 'back'}) async =>
      Uint8List(0);

  @override
  Future<Uint8List> recordWav(int seconds) async => Uint8List(0);

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stopSpeak() async {}

  @override
  Future<void> openNotificationAccess() async {}

  @override
  Future<Map<String, Object?>> run(
    String command,
    Map<String, Object?> params,
  ) async => {};
}

class _FakeBackend implements QueueAudioBackend {
  final List<String> played = [];
  void Function()? done;
  bool paused = false;

  @override
  Future<void> playUrl(String url) async {
    played.add(url);
  }

  @override
  Future<void> pause() async {
    paused = true;
  }

  @override
  Future<void> resume() async {
    paused = false;
  }

  @override
  Future<void> stop() async {}

  @override
  void onComplete(void Function() cb) {
    done = cb;
  }

  @override
  Future<void> dispose() async {}

  void finishTrack() => done?.call();
}

MediaTrack track(String name) =>
    MediaTrack(url: 'https://example.com/$name.mp3', title: name);

void main() {
  test('queue rejects non-http urls and caps length', () {
    final queue = MediaQueue();
    expect(
      () => queue.add(const MediaTrack(url: 'ftp://x/y.mp3')),
      throwsA(isA<MediaQueueException>()),
    );
    for (var i = 0; i < MediaQueue.maxTracks; i++) {
      queue.add(track('t$i'));
    }
    expect(() => queue.add(track('overflow')), throwsA(isA<MediaQueueException>()));
  });

  test('remove follows the music and select bounds-checks', () {
    final queue = MediaQueue()
      ..add(track('a'))
      ..add(track('b'))
      ..add(track('c'));
    queue.select(1);
    queue.removeAt(1);
    expect(queue.current?.title, 'c');
    expect(() => queue.select(9), throwsA(isA<MediaQueueException>()));
    expect(() => queue.removeAt(9), throwsA(isA<MediaQueueException>()));
  });

  test('player plays, pauses, advances and auto-continues', () async {
    final backend = _FakeBackend();
    final player = MediaQueuePlayer(backend: backend);
    player.queue
      ..add(track('one'))
      ..add(track('two'));

    expect(await player.play(), isTrue);
    expect(player.state, QueuePlayerState.playing);
    expect(backend.played, ['https://example.com/one.mp3']);

    expect(await player.pause(), isTrue);
    expect(player.state, QueuePlayerState.paused);
    expect(await player.resume(), isTrue);

    backend.finishTrack();
    await Future<void>.delayed(Duration.zero);
    expect(player.queue.current?.title, 'two');
    expect(backend.played.last, 'https://example.com/two.mp3');

    expect(await player.next(), isFalse);
    expect(player.state, QueuePlayerState.stopped);
    await player.dispose();
  });

  test('play with no tracks fails cleanly', () async {
    final player = MediaQueuePlayer(backend: _FakeBackend());
    expect(await player.play(), isFalse);
    expect(player.lastError, isNotEmpty);
    expect(player.status()['state'], 'stopped');
    await player.dispose();
  });

  group('media local tools', () {
    late MediaQueuePlayer player;
    late LmToolContext ctx;

    setUp(() {
      player = MediaQueuePlayer(backend: _FakeBackend());
      ctx = LmToolContext(
        phone: _FakePhone(),
        cameraFacing: 'back',
        mediaQueue: player,
      );
    });

    tearDown(() => player.dispose());

    test('enqueue, queue, play and control via tools', () async {
      var out = await lmToolNamed('media_enqueue')!.handler({
        'url': 'https://example.com/a.mp3',
        'title': 'A',
      }, ctx);
      expect(out, contains('Queued (1 tracks)'));

      out = await lmToolNamed('media_queue')!.handler({}, ctx);
      expect(out, contains('> 0: A'));

      out = await lmToolNamed('media_play')!.handler({}, ctx);
      expect(out, contains('Playing (playing)'));

      out = await lmToolNamed('media_control')!.handler(
        {'action': 'pause'},
        ctx,
      );
      expect(out, 'Paused.');

      out = await lmToolNamed('media_control')!.handler(
        {'action': 'dance'},
        ctx,
      );
      expect(out, startsWith('error:'));
    });

    test('enqueue rejects bad urls', () async {
      final out = await lmToolNamed('media_enqueue')!.handler({
        'url': 'ftp://x/y.mp3',
      }, ctx);
      expect(out, startsWith('error:'));
    });
  });
}
