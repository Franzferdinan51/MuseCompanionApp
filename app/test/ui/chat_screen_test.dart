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
import 'package:muse_companion/app/ble_peripheral.dart';
import 'package:muse_companion/app/chat.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/app/storage.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/service.dart';
import 'package:muse_companion/ui/chat_screen.dart';
import 'package:muse_companion/ui/scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('offline send records the service error inline',
      (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.init();
    final presentation =
        PresentationState(settings: settings.loadSettings());
    final service = GadgetService(
      identity: const Identity('02:aa:bb:cc:dd:ee'),
      commands: const {},
      runCommand: (_, _, _) async => {'ok': true},
      pairingStore: MemoryPairingStore(),
      version: '0.1.0',
    );
    final ble = BlePeripheralManager(
      identity: const Identity('02:aa:bb:cc:dd:ee'),
      pairingStore: MemoryPairingStore(),
      version: '0.1.0',
    );
    final chat = ChatHistory();
    addTearDown(() async {
      await service.stop();
      await ble.dispose();
      chat.close();
      presentation.close();
    });

    await tester.pumpWidget(AppScope(
      service: service,
      presentation: presentation,
      settings: settings,
      ble: ble,
      chat: chat,
      sdkTokens: SecureSdkTokenStore(),
      child: const MaterialApp(
        home: ChatScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    // Fresh service is stopped: the banner says so and the empty hint
    // explains the history.
    expect(find.textContaining('Stopped'), findsOneWidget);
    expect(find.text('Message Muse'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello muse');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.text('hello muse'), findsOneWidget);
    expect(find.textContaining('not connected'), findsOneWidget);
    expect(chat.messages.single.status, ChatStatus.failed);
  });
}
