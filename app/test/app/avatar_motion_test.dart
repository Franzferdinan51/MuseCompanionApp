import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/avatar_motion.dart';

void main() {
  test('idle bob peaks at one pixel-unit', () {
    final motion = avatarMotion(AvatarPose.idle, math.pi / 2 / 1.8);
    expect(motion.bob, closeTo(1, 1e-9));
    expect(motion.rings, isFalse);
  });

  test('listening draws rings that advance at 0.9', () {
    final motion = avatarMotion(AvatarPose.listening, 1);
    expect(motion.rings, isTrue);
    expect(motion.ringPhase, closeTo(0.9, 1e-9));
    expect(motion.bob, closeTo(math.sin(3) * 0.6, 1e-9));
  });

  test('activity and status map onto poses', () {
    expect(poseForActivity('speaking'), AvatarPose.speaking);
    expect(poseForActivity('using_tool'), AvatarPose.thinking);
    expect(poseForActivity('idle'), AvatarPose.idle);
    expect(poseForStatus('Listening…'), AvatarPose.listening);
    expect(poseForStatus('Looking through the camera'), AvatarPose.thinking);
    expect(poseForStatus('Hello'), isNull);
  });
}
