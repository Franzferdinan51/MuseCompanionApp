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
    expect(avatarStateLabel(AvatarPose.idle), 'READY');
    expect(avatarStateLabel(AvatarPose.listening), 'LISTENING');
    expect(avatarStateLabel(AvatarPose.thinking), 'THINKING');
    expect(avatarStateLabel(AvatarPose.speaking), 'SPEAKING');
    expect(avatarCaptionRgb, 0xd8d2ff);
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
}
