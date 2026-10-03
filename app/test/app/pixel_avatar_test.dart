import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/avatar_motion.dart';
import 'package:muse_companion/app/pixel_avatar.dart';

void main() {
  test('scale map matches muse_pixel_set_size', () {
    final full = pixelScaleMap(192);
    expect(full, hasLength(192));
    expect(full[0].cell, 0);
    expect(full[0].edge, isFalse);
    // Cell 0 lasts until screen pixel 3: 3*64/192 == 1.
    expect(full[2].cell, 0);
    expect(full[2].edge, isTrue);
    expect(full[3].cell, 1);

    expect(pixelScaleMap(100).first.edge, isFalse);
    expect(pixelScaleMap(600), hasLength(pixelScaleMax));
    expect(pixelScaleMap(0), hasLength(1));
  });

  test('accents and state words follow the firmware schemes', () {
    expect(avatarAccent(AvatarPose.idle), 0xa77dff);
    expect(avatarAccent(AvatarPose.listening), 0x5cb8ff);
    expect(avatarAccent(AvatarPose.thinking), 0xe07bff);
    expect(avatarAccent(AvatarPose.speaking), 0x6ff0bf);
    expect(avatarAccent(AvatarPose.error), 0xff5c5c);
    expect(avatarAccent(AvatarPose.boot), 0xa9c0ff);
    expect(avatarAccent(AvatarPose.off), 0x7c72d0);
    expect(avatarStateLabel(AvatarPose.idle), 'READY');
    expect(avatarStateLabel(AvatarPose.listening), 'LISTENING');
    expect(avatarStateLabel(AvatarPose.thinking), 'THINKING');
    expect(avatarStateLabel(AvatarPose.speaking), 'SPEAKING');
    expect(avatarStateLabel(AvatarPose.error), 'ERROR');
    expect(avatarStateLabel(AvatarPose.boot), 'BOOT');
    expect(avatarStateLabel(AvatarPose.off), 'OFF');
    expect(avatarCaptionRgb, 0xd8d2ff);
    expect(avatarFaceWord(AvatarPose.idle), 'READY');
    expect(avatarFaceWord(AvatarPose.idle, connecting: true), 'CONNECTING');
    expect(avatarFaceWord(AvatarPose.idle, reconnecting: true), 'RECONNECTING');
    expect(avatarFaceWord(AvatarPose.listening, connecting: true), 'LISTENING');
    expect(avatarStateLabel(AvatarPose.idle), 'READY');
  });

  test('bezel arcs match the board ring', () {
    final think = thinkingBezelArc(0);
    expect(think.start, closeTo(-math.pi / 2, 1e-9));
    expect(think.sweep, closeTo(math.pi / 3, 1e-9));
    final later = thinkingBezelArc(0.5);
    expect(later.start, closeTo(-math.pi / 2 + 150 * math.pi / 180, 1e-9));
    expect(later.sweep, think.sweep);
    // One second is 300° and stays inside a single turn.
    var travel = thinkingBezelArc(1).start - think.start;
    if (travel < 0) travel += math.pi * 2;
    expect(travel, closeTo(300 * math.pi / 180, 1e-9));
    // A full 360° of travel lands back on the top.
    final lap = thinkingBezelArc(1.2);
    var back = lap.start - (-math.pi / 2);
    back = back % (math.pi * 2);
    if (back > math.pi) back -= math.pi * 2;
    expect(back.abs(), lessThan(1e-6));

    expect(listenRingSeconds, 15);
    expect(listenRingProgress(Duration.zero), 0);
    expect(listenRingProgress(const Duration(milliseconds: -1)), 0);
    expect(
      listenRingProgress(const Duration(milliseconds: 7500)),
      closeTo(0.5, 1e-9),
    );
    expect(listenRingProgress(const Duration(seconds: 20)), 1);
    final listen = listenBezelArc(0.25);
    expect(listen.start, closeTo(-math.pi / 2, 1e-9));
    expect(listen.sweep, closeTo(math.pi / 2, 1e-9));
    expect(listenBezelArc(2).sweep, closeTo(math.pi * 2, 1e-9));
    expect(listenBezelArc(-1).sweep, 0);
  });

  test('a flat backdrop is removed and the feet stay planted', () {
    final rgba = Uint8List(pixelGrid * pixelGrid * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i + 3] = 255;
    }
    for (var y = 10; y <= 40; y++) {
      for (var x = 20; x <= 34; x++) {
        final i = (y * pixelGrid + x) * 4;
        rgba[i] = 240;
        rgba[i + 1] = 220;
        rgba[i + 2] = 40;
        rgba[i + 3] = 255;
      }
    }
    final keyed = keyCharacter(rgba);
    expect(keyed.frame.keyed, isTrue);
    expect(keyed.frame.left, 20);
    expect(keyed.frame.top, 10);
    expect(keyed.frame.right, 34);
    expect(keyed.frame.bottom, 40);
    expect(keyed.frame.backdrop, 0xFF000000);
    expect(keyed.rgba[0], 0);
    expect(keyed.rgba[3], 0);
    expect(keyed.rgba[(10 * pixelGrid + 20) * 4 + 3], 255);
    expect(keyed.frame.lift(10), 1);
    expect(keyed.frame.lift(40), 0);
    expect(keyed.frame.lift(25), closeTo(0.5, 1e-9));

    final feet = bodyRowShift(
      lift: 0,
      bob: 1,
      lean: 2,
      hop: 3,
      gazeX: 0.5,
      gazeY: 0.5,
    );
    expect(feet.dy, closeTo(-0.9, 1e-9));
    expect(feet.dx, closeTo(0.9, 1e-9));
    final head = bodyRowShift(
      lift: 1,
      bob: 1,
      lean: 2,
      hop: 3,
      gazeX: 0.5,
      gazeY: 0.5,
    );
    expect(head.dy, closeTo(1 - 3 + 0.5, 1e-9));
    expect(head.dx, closeTo(2 + 0.5, 1e-9));

    final busy = Uint8List(pixelGrid * pixelGrid * 4);
    for (var i = 0; i < busy.length; i += 4) {
      busy[i] = i % 255;
      busy[i + 1] = 80;
      busy[i + 2] = 10;
      busy[i + 3] = 255;
    }
    final photo = keyCharacter(busy);
    expect(photo.frame.keyed, isFalse);
    expect(photo.frame.bottom, pixelGrid - 1);
    expect(photo.frame.backdrop, 0);
    expect(identical(photo.rgba, busy), isTrue);

    final place = placePortrait(keyed.frame);
    expect(place.scale, closeTo(56 / 31, 1e-9));
    expect(place.ground, closeTo(60, 1e-9));
    expect(place.left, closeTo((64 - 15 * place.scale) / 2, 1e-9));
    final fullPlace = placePortrait(const CharacterFrame.full());
    expect(fullPlace.scale, 1);
    expect(fullPlace.left, 0);
    expect(fullPlace.ground, pixelGrid.toDouble());
  });

  test('a white shirt stays and a full-height body clears the ring', () {
    final rgba = Uint8List(pixelGrid * pixelGrid * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 250;
      rgba[i + 1] = 250;
      rgba[i + 2] = 250;
      rgba[i + 3] = 255;
    }
    for (var y = 10; y <= 40; y++) {
      for (var x = 20; x <= 34; x++) {
        final edge = x == 20 || x == 34 || y == 10 || y == 40;
        if (!edge) continue;
        final i = (y * pixelGrid + x) * 4;
        rgba[i] = 10;
        rgba[i + 1] = 10;
        rgba[i + 2] = 10;
      }
    }
    final keyed = keyCharacter(rgba);
    expect(keyed.frame.keyed, isTrue);
    expect(keyed.frame.backdrop, 0xFFFAFAFA);
    final shirt = (25 * pixelGrid + 27) * 4;
    expect(keyed.rgba[shirt], 250);
    expect(keyed.rgba[shirt + 3], 255);
    expect(keyed.rgba[0], 0);
    expect(keyed.rgba[3], 0);

    final tall = CharacterFrame(
      left: 17,
      top: 0,
      right: 46,
      bottom: 63,
      keyed: true,
      backdrop: 0xFFF4F4F4,
    );
    final place = placePortrait(tall);
    expect(place.scale, closeTo(56 / 64, 1e-9));
    expect(place.ground, closeTo(60, 1e-9));
    expect(place.ground - 64 * place.scale, closeTo(4, 1e-9));
  });

  test('cover crop keeps the centre of a wide image', () {
    final wide = Uint8List(4 * 2 * 4);
    for (var y = 0; y < 2; y++) {
      for (var x = 0; x < 4; x++) {
        final i = (y * 4 + x) * 4;
        wide[i] = (x == 1 || x == 2) ? 9 : 1;
        wide[i + 3] = 255;
      }
    }
    final grid = coverCropGrid(wide, 4, 2);
    expect(grid[0], 9);
    expect(grid[(pixelGrid - 1) * 4], 9);
    expect(grid.length, pixelGrid * pixelGrid * 4);
  });

  test('thought dots step and the meter lights from the centre', () {
    final first = thoughtDots(0);
    expect(first, hasLength(3));
    expect(first[0].active, isTrue);
    expect(first[1].dx, 4);
    expect(first[1].dy, -3);
    expect(thoughtDots(0.5 / 1.6)[1].active, isTrue);

    expect(meterSegmentOn(6, 0), isFalse);
    expect(meterSegmentOn(0, 0), isFalse);
    expect(meterSegmentOn(6, 0.1), isTrue);
    expect(meterSegmentOn(0, 0.1), isFalse);
    expect(meterSegmentOn(0, 1), isTrue);
  });

  test('blink clock shuts the eyes for part of a 0.16 s blink', () {
    final clock = BlinkClock();
    var peak = 0.0;
    for (var i = 0; i < 200; i++) {
      final shut = clock.advance(0.01);
      if (shut > peak) peak = shut;
    }
    expect(clock.seconds, closeTo(2.0, 1e-9));
    expect(peak, greaterThan(0.9));
  });

  test('blinks land every 2.2–5.2 s, with a 0.28 s double blink', () {
    final clock = BlinkClock();
    final starts = <double>[];
    var prev = 0.0;
    for (var i = 0; i < 30000; i++) {
      final shut = clock.advance(0.01);
      if (shut > 0 && prev == 0) starts.add(clock.seconds);
      prev = shut;
    }
    expect(starts.first, closeTo(1.51, 0.02));
    var doubles = 0;
    for (var i = 1; i < starts.length; i++) {
      final gap = starts[i] - starts[i - 1];
      if (gap < 0.5) {
        doubles++;
        expect(gap, closeTo(0.28, 0.02));
      } else {
        expect(gap, greaterThanOrEqualTo(2.2 - 1e-6));
        expect(gap, lessThanOrEqualTo(5.2 + 1e-6));
      }
    }
    expect(doubles, greaterThan(0));
  });
}
