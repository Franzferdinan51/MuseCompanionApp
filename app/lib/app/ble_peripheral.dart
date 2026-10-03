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
// App-side BLE setup peripheral.
//
// This phone plays the gadget's side of BLE provisioning: it advertises
// `MuseGadgetXXXXXX` with the same service and characteristics as the
// firmware, and drives the shared [SetupController] protocol engine with
// packets from the platform GATT server. The native side (Android
// `GadgetBlePeripheral`, later iOS/macOS/Windows equivalents behind the
// same channel names) only moves bytes; every protocol decision lives in
// Dart so behavior is identical on every OS.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:muse_companion/src/gadget/ble_framing.dart';
import 'package:muse_companion/src/gadget/ble_setup.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/muse_api.dart';
import 'package:muse_companion/src/gadget/pairing.dart';
import 'package:muse_companion/src/gadget/service.dart';

const String bleMethodChannel = 'dev.musecompanion/ble';
const String bleEventChannel = 'dev.musecompanion/ble_events';

/// GATT identifiers shared with the Muse gadget firmware.
const String gadgetServiceUuid = '7fdd3d1c-38ea-46cf-8b46-314ecf5f240c';
const String gadgetRxUuid = '4d593029-28a2-4a6e-a1f0-3c2d5e8f9b01';
const String gadgetTxUuid = 'd75dc4ca-7b2b-4e9c-8f0a-1d2e3f4a5b6c';

const int defaultAttMtu = 23;

/// Where the BLE setup flow stands, for the pairing wizard.
enum BlePeripheralState {
  idle,
  starting,
  advertising,
  connected,
  done,
  error,
  unsupported,
}

typedef BleLogger = void Function(String message);

void _nullBleLogger(String message) {}

/// Verifies provisioned credentials before they are committed.
///
/// Throws [ProvisionFailed] when the credentials must be rejected; any
/// other throw is treated as a transient failure with a generic status.
typedef ProvisionVerifier = Future<void> Function(Credentials credentials);

/// Default verifier: the device token must be accepted by the Muse API.
///
/// Any 2xx response accepts the pairing, even with no leased VMs yet —
/// the connection loop waits for a Muse to become available. A 401 means
/// the token is already bad, and a transport failure means the phone
/// cannot reach the API right now.
Future<void> verifyProvisionWithApi(
  Credentials credentials, {
  String version = '0.0.0',
}) async {
  final fetched = await fetchVmsWithStatus(
    credentials.accessToken,
    root: apiRoot(credentials.apiUrlV2),
    version: version,
  );
  if (fetched.status == 401) {
    throw const ProvisionFailed('provision_unauthorized');
  }
  if (fetched.status == null) {
    throw const ProvisionFailed('provision_verify_failed');
  }
}

/// MethodChannel-backed [SetupTransport].
class BleMethodTransport implements SetupTransport {
  BleMethodTransport({
    required MethodChannel channel,
    required int Function() currentMtu,
    this.stagger = chunkStagger,
  })  : _channel = channel,
        _currentMtu = currentMtu;

  final MethodChannel _channel;
  final int Function() _currentMtu;

  /// Delay between notifications; tests pass [Duration.zero].
  final Duration stagger;

  @override
  Future<void> sendPackets(List<Uint8List> packets) async {
    // Stagger notifications like the firmware: a burst of back-to-back
    // notifies (pairing_ready is ~40 chunks at MTU 23) overruns phone
    // BLE stacks and arrives truncated, stalling the handshake.
    for (var i = 0; i < packets.length; i++) {
      await _channel.invokeMethod<bool>('notify', {'packet': packets[i]});
      if (stagger > Duration.zero && i + 1 < packets.length) {
        await Future<void>.delayed(stagger);
      }
    }
  }

  @override
  int mtu() => _currentMtu();

  @override
  void disconnect(Duration delay) {
    Future<void>.delayed(delay, () async {
      try {
        await _channel.invokeMethod<void>('disconnect');
      } on PlatformException {
        // The link is already gone; nothing left to do.
      }
    });
  }
}

