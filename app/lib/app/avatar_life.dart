// Life on top of the portrait motion in avatar_motion.dart.
//
// The timing comes from muse_pixel.c: breathing, blinks, wandering gaze,
// sparkles, sound-wave arcs, per-mode colour schemes, and the boot, error,
// off, and happy beats. The phone does not draw Meta's default character.
// These values move the picture Muse sent, or a plain round placeholder.

import 'dart:math' as math;

import 'avatar_motion.dart';

/// One mode's glow ramp (bright to deep) and accent, as `0xRRGGBB`.
class AvatarScheme {
  const AvatarScheme(this.f0, this.f1, this.f2, this.f3, this.accent);

  final int f0;
  final int f1;
  final int f2;
  final int f3;
  final int accent;

  @override
  bool operator ==(Object other) =>
      other is AvatarScheme &&
      other.f0 == f0 &&
      other.f1 == f1 &&
      other.f2 == f2 &&
      other.f3 == f3 &&
      other.accent == accent;

  @override
  int get hashCode => Object.hash(f0, f1, f2, f3, accent);
}

/// `SCHEMES` from muse_pixel.c. Idle's accent matches [avatarAccent].
AvatarScheme avatarScheme(AvatarPose pose) {
  switch (pose) {
    case AvatarPose.boot:
      return const AvatarScheme(
        0xffffff,
        0xcfe0ff,
        0x8fa8ff,
        0x5a5fe0,
        0xa9c0ff,
      );
    case AvatarPose.listening:
      return const AvatarScheme(
        0xe8faff,
        0x8fdcff,
        0x3fa2ff,
        0x2a5bd7,
        0x5cb8ff,
      );
    case AvatarPose.thinking:
      return const AvatarScheme(
        0xffe6ff,
        0xff9cf0,
        0xd35bff,
        0x7a2bd9,
        0xe07bff,
      );
    case AvatarPose.speaking:
      return const AvatarScheme(
        0xeafff4,
        0x9ff5cf,
        0x3fd9a0,
        0x1f9a7a,
        0x6ff0bf,
      );
    case AvatarPose.error:
      return const AvatarScheme(
        0xffd6d6,
        0xff6b6b,
        0xc7304a,
        0x6b1a3a,
        0xff5c5c,
      );
    case AvatarPose.off:
      return const AvatarScheme(
        0xd8d4ff,
        0x8f86d9,
        0x5a4fb0,
        0x2e2870,
        0x7c72d0,
      );
    case AvatarPose.idle:
      return const AvatarScheme(
        0xf4e8ff,
        0xc7a4ff,
        0x9a6bff,
        0x5b3fd9,
        0xa77dff,
      );
  }
}

/// `1 - exp(-dt * rate)`. Gaze uses 14, the palette uses 7.
double expEase(double dt, double rate) {
  if (dt <= 0) return 0;
  return 1 - math.exp(-dt * rate);
}

class Rgb {
  const Rgb(this.r, this.g, this.b);

  final double r;
  final double g;
  final double b;

  factory Rgb.hex(int hex) {
    return Rgb(
      ((hex >> 16) & 255) / 255,
      ((hex >> 8) & 255) / 255,
      (hex & 255) / 255,
    );
  }

  Rgb mix(Rgb toward, double k) {
    return Rgb(
      r + (toward.r - r) * k,
      g + (toward.g - g) * k,
      b + (toward.b - b) * k,
    );
  }

  int get hex {
    int ch(double v) => (v * 255).round().clamp(0, 255);
    return (ch(r) << 16) | (ch(g) << 8) | ch(b);
  }
}

/// Exponential blend toward the mode scheme, `1 - exp(-dt * 7)` per frame.
class PaletteClock {
  PaletteClock([AvatarPose pose = AvatarPose.idle]) {
    final scheme = avatarScheme(pose);
    f0 = Rgb.hex(scheme.f0);
    f1 = Rgb.hex(scheme.f1);
    f2 = Rgb.hex(scheme.f2);
    f3 = Rgb.hex(scheme.f3);
    accent = Rgb.hex(scheme.accent);
  }

