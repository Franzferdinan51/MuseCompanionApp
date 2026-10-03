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
// Shared mock of the native BLE peripheral channels for widget tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/ble_peripheral.dart';

/// scriptable stand-in for the platform GATT server + advertiser.
class MockBleNative {
  final calls = <MethodCall>[];
  bool supported = true;
  bool bluetoothOn = true;
  bool startOk = true;
  MockStreamHandlerEventSink? sink;

  TestDefaultBinaryMessenger get messenger =>
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  void install() {
    messenger.setMockMethodCallHandler(
      const MethodChannel(bleMethodChannel),
      (call) async {
        calls.add(call);
        return switch (call.method) {
          'isSupported' => supported,
          'isBluetoothOn' => bluetoothOn,
          'start' => startOk,
          'stop' => null,
          'notify' => true,
          'disconnect' => null,
          _ => throw PlatformException(code: 'unimplemented'),
        };
      },
    );
    messenger.setMockStreamHandler(
      const EventChannel(bleEventChannel),
      MockStreamHandler.inline(onListen: (args, events) {
        sink = events;
      }),
    );
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(
        const MethodChannel(bleMethodChannel), null);
    messenger.setMockStreamHandler(
        const EventChannel(bleEventChannel), null);
  }

  void emit(Map<String, Object?> event) {
    sink!.success(event);
  }
}
