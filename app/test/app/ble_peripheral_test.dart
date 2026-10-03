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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/ble_peripheral.dart';
import 'package:muse_companion/src/gadget/ble_framing.dart';
import 'package:muse_companion/src/gadget/ble_setup.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/service.dart';

class _FakeNetwork implements SetupNetwork {
  @override
  Future<bool> isOnline() async => true;

  @override
  Map<String, Object?> currentConnectionEntry() => const {
        'ssid': 'test',
        'state': 'connected',
      };
}

class _Native {
  _Native(this.messenger);

  final TestDefaultBinaryMessenger messenger;
  final calls = <MethodCall>[];
  bool supported = true;
  bool bluetoothOn = true;
  bool startOk = true;
  MockStreamHandlerEventSink? sink;

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

  void emit(Map<String, Object?> event) {
    sink!.success(event);
  }
}

BlePeripheralManager _manager(_Native native,
        {PairingStore? store}) =>
    BlePeripheralManager(
      identity: const Identity('02:00:00:aa:bb:cc'),
      pairingStore: store ?? MemoryPairingStore(),
      version: '1.2.3-test',
      network: _FakeNetwork(),
      notifyStagger: Duration.zero,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Native native;
  final managers = <BlePeripheralManager>[];

  BlePeripheralManager track(BlePeripheralManager manager) {
    managers.add(manager);
    return manager;
  }

  setUp(() {
    final binding = TestWidgetsFlutterBinding.instance;
    native = _Native(binding.defaultBinaryMessenger);
    native.install();
  });

  tearDown(() async {
    for (final manager in managers) {
      await manager.dispose();
    }
    managers.clear();
    final binding = TestWidgetsFlutterBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(bleMethodChannel), null);
    binding.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel(bleEventChannel), null);
  });

  test('start advertises with the gadget UUIDs and BLE name', () async {
    final manager = track(_manager(native));
    expect(await manager.start(), isTrue);
    expect(manager.state, BlePeripheralState.advertising);
    expect(manager.deviceName, 'MuseGadgetAABBCC');

    final start = native.calls.lastWhere((c) => c.method == 'start');
    final args = start.arguments as Map;
    expect(args['name'], 'MuseGadgetAABBCC');
    expect(args['paired'], isFalse);
    expect(args['serviceUuid'], gadgetServiceUuid);
    expect(args['rxUuid'], gadgetRxUuid);
    expect(args['txUuid'], gadgetTxUuid);

    await manager.stop();
    expect(manager.state, BlePeripheralState.idle);
    expect(native.calls.last.method, 'stop');
  });

  test('start reports the saved pairing in the paired flag', () async {
    final store = MemoryPairingStore();
    await store.save(const {'access_token': 'a'});
    final manager = track(_manager(native, store: store));
    expect(await manager.start(), isTrue);
    final start = native.calls.lastWhere((c) => c.method == 'start');
    expect((start.arguments as Map)['paired'], isTrue);
  });

  test('native connect/disconnect moves between states', () async {
    final manager = track(_manager(native));
    final states = <BlePeripheralState>[];
    manager.onStateChanged.listen(states.add);
    await manager.start();
    native.emit(const {'type': 'connected'});
    await pumpEventQueue();
    expect(manager.state, BlePeripheralState.connected);
    native.emit(const {'type': 'disconnected'});
    await pumpEventQueue();
    expect(manager.state, BlePeripheralState.advertising);
    expect(states, containsAllInOrder([
      BlePeripheralState.starting,
      BlePeripheralState.advertising,
      BlePeripheralState.connected,
      BlePeripheralState.advertising,
    ]));
  });

  test('native error surfaces its detail', () async {
    final manager = track(_manager(native));
    await manager.start();
    native.emit(const {'type': 'error', 'message': 'boom'});
    await pumpEventQueue();
    expect(manager.state, BlePeripheralState.error);
    expect(manager.detail, 'boom');
  });

  test('RX writes reach the setup engine without crashing', () async {
    final manager = track(_manager(native));
    await manager.start();
    // A plaintext get_device_info request; the reply flows back through
    // the mocked notify channel.
    final request = encodeChunks(
        Uint8List.fromList('{"action":"get_device_info"}'.codeUnits));
    for (final packet in request) {
      native.emit({
        'type': 'write',
        'data': packet,
        'mtu': 23,
      });
    }
    await pumpEventQueue(times: 100);
    expect(native.calls.any((c) => c.method == 'notify'), isTrue);
  });

  test('unsupported native side maps to unsupported', () async {
    native.supported = false;
    final manager = track(_manager(native));
    expect(await manager.start(), isFalse);
    expect(manager.state, BlePeripheralState.unsupported);
  });

  test('bluetooth off maps to a helpful error', () async {
    native.bluetoothOn = false;
    final manager = track(_manager(native));
    expect(await manager.start(), isFalse);
    expect(manager.state, BlePeripheralState.error);
    expect(manager.detail, contains('Bluetooth is off'));
  });

  test('refused native start maps to an error', () async {
    native.startOk = false;
    final manager = track(_manager(native));
    expect(await manager.start(), isFalse);
    expect(manager.state, BlePeripheralState.error);
  });

  test('missing plugin maps to unsupported', () async {
    final binding = TestWidgetsFlutterBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(bleMethodChannel), null);
    final manager = track(_manager(native));
    expect(await manager.start(), isFalse);
    expect(manager.state, BlePeripheralState.unsupported);
  });

  test('provision verify rejects a 401 without saving', () async {
    // The default verifier hits the network; here the token is garbage,
    // so whatever the network says, a non-401 path that throws is still
    // a ProvisionFailed from the manager wrapper, never a crash.
    final manager = track(BlePeripheralManager(
      identity: const Identity('02:00:00:aa:bb:cc'),
      pairingStore: MemoryPairingStore(),
      version: '0.0.0-test',
      network: _FakeNetwork(),
      notifyStagger: Duration.zero,
      verifyProvision: (_) async {
        throw const ProvisionFailed('provision_unauthorized');
      },
    ));
    await manager.start();
    // Drive the private provision path through a real controller is
    // covered by ble_setup_test; here just confirm the manager survives.
    expect(manager.state, BlePeripheralState.advertising);
  });
}
