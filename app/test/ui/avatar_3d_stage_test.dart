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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/avatar_motion.dart';
import 'package:muse_companion/ui/avatar_3d_stage.dart';
import 'package:muse_companion/ui/pixel_stage.dart';

void main() {
  Future<void> pumpStage(WidgetTester tester, AvatarPose pose) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Avatar3DStage(pose: pose, bytes: null),
        ),
      ),
    );
    // Bounded pumps: the pixel fallback animates forever, so
    // pumpAndSettle would never finish. These frames also let the
    // video-stage asset init fail and yield to the pixel fallback.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('falls back to the pixel stage where 3D is unavailable',
      (tester) async {
    await pumpStage(tester, AvatarPose.idle);
    expect(find.byType(PixelStage), findsOneWidget);
  });

  testWidgets('pose changes do not crash on the fallback path',
      (tester) async {
    await pumpStage(tester, AvatarPose.speaking);
    expect(find.byType(PixelStage), findsOneWidget);
    await pumpStage(tester, AvatarPose.thinking);
    expect(find.byType(PixelStage), findsOneWidget);
  });
}
