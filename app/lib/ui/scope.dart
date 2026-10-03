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
// Shared app context: the gadget service, presentation state and settings
// store are created once at the root and exposed to descendant widgets through
// this InheritedWidget so screens stay decoupled from construction order.

import 'package:flutter/material.dart';

import '../app/ble_peripheral.dart';
import '../app/chat.dart';
import '../app/model.dart';
import '../app/storage.dart';
import 'package:muse_companion/src/gadget/service.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.service,
    required this.presentation,
    required this.settings,
    required this.ble,
    required this.chat,
    required this.sdkTokens,
    required super.child,
  });

  final GadgetService service;
  final PresentationState presentation;
  final SettingsStore settings;
  final BlePeripheralManager ble;
  final ChatHistory chat;
  final SecureSdkTokenStore sdkTokens;

  static AppScope of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing; wrap the app in it');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      service != oldWidget.service ||
      presentation != oldWidget.presentation ||
      settings != oldWidget.settings ||
      ble != oldWidget.ble ||
      chat != oldWidget.chat ||
      sdkTokens != oldWidget.sdkTokens;
}
