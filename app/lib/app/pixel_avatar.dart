// Motion and sampling for the companion's pixel avatar.
//
// The Waveshare screen draws Muse on a 64x64 grid (esp32/avatar/muse_pixel.c
// and esp32/components/muse/muse_ui.c): nearest-neighbour scale with a faint
// cell edge, a per-mode accent, a blink clock, dotted rings, thought dots,
// and a centred listening meter. This file ports those numbers.
//
// It does not draw the firmware's default character. That art is Meta's,
// and the gadget recipe says the Apache license does not grant it. The
// phone pixelates the picture Muse sends of itself. Until that picture
// arrives, the screen shows an original round face, not the stock hood.

import 'dart:math' as math;
import 'dart:typed_data';

import 'avatar_life.dart';
import 'avatar_motion.dart';

/// Grid the firmware renders into.
const int pixelGrid = 64;

/// `muse_pixel_set_size` refuses anything past this.
const int pixelScaleMax = 512;

/// Listening meter segment count (`METER_SEGS` in muse_ui.c).
const int meterSegments = 14;

/// One screen pixel's source cell. [edge] is the dim grid line: set when
/// the next screen pixel belongs to another cell and the stage is at least
/// three screen pixels per cell.
class PixelSample {
  const PixelSample(this.cell, this.edge);

  final int cell;
  final bool edge;
}

/// Screen-pixel to grid-cell map, matching `muse_pixel_set_size`.
List<PixelSample> pixelScaleMap(int size) {
  var n = size;
  if (n < 1) n = 1;
  if (n > pixelScaleMax) n = pixelScaleMax;
  final grid = n >= 3 * pixelGrid;
  return [
    for (var i = 0; i < n; i++)
      PixelSample(
        i * pixelGrid ~/ n,
        grid && (i + 1) * pixelGrid ~/ n != i * pixelGrid ~/ n,
      ),
  ];
}

/// Accent `0xRRGGBB` for the ring, meter, and state word.
///
/// Same per-mode colours as `SCHEMES` in muse_pixel.c.
int avatarAccent(AvatarPose pose) => avatarScheme(pose).accent;

/// Word drawn above the avatar. Idle is "READY", as on the board.
String avatarStateLabel(AvatarPose pose) {
  switch (pose) {
    case AvatarPose.listening:
      return 'LISTENING';
    case AvatarPose.thinking:
      return 'THINKING';
    case AvatarPose.speaking:
      return 'SPEAKING';
    case AvatarPose.error:
      return 'ERROR';
    case AvatarPose.boot:
      return 'BOOT';
    case AvatarPose.off:
      return 'OFF';
    case AvatarPose.idle:
      return 'READY';
  }
}

/// Face word above the portrait.
///
/// Idle follows the Muse link the way `idle_name` in muse_ui.c follows
/// Wi-Fi: connecting, reconnecting, or READY. Other poses keep
/// [avatarStateLabel]. That helper still returns READY for a plain idle
/// pose, which the tests lock.
String avatarFaceWord(
  AvatarPose pose, {
  bool connecting = false,
  bool reconnecting = false,
}) {
  if (pose == AvatarPose.idle) {
    if (connecting) return 'CONNECTING';
    if (reconnecting) return 'RECONNECTING';
  }
  return avatarStateLabel(pose);
}

/// Board push-to-talk cap (`MAX_SECS` in muse_voice.c). The bezel fills
/// across this span. The phone may keep the microphone slightly longer.
const double listenRingSeconds = 15;

/// Hold progress in 0..1 for the listen arc.
double listenRingProgress(Duration elapsed) {
  final seconds = elapsed.inMicroseconds / 1000000.0;
  if (seconds <= 0) return 0;
  final progress = seconds / listenRingSeconds;
  if (progress >= 1) return 1;
  return progress;
}

/// One stroke on the fixed stage bezel. [start] is a Flutter canvas angle
/// (0 at the right, clockwise). The board's arc widget is rotated 270°,
/// so its zero sits at the top, which is `-pi/2` here.
class BezelArc {
  const BezelArc(this.start, this.sweep);

  final double start;
  final double sweep;
}

/// Thinking indicator: 60° (`RING_RANGE / 6`) traveling at 300°/s.
BezelArc thinkingBezelArc(double seconds) {
  const cycle = math.pi * 2;
  var travel = (seconds * 300 * math.pi / 180) % cycle;
  if (travel < 0) travel += cycle;
  return BezelArc(-math.pi / 2 + travel, math.pi / 3);
}

