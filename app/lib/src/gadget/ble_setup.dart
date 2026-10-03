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
// Dart port of the Muse Gadget SDK BLE setup commands
// (linux/src/musegadget/ble_setup.py).
//
// The protocol logic behind the GATT characteristics, independent of the
// platform BLE peripheral: a transport delivers reassembled writes and
// sends framed notifications. Messages are handled one at a time, in
// arrival order, and every send happens under one lock so encrypted
// record counters reach the phone in order.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'ble_framing.dart';
import 'identity.dart';
import 'pairing.dart';

/// Actions that require an encrypted, confirmed session.
const Set<String> sensitiveActions = {
  'provision',
  'provision_v2',
  'wifi_scan',
  'ota',
  'device.ota',
  'unpair',
  'set_wifi',
  'set_auth',
};

const Set<String> plaintextStatuses = {
  'error_encryption_required',
  'error_pairing_invalid_hello',
  'error_pairing_unavailable',
  'error_pairing_decrypt',
};

const Duration disconnectAfterError = Duration(milliseconds: 300);

/// Sends framed notifications to the setup client.
abstract class SetupTransport {
  /// Notify each packet in order.
  Future<void> sendPackets(List<Uint8List> packets);

  /// Current ATT MTU.
  int mtu();

  /// Disconnect the client after [delay].
  void disconnect(Duration delay);
}

/// Connectivity answers the setup client sees during provisioning.
abstract class SetupNetwork {
  Future<bool> isOnline();
  Map<String, Object?> currentConnectionEntry();
}

class Credentials {
  const Credentials({
    required this.accessToken,
    required this.refreshToken,
    required this.username,
    required this.apiUrl,
    required this.apiUrlV2,
    required this.noiseHost,
  });

  final String accessToken;
  final String refreshToken;
  final String username;
  final String apiUrl;
  final String apiUrlV2;
  final String noiseHost;
}

/// Setup could not finish; [status] is what the app is told.
class ProvisionFailed implements Exception {
  const ProvisionFailed(this.status);
  final String status;
  @override
  String toString() => 'ProvisionFailed: $status';
}

/// Runs the blocking provision step with the saved credentials.
///
/// It must verify the credentials and persist them through [commit]
/// (which runs under the pairing lock), throwing [ProvisionFailed] on
/// failure.
typedef ProvisionRunner = Future<void> Function(
  Credentials credentials,
  Future<bool> Function(Future<bool> Function() save) commit,
);

/// Setup lifecycle events for the pairing UI.
enum SetupEventKind {
  started,
  helloReceived,
  pairingConfirmed,
  wifiConnecting,
  wifiConnected,
  wifiFailed,
  provisioning,
  authOk,
  failed,
  clientDisconnected,
}

class SetupEvent {
  const SetupEvent(this.kind, [this.detail = '']);
  final SetupEventKind kind;
  final String detail;
}

typedef SetupLogger = void Function(String message);

void _nullLogger(String message) {}

String _compact(Map<String, Object?> obj) => json.encode(obj);

/// Handles one BLE setup client at a time.
class SetupController {
  SetupController({
    required PairingSession pairing,
    required Identity identity,
    required String version,
    required SetupTransport transport,
    required SetupNetwork network,
    required ProvisionRunner provision,
    void Function()? onComplete,
    SetupLogger logger = _nullLogger,
  })  : _pairing = pairing,
        _identity = identity,
        _version = version,
        _transport = transport,
        _network = network,
        _provision = provision,
        _onComplete = onComplete,
        _logger = logger;

  final PairingSession _pairing;
  final Identity _identity;
  final String _version;
  final SetupTransport _transport;
  final SetupNetwork _network;
  final ProvisionRunner _provision;
  final void Function()? _onComplete;
  final SetupLogger _logger;

  final ChunkAssembler _assembler = ChunkAssembler();
  final StreamController<Uint8List?> _inbox =
      StreamController<Uint8List?>();
  final StreamController<SetupEvent> _events =
      StreamController<SetupEvent>.broadcast();
  Future<void> _txTail = Future.value();
  Future<void> _rxTail = Future.value();
  bool _plaintextBlocked = false;
  bool _provisioning = false;
  bool _running = false;

  /// Lifecycle events for the pairing UI (broadcast stream).
  Stream<SetupEvent> get events => _events.stream;

  // -- Transport callbacks ------------------------------------------------

  /// Called with every raw RX write from the platform peripheral.
  void onWrite(Uint8List packet) {
    final message = _assembler.feed(packet);
    if (message != null) {
      _inbox.add(message);
    }
  }