  late Rgb f0;
  late Rgb f1;
  late Rgb f2;
  late Rgb f3;
  late Rgb accent;

  void step(double dt, AvatarPose pose) {
    final k = expEase(dt, 7);
    if (k == 0) return;
    final scheme = avatarScheme(pose);
    f0 = f0.mix(Rgb.hex(scheme.f0), k);
    f1 = f1.mix(Rgb.hex(scheme.f1), k);
    f2 = f2.mix(Rgb.hex(scheme.f2), k);
    f3 = f3.mix(Rgb.hex(scheme.f3), k);
    accent = accent.mix(Rgb.hex(scheme.accent), k);
  }
}

/// Gaze wanders every 1.2–3.6 s and eases with rate 14.
///
/// Listening locks forward. Thinking looks up and side to side. The result
/// is -1..1; eye centres add `±0.8` px in x and `±0.7` px in y.
class GazeClock {
  double x = 0;
  double y = 0;
  double _tx = 0;
  double _ty = 0;
  double _next = 0.6;
  double _t = 0;
  bool _locked = false;
  int _rng = 0xA5A5F00D;

  double _frand() {
    var n = _rng & 0xFFFFFFFF;
    n = (n ^ ((n << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    n = (n ^ (n >> 17)) & 0xFFFFFFFF;
    n = (n ^ ((n << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    _rng = n;
    return (n & 0xffffff) / 0x1000000;
  }

  void step(double dt, {required AvatarPose pose, required double modeT}) {
    if (dt < 0) dt = 0;
    if (dt > 0.2) dt = 0.2;
    _t += dt;
    final locked =
        pose == AvatarPose.listening ||
        pose == AvatarPose.thinking ||
        pose == AvatarPose.error ||
        pose == AvatarPose.off ||
        pose == AvatarPose.boot;
    if (pose == AvatarPose.listening) {
      _tx = 0;
      _ty = 0.1;
    } else if (pose == AvatarPose.thinking) {
      _tx = 0.75 * math.sin(modeT * 1.3) + 0.25;
      _ty = -0.85;
    } else if (pose == AvatarPose.error ||
        pose == AvatarPose.off ||
        pose == AvatarPose.boot) {
      _tx = 0;
      _ty = 0;
    } else if (_locked || _t >= _next) {
      if (_frand() < 0.35) {
        _tx = 0;
        _ty = 0;
      } else {
        _tx = _frand() * 2 - 1;
        _ty = _frand() * 2 - 1;
      }
      _next = _t + 1.2 + _frand() * 2.4;
    }
    _locked = locked;
    final k = expEase(dt, 14);
    x += (_tx - x) * k;
    y += (_ty - y) * k;
  }
}

/// `sin(t * 2 + 1) * 0.03`. Width and height both use it.
double breatheScale(double seconds) => math.sin(seconds * 2.0 + 1.0) * 0.03;

double bootPop(double modeT) => (modeT / 0.6).clamp(0.0, 1.0);

/// Squash at the start of boot, settling to 1 at 0.6 s.
double bootSquash(double modeT) {
  final pop = bootPop(modeT);
  return 1 - (1 - pop) * 0.35 + math.sin(pop * math.pi) * 0.06;
}

double bootAmount(double modeT) => (modeT / 1.4).clamp(0.0, 1.0);

/// Eyes stay shut until 0.9 s, then open over 0.3 s.
double bootEyeOpen(double modeT) {
  if (modeT <= 0.9) return 0;
  return ((modeT - 0.9) / 0.3).clamp(0.0, 1.0);
}

double offFade(double modeT) => (1 - modeT / 1.3).clamp(0.0, 1.0);

double offEyeOpen(double modeT) => ((1 - modeT / 1.0) * 1.5).clamp(0.0, 1.0);

/// Shake for the first 0.6 s of error, then hold still.
double errorLean(double seconds, double modeT) {
  if (modeT >= 0.6) return 0;
  return math.sin(seconds * 18) * 1.0;
}

double happyHop(double seconds, double happy) =>
    math.sin(seconds * 9).abs() * 3.0 * happy;

/// Speaking mouth. The flutter term keeps it from freezing when [level] is flat.
double talkOpen(double seconds, double level) =>
    level * 1.3 + 0.1 * (0.5 + 0.5 * math.sin(seconds * 22));

int mouthHeight(double open) {
  final clamped = open.clamp(0.0, 1.0);
  return 1 + (clamped * 3).round();
}

int soundWaveCount(double level) {
  final n = (1 + level.clamp(0.0, 1.0) * 3.2).floor();
  if (n < 1) return 1;
  if (n > 3) return 3;
  return n;
}

double waveFlicker(double seconds, int index) =>
    0.5 + 0.5 * math.sin(seconds * 12 - index * 1.4);

/// Stand-in level when the phone has no amplitude tap. Listening and
/// speaking pulse; every other pose is silent.
double avatarLevel(AvatarPose pose, double seconds) {
  if (pose != AvatarPose.listening && pose != AvatarPose.speaking) return 0;
  return (0.35 + 0.4 * math.sin(seconds * 6)).clamp(0.0, 1.0);
}

double sparkleSpeed(AvatarPose pose, double boot) {
  switch (pose) {
    case AvatarPose.boot:
      return boot.clamp(0.0, 1.0) * 6;
    case AvatarPose.thinking:
      return 2.8;
    case AvatarPose.listening:
      return 1.2;
    case AvatarPose.speaking:
      return 1.5;
    case AvatarPose.error:
    case AvatarPose.off:
    case AvatarPose.idle:
      return 0.6;
  }
}

class Sparkle {
  const Sparkle(this.x, this.y, this.twinkle, this.behind);

  /// Cells from the portrait centre.
  final double x;
  final double y;
  final double twinkle;

  /// Even sparks sit behind the portrait, odd ones in front.
  final bool behind;
}

List<Sparkle> sparkles(double seconds, AvatarPose pose, double boot) {
  final shown = pose == AvatarPose.boot
      ? (boot.clamp(0.0, 1.0) * 6).floor()
      : 6;
  if (shown <= 0) return const [];
  final speed = sparkleSpeed(pose, boot);
  return [
    for (var i = 0; i < shown; i++)
      Sparkle(
        math.cos(seconds * speed + i * 1.047) * (18 + (i % 3) * 4),
        math.sin(seconds * speed * 0.8 + i * 1.047) * (14 + (i % 2) * 3),
        0.5 + 0.5 * math.sin(seconds * 5 + i * 1.7),
        i.isEven,
      ),
  ];
}

enum FaceEye { bead, wide, glance, shut, cross, happy }

enum FaceMouth { smile, oh, hmm, talk, flat, grin }

enum ArmCue { rest, cup, chin, talk, wave, up }

/// One frame of life around the portrait. Lengths are pixel-units on the
/// 64-wide grid. Eye and mouth names describe the placeholder only.
class AvatarLife {
  const AvatarLife({
    required this.breathe,
    required this.hop,
    required this.squash,
    required this.fade,
    required this.eyeOpen,
    required this.eye,
    required this.mouth,
    required this.talk,
    required this.waves,
    required this.blush,
    required this.overrideLean,
    required this.lean,
    required this.step,
    required this.sway,
    required this.arm,
    required this.armAngle,
    required this.hearts,
    required this.alert,
    required this.aura,
    required this.boot,
    required this.gazeX,
    required this.gazeY,
  });

  final double breathe;
  final double hop;
  final double squash;
  final double fade;
  final double eyeOpen;
  final FaceEye eye;
  final FaceMouth mouth;
  final double talk;
  final int waves;
  final double blush;
  final bool overrideLean;
  final double lean;
  final double step;
  final double sway;
  final ArmCue arm;
  final double armAngle;
  final bool hearts;
  final bool alert;
  final double aura;
  final double boot;

  /// Pixel offset added to an eye centre. Already scaled from -1..1 gaze.
  final double gazeX;
  final double gazeY;
}

AvatarLife avatarLife({
  required AvatarPose pose,
  required double seconds,
  required double modeT,
  required double level,
  required double happy,
  required double blinkShut,
  required double gazeX,
  required double gazeY,
}) {
  final mood = pose == AvatarPose.error ? 0.0 : happy.clamp(0.0, 1.0);
  final fade = pose == AvatarPose.off ? offFade(modeT) : 1.0;
  final boot = pose == AvatarPose.boot ? bootAmount(modeT) : 1.0;
  var open = switch (pose) {
    AvatarPose.boot => bootEyeOpen(modeT),
    AvatarPose.off => offEyeOpen(modeT),
    AvatarPose.thinking => 0.85,
    _ => 1.0,
  };
  final shut = blinkShut.clamp(0.0, 1.0);
  if (pose != AvatarPose.error) open *= 1 - shut;

  final FaceEye eye;
  if (pose == AvatarPose.error) {
    eye = FaceEye.cross;
  } else if (open < 0.25) {
    eye = FaceEye.shut;
  } else if (mood > 0.2) {
    eye = FaceEye.happy;
  } else if (pose == AvatarPose.listening) {
    eye = FaceEye.wide;
  } else if (pose == AvatarPose.thinking) {
    eye = FaceEye.glance;
  } else {
    eye = FaceEye.bead;
  }

  final FaceMouth mouth;
  if (pose == AvatarPose.error) {
    mouth = FaceMouth.flat;
  } else if (mood > 0.2) {
    mouth = FaceMouth.grin;
  } else {
    mouth = switch (pose) {
      AvatarPose.listening => FaceMouth.oh,
      AvatarPose.thinking => FaceMouth.hmm,
      AvatarPose.speaking => FaceMouth.talk,
      _ => FaceMouth.smile,
    };
  }

  final ArmCue arm;
  var armAngle = 0.0;
  if (mood > 0.2) {
    arm = ArmCue.up;
    armAngle = math.sin(seconds * 14) * 0.25;
  } else if (pose == AvatarPose.listening) {
    arm = ArmCue.cup;
  } else if (pose == AvatarPose.thinking) {
    arm = ArmCue.chin;
  } else if (pose == AvatarPose.speaking) {
    arm = ArmCue.talk;
    armAngle = math.sin(seconds * 7) * (0.25 + level * 0.45);
  } else if (pose == AvatarPose.off) {
    arm = ArmCue.wave;
    armAngle = math.sin(seconds * 12) * 0.35 * fade;
  } else {
    arm = ArmCue.rest;
    armAngle = math.sin(seconds * 1.8 + 0.6) * 0.08;
  }

  var blush = 0.55;
  if (pose == AvatarPose.speaking) {
    blush = 0.55 + mood * 0.45 + 0.15;
  } else if (mood > 0) {
    blush = 0.55 + mood * 0.45;
  }

  final auraBoot = pose == AvatarPose.boot ? boot : 0.0;
  return AvatarLife(
    breathe: breatheScale(seconds),
    hop: happyHop(seconds, mood),
    squash: pose == AvatarPose.boot ? bootSquash(modeT) : 1,
    fade: fade,
    eyeOpen: open.clamp(0.0, 1.0),
    eye: eye,
    mouth: mouth,
    talk: talkOpen(seconds, level),
    waves: (pose == AvatarPose.listening || pose == AvatarPose.speaking)
        ? soundWaveCount(level)
        : 0,
    blush: blush.clamp(0.0, 1.0),
    overrideLean: pose == AvatarPose.error,
    lean: errorLean(seconds, modeT),
    step: pose == AvatarPose.speaking ? math.sin(seconds * 5) * 0.6 : 0,
    sway: pose == AvatarPose.idle ? math.sin(seconds * 1.8 + 0.6) * 0.08 : 0,
    arm: arm,
    armAngle: armAngle,
    hearts: mood > 0.02,
    alert: pose == AvatarPose.error,
    aura: (0.75 * auraBoot + level * 0.4) * fade,
    boot: boot,
    gazeX: gazeX * 0.8,
    gazeY: gazeY * 0.7,
  );
}

/// Two hearts. [phase] is 0 at the chest and 1 after rising 10 px.
/// A heart is visible only while `phase < happy`.
double heartPhase(double seconds, int index) =>
    (seconds * 0.9 + index * 0.5) % 1.0;