/// The phone's own connectivity answers the setup client's network checks.
///
/// There is no Wi-Fi to join: this gadget is online whenever the phone is.
/// The scan result echoes the current link so the app's "connected" step
/// has something truthful to show.
class PhoneSetupNetwork implements SetupNetwork {
  PhoneSetupNetwork([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> isOnline() async {
    final result = await _connectivity.checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }

  @override
  Map<String, Object?> currentConnectionEntry() => const {
        'ssid': 'this phone',
        'state': 'connected',
      };
}

/// Owns native BLE advertising and the [SetupController] protocol engine.
class BlePeripheralManager {
  BlePeripheralManager({
    required Identity identity,
    required PairingStore pairingStore,
    required String version,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    SetupNetwork? network,
    ProvisionVerifier? verifyProvision,
    this.onProvisioned,
    this.notifyStagger = chunkStagger,
    BleLogger logger = _nullBleLogger,
  })  : _identity = identity,
        _pairingStore = pairingStore,
        _version = version,
        _methodChannel =
            methodChannel ?? const MethodChannel(bleMethodChannel),
        _eventChannel = eventChannel ?? const EventChannel(bleEventChannel),
        _network = network ?? PhoneSetupNetwork(),
        _verifyProvision = verifyProvision ?? ((c) => verifyProvisionWithApi(
              c,
              version: version,
            )),
        _logger = logger;

  final Identity _identity;
  final PairingStore _pairingStore;
  final String _version;
  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final SetupNetwork _network;
  final ProvisionVerifier _verifyProvision;

  /// Called on the UI thread once a pairing is committed.
  ///
  /// The service loop wakes from here so it picks up the new pairing
  /// without waiting out its poll sleep.
  final void Function()? onProvisioned;

  /// Delay between BLE notifications; tests pass [Duration.zero].
  final Duration notifyStagger;

  final BleLogger _logger;

  final StreamController<BlePeripheralState> _states =
      StreamController<BlePeripheralState>.broadcast();
  final StreamController<SetupEvent> _setupEvents =
      StreamController<SetupEvent>.broadcast();
  final StreamController<String> _logLines =
      StreamController<String>.broadcast();

  /// In-memory tail of [_log] lines for the diagnostics screen.
  final List<String> _recentLogs = <String>[];

  /// Maximum lines kept in [recentLogs].
  static const int maxRecentLogs = 300;

  BlePeripheralState _state = BlePeripheralState.idle;
  String _detail = '';
  int _mtu = defaultAttMtu;
  StreamSubscription<dynamic>? _events;
  StreamSubscription<SetupEvent>? _setupSub;
  SetupController? _setup;
  bool _disposed = false;

  Stream<BlePeripheralState> get onStateChanged => _states.stream;
  BlePeripheralState get state => _state;

  /// Human-readable detail for the error state.
  String get detail => _detail;

  /// Protocol lifecycle events from the active setup session.
  Stream<SetupEvent> get setupEvents => _setupEvents.stream;

  /// Timestamped log lines for the diagnostics screen.
  Stream<String> get logLines => _logLines.stream;

  /// The bounded in-memory tail of log lines, oldest first.
  List<String> get recentLogs => List.unmodifiable(_recentLogs);

  String get deviceName => _identity.bleName;
  String get nodeId => _identity.nodeId;
  String get mac => _identity.mac;

  bool get isActive =>
      _state == BlePeripheralState.advertising ||
      _state == BlePeripheralState.connected;

  void _log(String message) {
    _logger(message);
    final stamp = DateTime.now().toIso8601String().substring(11, 23);
    final line = '[$stamp] $message';
    _recentLogs.add(line);
    if (_recentLogs.length > maxRecentLogs) {
      _recentLogs.removeRange(0, _recentLogs.length - maxRecentLogs);
    }
    if (!_logLines.isClosed) {
      _logLines.add(line);
    }
  }

  void _setState(BlePeripheralState state, [String detail = '']) {
    _state = state;
    _detail = detail;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  /// Start advertising and accept one setup client at a time.
  ///
  /// Returns true while advertising is up. Safe to call again after
  /// [stop]; calling while active is a no-op returning true.
  Future<bool> start() async {
    if (isActive || _state == BlePeripheralState.starting) {
      return true;
    }
    if (_disposed) return false;
    _setState(BlePeripheralState.starting);
    _log('starting BLE peripheral as ${_identity.bleName}');

    bool supported = false;
    try {
      supported =
          await _methodChannel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      _log('no native BLE plugin on this platform');
      _setState(BlePeripheralState.unsupported,
          'BLE setup is not available on this device yet');
      return false;
    } on PlatformException catch (e) {
      _log('BLE support check failed: ${e.message}');
      _setState(BlePeripheralState.error,
          'Could not start Bluetooth: ${e.message ?? e.code}');
      return false;
    }
    if (!supported) {
      _log('native BLE peripheral not supported');
      _setState(BlePeripheralState.unsupported,
          'This device cannot advertise over Bluetooth LE');
      return false;
    }

    final bluetoothOn =
        await _methodChannel.invokeMethod<bool>('isBluetoothOn') ?? false;
    if (!bluetoothOn) {
      _log('bluetooth is off');
      _setState(BlePeripheralState.error,
          'Bluetooth is off — turn it on and try again');
      return false;
    }

    final pairing = await _pairingStore.load();
    _mtu = defaultAttMtu;

    final setup = SetupController(
      pairing: PairingSession(
        nodeId: _identity.nodeId,
        deviceId: _identity.deviceId,
        mac: _identity.mac,
        firmwareVersion: _version,
      ),
      identity: _identity,
      version: _version,
      transport: BleMethodTransport(
        channel: _methodChannel,
        currentMtu: () => _mtu,
        stagger: notifyStagger,
      ),
      network: _network,
      provision: _runProvision,
      onComplete: _handleProvisioned,
      logger: _log,
    );
    await _setupSub?.cancel();
    _setup = setup;
    _setupSub = setup.events.listen(_setupEvents.add);
    setup.start();

    await _events?.cancel();
    _events = _eventChannel.receiveBroadcastStream().listen(
          _handleNativeEvent,
          onError: (Object e) {
            _log('BLE event stream error: $e');
            _setState(BlePeripheralState.error, 'Bluetooth link lost: $e');
          },
        );

    bool started = false;
    try {
      started = await _methodChannel.invokeMethod<bool>('start', {
            'name': _identity.bleName,
            'paired': pairing != null,
            'serviceUuid': gadgetServiceUuid,
            'rxUuid': gadgetRxUuid,
            'txUuid': gadgetTxUuid,
          }) ??
          false;
    } on PlatformException catch (e) {
      _log('native start failed: ${e.message}');
      await _tearDownSetup();
      _setState(BlePeripheralState.error,
          'Could not advertise: ${e.message ?? e.code}');
      return false;
    }
    if (!started) {
      _log('native start refused');
      await _tearDownSetup();
      _setState(BlePeripheralState.error,
          'Could not advertise — is Bluetooth available?');
      return false;
    }
    _log('advertising as ${_identity.bleName}');
    _setState(BlePeripheralState.advertising);
    return true;
  }

  /// Stop advertising and drop the setup session.
  Future<void> stop() async {
    if (_state == BlePeripheralState.idle) return;
    _log('stopping BLE peripheral');
    await _tearDownSetup();
    try {
      await _methodChannel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      _log('native stop failed: ${e.message}');
    } on MissingPluginException {
      // Nothing native was ever started.
    }
    if (!_disposed) {
      _setState(BlePeripheralState.idle);
    }
  }

  Future<void> dispose() async {
    // Idempotent: tests stop in the body and again in addTearDown, and a
    // second close() would wedge awaiting an already-closed controller.
    // The closes are not awaited: like subscription cancels, a close()
    // future only completes on real event-loop turns, which never come
    // under widget-test fake async when a listener (e.g. a mounted
    // DiagnosticsScreen) is still subscribed. close() itself takes effect
    // synchronously; only the done-delivery signal is dropped.
    if (_disposed) return;
    _disposed = true;
    await stop();
    unawaited(_states.close());
    unawaited(_setupEvents.close());
    unawaited(_logLines.close());
  }

  Future<void> _tearDownSetup() async {
    // Never await subscription cancels here: a cancel() future only
    // completes on real event-loop turns, which never come under
    // widget-test fake async, so awaiting wedges stop/dispose/teardown.
    // The subscriptions are dropped first so nothing further is
    // processed; straggler events are harmless (broadcast streams with
    // guarded listeners, and _setup is nulled below).
    final events = _events;
    _events = null;
    unawaited(events?.cancel().catchError((_) {}));
    final setupSub = _setupSub;
    _setupSub = null;
    unawaited(setupSub?.cancel().catchError((_) {}));
    final setup = _setup;
    _setup = null;
    if (setup != null) {
      // Not awaited: SetupController.stop() awaits its in-flight RX tail,
      // whose completion signal never arrives under widget-test fake
      // async once the test body has returned (addTearDown phase). The
      // stop itself takes effect synchronously (_running=false + poison
      // pill), so the session still shuts down; only the acknowledgement
      // is dropped. Same class of wedge as the cancels above.
      unawaited(setup.stop());
    }
  }

  void _handleNativeEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'];
    switch (type) {
      case 'write':
        final data = event['data'];
        final mtu = event['mtu'];
        if (mtu is int && mtu >= defaultAttMtu) {
          _mtu = mtu;
        }
        if (data is Uint8List) {
          _setup?.onWrite(data);
        } else if (data is List) {
          _setup?.onWrite(Uint8List.fromList(data.cast<int>()));
        }
      case 'connected':
        _log('setup client connected');
        if (_state == BlePeripheralState.advertising) {
          _setState(BlePeripheralState.connected);
        }
      case 'disconnected':
        _log('setup client disconnected');
        _mtu = defaultAttMtu;
        _setup?.onDisconnect();
        if (_state == BlePeripheralState.connected) {
          // The native side resumes advertising on its own.
          _setState(BlePeripheralState.advertising);
        }
      case 'mtu':
        final mtu = event['mtu'];
        if (mtu is int && mtu >= defaultAttMtu) {
          _mtu = mtu;
          _log('ATT MTU now $mtu');
        }
      case 'error':
        final message = event['message'];
        final text =
            message is String && message.isNotEmpty ? message : 'BLE error';
        _log('native error: $text');
        _setState(BlePeripheralState.error, text);
    }
  }

  Future<void> _runProvision(
    Credentials credentials,
    Future<bool> Function(Future<bool> Function() save) commit,
  ) async {
    try {
      await _verifyProvision(credentials);
    } on ProvisionFailed {
      rethrow;
    } catch (e) {
      _log('provision verify threw: $e');
      throw const ProvisionFailed('provision_verify_failed');
    }
    final record = {
      'access_token': credentials.accessToken,
      'refresh_token': credentials.refreshToken,
      'access_token_saved_at':
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'api_url_v2': credentials.apiUrlV2,
      'noise_host': credentials.noiseHost,
      'username': credentials.username,
    };
    bool saved = false;
    try {
      saved = await commit(() async {
        await _pairingStore.save(record);
        return true;
      });
    } catch (e) {
      _log('pairing save threw: $e');
      throw const ProvisionFailed('provision_commit_failed');
    }
    if (!saved) {
      // The session went away (usually the app disconnected) after the
      // tokens verified. The credentials are proven good, so keep them
      // anyway instead of losing a pairing the app already accepted.
      _log('session gone after verify; saving the pairing directly');
      try {
        await _pairingStore.save(record);
      } catch (e) {
        _log('direct pairing save threw: $e');
        throw const ProvisionFailed('provision_commit_failed');
      }
    }
    _log('pairing saved for ${credentials.username}');
  }

  void _handleProvisioned() {
    _log('setup complete; stopping advertiser');
    onProvisioned?.call();
    _setState(BlePeripheralState.done);
    // Let `auth_ok` flush to the phone before the GATT server goes away.
    // The state stays `done` until the UI calls stop(), so the wizard
    // can show its success screen.
    Future<void>.delayed(const Duration(seconds: 1), () async {
      if (_state == BlePeripheralState.done && !_disposed) {
        await _tearDownSetup();
        try {
          await _methodChannel.invokeMethod<void>('stop');
        } on PlatformException catch (e) {
          _log('native stop failed: ${e.message}');
        } on MissingPluginException {
          // Nothing native was ever started.
        }
      }
    });
  }
}
