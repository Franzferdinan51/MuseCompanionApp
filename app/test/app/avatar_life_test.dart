import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/avatar_life.dart';
import 'package:muse_companion/app/avatar_motion.dart';

void main() {
  test('schemes match muse_pixel.c', () {
    expect(
      avatarScheme(AvatarPose.boot),
      scheme(0xffffff, 0xcfe0ff, 0x8fa8ff, 0x5a5fe0, 0xa9c0ff),
    );
    expect(
      avatarScheme(AvatarPose.idle),
      scheme(0xf4e8ff, 0xc7a4ff, 0x9a6bff, 0x5b3fd9, 0xa77dff),
    );
    expect(
      avatarScheme(AvatarPose.listening),
      scheme(0xe8faff, 0x8fdcff, 0x3fa2ff, 0x2a5bd7, 0x5cb8ff),
    );
    expect(
      avatarScheme(AvatarPose.thinking),
      scheme(0xffe6ff, 0xff9cf0, 0xd35bff, 0x7a2bd9, 0xe07bff),
    );
    expect(
      avatarScheme(AvatarPose.speaking),
      scheme(0xeafff4, 0x9ff5cf, 0x3fd9a0, 0x1f9a7a, 0x6ff0bf),
    );
    expect(
      avatarScheme(AvatarPose.error),
      scheme(0xffd6d6, 0xff6b6b, 0xc7304a, 0x6b1a3a, 0xff5c5c),
    );
    expect(
      avatarScheme(AvatarPose.off),
      scheme(0xd8d4ff, 0x8f86d9, 0x5a4fb0, 0x2e2870, 0x7c72d0),
    );
  });

  test('palette eases with 1 - exp(-dt * 7) and ignores a zero step', () {
    final clock = PaletteClock();
    expect(clock.accent.hex, 0xa77dff);
    clock.step(0, AvatarPose.listening);
    expect(clock.accent.hex, 0xa77dff);
    const dt = 0.1;
    clock.step(dt, AvatarPose.listening);
    final k = 1 - math.exp(-dt * 7);
    expect(k, expEase(dt, 7));
    expect(clock.accent.hex, Rgb.hex(0xa77dff).mix(Rgb.hex(0x5cb8ff), k).hex);
    expect(clock.f0.hex, Rgb.hex(0xf4e8ff).mix(Rgb.hex(0xe8faff), k).hex);
  });

  test('listening gaze eases toward a forward lock', () {
    final gaze = GazeClock();
    const dt = 0.05;
    gaze.step(dt, pose: AvatarPose.listening, modeT: 0);
    final k = 1 - math.exp(-dt * 14);
    expect(gaze.x, closeTo(0, 1e-9));
    expect(gaze.y, closeTo(0.1 * k, 1e-9));
  });

  test('thinking gaze looks up and to the side', () {
    final gaze = GazeClock();
    gaze.step(1, pose: AvatarPose.thinking, modeT: 0);
    // dt clamps to 0.2, so one step only covers part of the way.
    final k = 1 - math.exp(-0.2 * 14);
    expect(gaze.x, closeTo(0.25 * k, 1e-9));
    expect(gaze.y, closeTo(-0.85 * k, 1e-9));
  });

  test('breath, boot, off, and the short error shake', () {
    expect(breatheScale(0), closeTo(math.sin(1) * 0.03, 1e-12));
    expect(bootSquash(0), closeTo(0.65, 1e-12));
    expect(bootSquash(0.6), closeTo(1, 1e-12));
    expect(bootEyeOpen(0.5), 0);
    expect(bootEyeOpen(1.2), closeTo(1, 1e-9));
    expect(offFade(0), 1);
    expect(offFade(1.3), 0);
    expect(offEyeOpen(0), 1);
    expect(offEyeOpen(1), 0);
    expect(errorLean(0.1, 0.1), isNot(closeTo(0, 1e-6)));
    expect(errorLean(1, 0.7), 0);
    expect(happyHop(0, 1), 0);
    expect(happyHop(math.pi / 18, 1), closeTo(3, 1e-9));
    expect(happyHop(math.pi / 18, 0), 0);
  });

  test('talking mouth, waves, and sparkle counts follow the spec', () {
    expect(talkOpen(0, 1), closeTo(1.35, 1e-12));
    expect(mouthHeight(talkOpen(0, 1)), 4);
    expect(mouthHeight(0), 1);
    expect(soundWaveCount(0), 1);
    expect(soundWaveCount(0.5), 2);
    expect(soundWaveCount(1), 3);
    expect(waveFlicker(0, 0), closeTo(0.5, 1e-12));
    expect(sparkles(0, AvatarPose.boot, 0), isEmpty);
    expect(sparkles(0, AvatarPose.idle, 1), hasLength(6));
    expect(sparkles(0, AvatarPose.boot, 0.5).length, 3);
    expect(sparkleSpeed(AvatarPose.thinking, 1), 2.8);
    expect(sparkleSpeed(AvatarPose.listening, 1), 1.2);
    expect(sparkleSpeed(AvatarPose.speaking, 1), 1.5);
    expect(sparkleSpeed(AvatarPose.boot, 0.5), 3);
    expect(sparkles(0, AvatarPose.idle, 1).first.behind, isTrue);
    expect(avatarLevel(AvatarPose.idle, 1), 0);
    expect(
      avatarLevel(AvatarPose.listening, math.pi / 2 / 6),
      closeTo(0.75, 1e-9),
    );
  });

  test('each mode picks its eyes, mouth, and arms', () {
    expect(frame(AvatarPose.idle).eye, FaceEye.bead);
    expect(frame(AvatarPose.idle).mouth, FaceMouth.smile);
    expect(frame(AvatarPose.idle).sway, isNot(0));

    expect(frame(AvatarPose.listening).eye, FaceEye.wide);
    expect(frame(AvatarPose.listening).mouth, FaceMouth.oh);
    expect(frame(AvatarPose.listening).arm, ArmCue.cup);
    expect(frame(AvatarPose.listening).waves, greaterThan(0));

    final thinking = frame(AvatarPose.thinking);
    expect(thinking.eye, FaceEye.glance);
    expect(thinking.mouth, FaceMouth.hmm);
    expect(thinking.arm, ArmCue.chin);
    expect(thinking.eyeOpen, closeTo(0.85, 1e-9));

    final speaking = frame(AvatarPose.speaking, level: 0.4);
    expect(speaking.mouth, FaceMouth.talk);
    expect(speaking.arm, ArmCue.talk);
    expect(speaking.blush, closeTo(0.7, 1e-9));
    expect(speaking.step, isNot(0));

    final error = frame(AvatarPose.error, happy: 1);
    expect(error.eye, FaceEye.cross);
    expect(error.mouth, FaceMouth.flat);
    expect(error.alert, isTrue);
    expect(error.hearts, isFalse);
    expect(error.hop, 0);

    expect(frame(AvatarPose.boot, modeT: 0.4).eye, FaceEye.shut);
    expect(frame(AvatarPose.boot, modeT: 1.2).eye, FaceEye.bead);
    expect(frame(AvatarPose.boot, modeT: 0).squash, closeTo(0.65, 1e-12));
    expect(frame(AvatarPose.off, modeT: 0).arm, ArmCue.wave);
    expect(frame(AvatarPose.off, modeT: 0).fade, 1);
    expect(frame(AvatarPose.off, modeT: 1.3).fade, 0);

    final pet = frame(AvatarPose.idle, happy: 1, seconds: math.pi / 18);
    expect(pet.eye, FaceEye.happy);
    expect(pet.mouth, FaceMouth.grin);
    expect(pet.arm, ArmCue.up);
    expect(pet.hearts, isTrue);
    expect(pet.hop, closeTo(3, 1e-9));
    expect(pet.gazeX, closeTo(0.8, 1e-9));
    expect(pet.gazeY, closeTo(0.7, 1e-9));
  });

  test(
    'a blink shuts bead eyes and a heart rises only while phase < happy',
    () {
      final shut = frame(AvatarPose.idle, blinkShut: 1);
      expect(shut.eye, FaceEye.shut);
      expect(shut.eyeOpen, 0);
      expect(heartPhase(0, 0), 0);
      expect(heartPhase(0, 1), 0.5);
    },
  );
}

AvatarScheme scheme(int f0, int f1, int f2, int f3, int accent) {
  return AvatarScheme(f0, f1, f2, f3, accent);
}

AvatarLife frame(
  AvatarPose pose, {
  double seconds = 0.4,
  double modeT = 2,
  double level = 0,
  double happy = 0,
  double blinkShut = 0,
}) {
  return avatarLife(
    pose: pose,
    seconds: seconds,
    modeT: modeT,
    level: level,
    happy: happy,
    blinkShut: blinkShut,
    gazeX: 1,
    gazeY: 1,
  );
}
