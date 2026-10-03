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
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/ble_peripheral.dart';
import 'package:muse_companion/app/chat.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/app/storage.dart';
import 'package:muse_companion/src/gadget/ble_setup.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/service.dart';
import 'package:muse_companion/ui/pairing_screen.dart';
import 'package:muse_companion/ui/scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('pairingStepIndex', () {
    test('idle starts at the waiting step', () {
      expect(pairingStepIndex(BlePeripheralState.idle, null), 0);
      expect(pairingStepIndex(BlePeripheralState.advertising, null), 0);
      expect(
          pairingStepIndex(
              BlePeripheralState.advertising, SetupEventKind.started),
          0);
    });

    test('connection and hello advance the handshake step', () {
      expect(pairingStepIndex(BlePeripheralState.connected, null), 1);
      expect(
          pairingStepIndex(
              BlePeripheralState.connected, SetupEventKind.helloReceived),
          1);
    });

    test('confirm moves to the credentials step', () {
      expect(
          pairingStepIndex(
              BlePeripheralState.connected, SetupEventKind.pairingConfirmed),
          2);
    });

    test('provisioning events map to the verifying step', () {
      for (final kind in [
        SetupEventKind.provisioning,
        SetupEventKind.wifiConnecting,
        SetupEventKind.wifiConnected,
        SetupEventKind.wifiFailed,
        SetupEventKind.failed,
      ]) {
        expect(pairingStepIndex(BlePeripheralState.connected, kind), 3,
            reason: '$kind');
      }
    });

    test('authOk and done reach the final step', () {
      expect(
          pairingStepIndex(
              BlePeripheralState.connected, SetupEventKind.authOk),
          4);
      expect(pairingStepIndex(BlePeripheralState.done, null), 4);
    });

    test('disconnect falls back to the waiting step', () {
      expect(
          pairingStepIndex(BlePeripheralState.advertising,
              SetupEventKind.clientDisconnected),
          0);
    });
  });

  group('PairingScreen', () {
    late TestDefaultBinaryMessenger messenger;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel(bleMethodChannel),
        (call) async => switch (call.method) {
          'isSupported' => true,
          'isBluetoothOn' => true,
          'start' => true,
          'stop' => null,
          'notify' => true,
          'disconnect' => null,
          _ => throw PlatformException(code: 'unimplemented'),
        },
      );
      messenger.setMockStreamHandler(
        const EventChannel(bleEventChannel),
        MockStreamHandler.inline(onListen: (args, events) {}),
      );
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(
          const MethodChannel(bleMethodChannel), null);
      messenger.setMockStreamHandler(
          const EventChannel(bleEventChannel), null);
    });

    Future<void> pumpScreen(WidgetTester tester) async {
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
          home: PairingScreen(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the advertised name and starts advertising',
        (tester) async {
      await pumpScreen(tester);

      expect(find.text('Pair a Muse'), findsOneWidget);
      expect(find.text('MuseGadgetCCDDEE'), findsOneWidget);
      expect(find.text('Start pairing'), findsOneWidget);

      await tester.tap(find.text('Start pairing'));
      // Bounded pumps: the advertising spinner animates forever, so
      // pumpAndSettle would time out. Poll until the state lands.
      for (var i = 0;
          i < 20 &&
              find
                  .text('Advertising — open the Muse app')
                  .evaluate()
                  .isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('Advertising — open the Muse app'), findsOneWidget);
      expect(find.text('Waiting for the Muse app'), findsOneWidget);
      expect(find.text('Secure handshake'), findsOneWidget);

      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Start pairing'), findsOneWidget);
    });
  });
}
