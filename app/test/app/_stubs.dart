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
// Test doubles for the CompanionDisplay / CompanionHealth platform sides used by
// the real CompanionExecutor. They record calls so dispatch can be asserted.

import 'package:muse_companion/src/gadget/commands.dart';

class CompanionDisplayStub implements CompanionDisplay {
  String? drawnUrl;
  bool drawnCalled = false;
  String? setStatusText;
  bool placeholderShown = false;
  Map<String, Object?>? lastSetDisplay;

  @override
  Future<String> setStatus(String text) async {
    setStatusText = text;
    return text;
  }

  @override
  Future<ImageDrawResult> drawImageFromUrl(String url) async {
    drawnCalled = true;
    drawnUrl = url;
    return ImageDrawResult.ok(
        width: 10, height: 10, bytes: 10, fromCache: false);
  }

  @override
  Future<void> showPlaceholder() async {
    placeholderShown = true;
  }

  @override
  Future<Map<String, Object?>> setDisplay(
      {String? theme, bool? keepScreenOn}) async {
    lastSetDisplay = {'theme': theme, 'keep_screen_on': keepScreenOn};
    return lastSetDisplay!;
  }

  @override
  Future<Map<String, Object?>> displayInfo() async => const {};
}

class CompanionHealthStub implements CompanionHealth {
  bool called = false;

  @override
  Future<Map<String, Object?>> health() async {
    called = true;
    return {'battery_percent': 42};
  }
}
