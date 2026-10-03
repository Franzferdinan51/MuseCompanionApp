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
// Motion for the user's own Muse portrait.
//
// The Waveshare, AiPi and Pocket screens move a character through idle,
// listening, thinking and speaking (see esp32/avatar/muse_pixel.c). The
// phone does not draw Meta's default pixel character. It moves the image
// Muse already sent — a JPEG, PNG, animated GIF, animated WebP, or GLB —
// with the same timing: idle bob sin(t*1.8), listening bob sin(t*3) plus
// rings, thinking bob sin(t*2.4) and lean sin(t*1.3), speaking bob
// sin(t*5) plus a scale pulse and rings.

import 'dart:math' as math;

/// What the portrait is doing. Matches the gadget avatar states the phone
/// can actually be in.
enum AvatarPose { idle, listening, thinking, speaking, error }

/// One frame of portrait motion. Offsets are in the same units as the
/// pixel avatar (about one pixel on a 64-wide sprite). The screen scales
/// them up.
class AvatarMotion {
  const AvatarMotion({
    required this.bob,
    required this.lean,
    required this.scale,
    required this.rings,
    required this.ringPhase,
  });

  /// Vertical offset. Positive is down.
  final double bob;

  /// Horizontal lean. Positive is to the right.
  final double lean;

  /// Uniform scale around the portrait center.
  final double scale;

  /// Listening and speaking draw the dotted rings.
  final bool rings;

  /// 0–1, how far the rings have expanded.
  final double ringPhase;
}

/// Pose motion at [seconds] since the screen started.
///
/// [level] is a 0–1 speech energy hint. The phone has no amplitude tap on
/// the system voice, so callers pass 0 and the scale pulse carries the
/// speaking motion.
AvatarMotion avatarMotion(AvatarPose pose, double seconds, {double level = 0}) {
  final t = seconds;
  switch (pose) {
    case AvatarPose.listening:
      return AvatarMotion(
        bob: math.sin(t * 3) * 0.6,
        lean: 0,
        scale: 1,
        rings: true,
        ringPhase: (t * 0.9) % 1,
      );
    case AvatarPose.thinking:
      return AvatarMotion(
        bob: math.sin(t * 2.4) * 0.8,
        lean: math.sin(t * 1.3) * 1.2,
        scale: 1,
        rings: false,
        ringPhase: 0,
      );
    case AvatarPose.speaking:
      final pulse = 0.5 + 0.5 * math.sin(t * 8);
      return AvatarMotion(
        bob: math.sin(t * 5) * 0.6 - level * 1.5,
        lean: 0,
        scale: 1 + 0.045 * pulse,
        rings: true,
        ringPhase: (t * 0.6) % 1,
      );
    case AvatarPose.error:
      return AvatarMotion(
        bob: 0,
        lean: math.sin(t * 28) * 1.4,
        scale: 1,
        rings: false,
        ringPhase: 0,
      );
    case AvatarPose.idle:
      return AvatarMotion(
        bob: math.sin(t * 1.8) * 1.0,
        lean: 0,
        scale: 1 + 0.015 * math.sin(t * 1.2),
        rings: false,
        ringPhase: 0,
      );
  }
}

/// Pose for an `agent.status` activity code.
AvatarPose poseForActivity(String code) {
  final key = code.trim().toLowerCase().replaceAll(' ', '_');
  switch (key) {
    case 'listening':
      return AvatarPose.listening;
    case 'speaking':
      return AvatarPose.speaking;
    case 'error':
    case 'failed':
      return AvatarPose.error;
    case '':
    case 'idle':
    case 'waiting':
      return AvatarPose.idle;
    default:
      return AvatarPose.thinking;
  }
}

/// Pose for a display status the phone itself sets, or null to leave the
/// current pose alone. Captions must not all become poses.
AvatarPose? poseForStatus(String text) {
  final value = text.trim().toLowerCase();
  if (value == 'listening' ||
      value == 'listening…' ||
      value == 'listening...') {
    return AvatarPose.listening;
  }
  if (value == 'looking through the camera') return AvatarPose.thinking;
  return null;
}