  void onDisconnect() {
    _logger('BLE client disconnected; clearing pairing session');
    _assembler.reset();
    _plaintextBlocked = false;
    _pairing.reset();
    _events.add(const SetupEvent(SetupEventKind.clientDisconnected));
  }

  // -- Lifecycle ----------------------------------------------------------

  void start() {
    if (_running) return;
    _running = true;
    _events.add(const SetupEvent(SetupEventKind.started));
    _run();
  }

  Future<void> stop() async {
    _running = false;
    _inbox.add(null);
    await _rxTail;
  }

  void _run() {
    () async {
      await for (final message in _inbox.stream) {
        if (message == null || !_running) break;
        try {
          await _handleSerially(message);
        } catch (e) {
          _logger('setup command failed: $e');
        }
      }
    }();
  }

  Future<void> _handleSerially(Uint8List message) {
    final next = _rxTail.then((_) => handleMessage(message));
    _rxTail = next.then((_) {}, onError: (_) {});
    return next;
  }

  // -- Dispatch -----------------------------------------------------------

  Future<void> handleMessage(Uint8List raw, {bool decrypted = false}) async {
    Map<String, Object?> command;
    try {
      final decoded = json.decode(utf8.decode(raw));
      if (decoded is! Map) {
        throw const FormatException('not an object');
      }
      command = decoded.cast<String, Object?>();
    } on FormatException {
      _logger('invalid command JSON (${raw.length} bytes)');
      await sendStatus('error_invalid_command');
      return;
    }
    final actionValue = command['action'];
    final action = actionValue is String ? actionValue : '';
    _logger('RX action: ${action.isEmpty ? '?' : action}'
        '${decrypted ? ' (encrypted)' : ''}');

    if (!decrypted && action == 'pairing_client_hello') {
      await _handleHello(command);
    } else if (!decrypted && action == 'pairing_encrypted') {
      await _handleRecord(command);
    } else if (action == 'get_device_info') {
      // Public metadata, safe in plaintext at any point. Apps re-read it
      // when they restart a handshake on the same connection.
      await sendJson(deviceInfo());
    } else if (!decrypted && _plaintextBlocked) {
      _logger('plaintext command ignored after pairing started: $action');
    } else if (!decrypted && sensitiveActions.contains(action)) {
      await sendStatus('error_encryption_required');
    } else if (decrypted && action == 'pairing_client_finished') {
      await _handleClientFinished(command);
    } else if (decrypted &&
        sensitiveActions.contains(action) &&
        !_pairing.confirmed) {
      await sendStatus('error_pairing_confirm_required');
    } else if (decrypted && action == 'wifi_scan') {
      await _handleWifiScan();
    } else if (decrypted &&
        (action == 'provision_v2' || action == 'provision')) {
      await _handleProvision(command);
    } else {
      await sendStatus('error_unknown_action');
    }
  }

  Map<String, Object?> deviceInfo() => {
        'type': 'device_info',
        'node_id': _identity.nodeId,
        'version': _version,
        ..._pairing.deviceInfo(),
        'build_sha': '',
        // Network readiness is checked live during provisioning; the
        // static pre-check is best-effort and refreshes on each read.
        'network_ready': true,
      };

  Future<void> _handleHello(Map<String, Object?> command) async {
    Map<String, Object?> ready;
    try {
      ready = await _pairing.handleHello(command);
    } on PairingError catch (e) {
      await sendStatus(e.status);
      return;
    }
    _plaintextBlocked = true;
    _events.add(const SetupEvent(SetupEventKind.helloReceived));
    await sendJson(ready);
  }

  Future<void> _handleRecord(Map<String, Object?> envelope) async {
    String plaintext;
    try {
      plaintext = await _pairing.decrypt(envelope);
    } on PairingError catch (e) {
      await sendStatus(e.status);
      _transport.disconnect(disconnectAfterError);
      return;
    }
    await handleMessage(Uint8List.fromList(utf8.encode(plaintext)),
        decrypted: true);
  }

  Future<void> _handleClientFinished(Map<String, Object?> command) async {
    final generation = _pairing.handleClientFinished(command);
    if (generation == 0) {
      await sendStatus('error_pairing_decrypt');
      _transport.disconnect(disconnectAfterError);
      return;
    }
    _logger('pairing confirmed (app consent)');
    _events.add(const SetupEvent(SetupEventKind.pairingConfirmed));
    await sendStatus('pairing_confirmed', generation);
  }

