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
// Shared mocks for the platform plugins the UI touches: secure storage
// (SDK tokens) and the clipboard (diagnostics copy). Unmocked plugin
// channels never complete under widget-test fake async, which wedges any
// screen awaiting them, so widget tests that reach those paths install
// this alongside [MockBleNative].

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in for secure storage + clipboard platform channels.
class MockPlatformPlugins {
  final secureStorageCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];

  /// Last text handed to Clipboard.setData, for assertions.
  String? clipboardText;

  TestDefaultBinaryMessenger get messenger =>
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  void install() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        secureStorageCalls.add(call);
        return switch (call.method) {
          'read' => null,
          'readAll' => <String, String>{},
          'containsKey' => false,
          'write' => null,
          'delete' => null,
          'deleteAll' => null,
          _ => null,
        };
      },
    );
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call);
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments;
          if (args is Map) {
            clipboardText = args['text'] as String?;
          }
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return clipboardText == null ? null : {'text': clipboardText};
        }
        return null;
      },
    );
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(
        const MethodChannel(
            'plugins.it_nomads.com/flutter_secure_storage'),
        null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }
}
