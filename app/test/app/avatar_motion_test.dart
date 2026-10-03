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
    expect(poseForActivity('boot'), AvatarPose.boot);
    expect(poseForActivity('starting'), AvatarPose.boot);
    expect(poseForActivity('off'), AvatarPose.off);
    expect(poseForActivity('shutdown'), AvatarPose.off);
    expect(poseForActivity('asleep'), AvatarPose.off);
    expect(poseForActivity('sleep'), AvatarPose.off);
    expect(poseForStatus('Listening…'), AvatarPose.listening);
    expect(poseForStatus('Looking through the camera'), AvatarPose.thinking);
    expect(poseForStatus('Looking at the screen'), AvatarPose.thinking);
    expect(poseForStatus('Hello'), isNull);
    expect(captionSetsThinking(streaming: true, pose: AvatarPose.idle), isTrue);
    expect(
      captionSetsThinking(streaming: false, pose: AvatarPose.idle),
      isFalse,
    );
    expect(
      captionSetsThinking(streaming: true, pose: AvatarPose.speaking),
      isFalse,
    );
    expect(
      captionSetsThinking(streaming: true, pose: AvatarPose.listening),
      isFalse,
    );
    expect(activitySetsPose('idle', streaming: false), isTrue);
    expect(activitySetsPose('listening', streaming: false), isTrue);
    expect(activitySetsPose('thinking', streaming: false), isFalse);
    expect(activitySetsPose('using_tool', streaming: false), isFalse);
    expect(activitySetsPose('thinking', streaming: true), isTrue);
  });

  test('boot and off hold still while error keeps its shake', () {
    for (final pose in [AvatarPose.boot, AvatarPose.off]) {
      final motion = avatarMotion(pose, 1.2);
      expect(motion.bob, 0);
      expect(motion.lean, 0);
      expect(motion.scale, 1);
      expect(motion.rings, isFalse);
    }
    final error = avatarMotion(AvatarPose.error, 1);
    expect(error.lean, closeTo(math.sin(28) * 1.4, 1e-9));
    expect(error.bob, 0);
  });
}