  Future<void> _handleWifiScan() async {
    final online = await _network.isOnline();
    final networks =
        online ? [_network.currentConnectionEntry()] : <Map<String, Object?>>[];
    await sendEncryptedJson(
        {'type': 'wifi_scan_result', 'networks': networks});
  }

  Future<void> _handleProvision(Map<String, Object?> command) async {
    String text(String key) {
      final value = command[key];
      return value is String ? value : '';
    }

    // Only the tokens matter: the Wi-Fi fields are dropped below (this
    // device is already online), so absent ones must not fail setup.
    // Some apps omit them or send the v1 `provision` action instead.
    if (text('access_token').isEmpty ||
        text('refresh_token').isEmpty ||
        text('token_type') != 'device') {
      await sendStatus('error_missing_credentials');
      return;
    }
    if (_provisioning) {
      await sendStatus('error_operation_in_progress');
      return;
    }
    final generation = _pairing.markProvisioning();
    if (generation == 0) {
      await sendStatus('error_pairing_confirm_required');
      return;
    }
    _provisioning = true;
    // The Wi-Fi fields are deliberately dropped: this device only sets up
    // when it is already online.
    final credentials = Credentials(
      accessToken: text('access_token'),
      refreshToken: text('refresh_token'),
      username: text('username'),
      apiUrl: text('api_url'),
      apiUrlV2: text('api_url_v2'),
      noiseHost: text('noise_host'),
    );
    // Run off the command queue so status sends stay ordered.
    () async {
      try {
        await _runProvision(credentials, generation);
      } finally {
        _provisioning = false;
      }
    }();
  }

  Future<void> _runProvision(
      Credentials credentials, int generation) async {
    _events.add(const SetupEvent(SetupEventKind.provisioning));
    await sendStatus('wifi_connecting', generation);
    _events.add(const SetupEvent(SetupEventKind.wifiConnecting));
    if (!await _network.isOnline()) {
      // Stay in provisioning so the app can retry, as the firmware does.
      _pairing.extendProvisioning(generation);
      await sendStatus('wifi_failed', generation);
      _events.add(const SetupEvent(SetupEventKind.wifiFailed));
      return;
    }
    await sendStatus('wifi_connected', generation);
    _events.add(const SetupEvent(SetupEventKind.wifiConnected));

    Future<bool> commit(Future<bool> Function() save) =>
        _pairing.commitProvisioning(generation, save);

    try {
      await _provision(credentials, commit);
    } on ProvisionFailed catch (e) {
      _logger('provisioning failed: ${e.status}');
      _events.add(SetupEvent(SetupEventKind.failed, e.status));
      await sendStatus(e.status, generation);
      _transport.disconnect(const Duration(milliseconds: 500));
      return;
    }
    await sendStatus('auth_ok', generation);
    _logger('setup complete');
    _events.add(const SetupEvent(SetupEventKind.authOk));
    _onComplete?.call();
  }

  // -- Sending --------------------------------------------------------------

  Future<void> sendStatus(String status, [int generation = 0]) {
    return _sendSerially(() async {
      final envelope = await _pairing.encryptStatus(status, generation);
      if (envelope != null) {
        await _sendLocked(_compact(envelope));
        _logger('TX status (encrypted #${envelope['counter']}): $status');
        return;
      }
      if (generation != 0 || _plaintextBlocked || !plaintextStatuses.contains(status)) {
        _logger('TX status suppressed: $status');
        return;
      }
      await _transport.sendPackets([Uint8List.fromList(status.codeUnits)]);
      _logger('TX status: $status');
    });
  }

  Future<void> sendJson(Map<String, Object?> obj) {
    return _sendSerially(() async {
      await _sendLocked(_compact(obj));
      _logger('TX ${obj['type']}');
    });
  }

  Future<void> sendEncryptedJson(Map<String, Object?> obj,
      [int generation = 0]) {
    return _sendSerially(() async {
      final envelope = await _pairing.encryptJson(_compact(obj), generation);
      if (envelope == null) {
        _logger('TX ${obj['type']} suppressed: no session');
        return;
      }
      await _sendLocked(_compact(envelope));
      _logger('TX ${obj['type']} (encrypted #${envelope['counter']})');
    });
  }

  Future<void> _sendSerially(Future<void> Function() body) {
    final next = _txTail.then((_) => body());
    _txTail = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _sendLocked(String text) async {
    final packets =
        encodeChunks(Uint8List.fromList(utf8.encode(text)), _transport.mtu());
    await _transport.sendPackets(packets);
  }
}