/// Listen arc. A full hold is one turn starting at the top.
BezelArc listenBezelArc(double progress) {
  var p = progress;
  if (p < 0) p = 0;
  if (p > 1) p = 1;
  return BezelArc(-math.pi / 2, p * math.pi * 2);
}

/// Caption colour from muse_ui.c (`COLOR_CAPTION`).
const int avatarCaptionRgb = 0xd8d2ff;

/// Cover-crop packed RGBA (4 bytes per pixel) into a [pixelGrid] square.
///
/// The subject stays centred. A smaller source is sampled, not stretched
/// sideways. The result is RGBA, length `pixelGrid * pixelGrid * 4`.
Uint8List coverCropGrid(Uint8List rgba, int width, int height) {
  final out = Uint8List(pixelGrid * pixelGrid * 4);
  if (width <= 0 || height <= 0 || rgba.length < 4) return out;
  final side = width < height ? width : height;
  final x0 = (width - side) ~/ 2;
  final y0 = (height - side) ~/ 2;
  for (var y = 0; y < pixelGrid; y++) {
    final sy = y0 + y * side ~/ pixelGrid;
    if (sy < 0 || sy >= height) continue;
    for (var x = 0; x < pixelGrid; x++) {
      final sx = x0 + x * side ~/ pixelGrid;
      if (sx < 0 || sx >= width) continue;
      final src = (sy * width + sx) * 4;
      if (src + 3 >= rgba.length) continue;
      final dst = (y * pixelGrid + x) * 4;
      out[dst] = rgba[src];
      out[dst + 1] = rgba[src + 1];
      out[dst + 2] = rgba[src + 2];
      out[dst + 3] = rgba[src + 3];
    }
  }
  return out;
}

/// One thought dot, in cells relative to the cluster's origin.
class ThoughtDot {
  const ThoughtDot(this.dx, this.dy, this.active);

  final int dx;
  final int dy;
  final bool active;
}

/// Three dots stepping up beside the head. Matches `draw_thought_dots`.
List<ThoughtDot> thoughtDots(double seconds) {
  final scaled = seconds * 1.6;
  final frac = scaled - scaled.floor();
  var active = (frac * 3).floor();
  if (active > 2) active = 2;
  if (active < 0) active = 0;
  return [
    for (var i = 0; i < 3; i++)
      ThoughtDot(i * 4, -i * 3 - (i == active ? 1 : 0), i == active),
  ];
}

/// Whether listening-meter segment [index] is lit at [level] (0–1).
///
/// Outer segments light last, matching the centred VU in muse_ui.c.
bool meterSegmentOn(int index, double level) {
  final clamped = level < 0 ? 0.0 : (level > 1 ? 1.0 : level);
  final lit = (clamped * meterSegments).round();
  final rank = (2 * index - (meterSegments - 1)).abs() ~/ 2;
  return rank < (lit + 1) ~/ 2;
}

/// Blink clock from `eyes_update`: shut amount is 0 when open and 1 at the
/// middle of a 0.16 s blink. Blinks start at 1.5 s, then every 2.2–5.2 s,
/// with a short gap when the draw rolls a double blink.
class BlinkClock {
  double _nextBlink = 1.5;
  double _blinkStart = -10;
  double _t = 0;
  int _rng = 0x9e3779b9;

  double get seconds => _t;

  double _frand() {
    var x = _rng & 0xFFFFFFFF;
    x = (x ^ ((x << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    x = (x ^ (x >> 17)) & 0xFFFFFFFF;
    x = (x ^ ((x << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    _rng = x;
    return (x & 0xffffff) / 0x1000000;
  }

  /// Advance by [dt] seconds (clamped to 0..0.2, as a frame's dt is) and
  /// return how shut the eyes are.
  double advance(double dt) {
    if (dt < 0) dt = 0;
    if (dt > 0.2) dt = 0.2;
    _t += dt;
    if (_t >= _nextBlink) {
      _blinkStart = _t;
      _nextBlink = _t + (_frand() < 0.2 ? 0.28 : 2.2 + _frand() * 3.0);
    }
    final bt = (_t - _blinkStart) / 0.16;
    if (bt < 0 || bt > 1) return 0;
    return 1 - (bt * 2 - 1).abs();
  }
}
