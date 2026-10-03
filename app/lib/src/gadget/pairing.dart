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
// Dart port of the Muse Gadget SDK BLE pairing
// (linux/src/musegadget/pairing.py).
//
// Device side of Muse Gadget BLE pairing, protocol version 5. Community
// mode only: `pairing_auth` is "none" and the policy is `confirm_app`, so a
// valid client-finished record confirms the session without a physical
// button. The wire format, transcript, key schedule and record encryption
// match the reference firmware so the existing Muse apps pair unchanged.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'noise_xx.dart' show hmacSha256, sha256Bytes;
import 'p256.dart';

const int pairingVersion = 5;
const String pairingModel = 'hatch_link';
const String pairingSuite = 'p256-hkdf-sha256-aes-gcm-v1';
const String policyButton = 'confirm_press';
const String policyApp = 'confirm_app';
const String authOfficial = 'fleet_ecdsa_p256_v1';
const String authCommunity = 'none';
const int buttonConfirmTimeoutS = 60;

const String recordLabel = 'hatch-link ble setup v1';
const String sessionIdLabel = 'hatch-link session id v1';

const Duration clientFinishedTimeout = Duration(seconds: 60);
const Duration confirmedTimeout = Duration(seconds: 120);
const Duration provisioningTimeout = Duration(seconds: 120);

const String errorInvalidHello = 'error_pairing_invalid_hello';
const String errorDecrypt = 'error_pairing_decrypt';

const int _p256PointBytes = 65;
const int _nonceBytes = 16;
const int _sessionIdBytes = 16;
const int _tagBytes = 16;
const int _maxB64Chars = 4096;
const int _maxCiphertextB64Chars = 16384;
const int _toDevice = 0;
const int _fromDevice = 1;

final RegExp _b64urlRe = RegExp(r'[A-Za-z0-9_-]+');
final RegExp _decimalRe = RegExp(r'[0-9]+');

final AesGcm _aesGcm = AesGcm.with256bits();
final Random _secureRandom = Random.secure();

/// A handshake step failed; [status] is the wire error to report.
class PairingError extends Error {
  PairingError(this.status);
  final String status;
  @override
  String toString() => 'PairingError: $status';
}

enum PairingState { idle, waitClientFinished, ready, provisioning }

/// Seconds on a monotonic clock; injectable for tests.
typedef MonotonicClock = double Function();

double _defaultClock() =>
    DateTime.now().microsecondsSinceEpoch / Duration.microsecondsPerSecond;

String b64urlEncode(Uint8List data) {
  var out = base64Url.encode(data);
  while (out.endsWith('=')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// Decode unpadded base64url, rejecting anything the firmware rejects.
Uint8List b64urlDecode(Object? text, [int maxChars = _maxB64Chars]) {
  if (text is! String || text.isEmpty || text.length > maxChars) {
    throw FormatException('invalid base64url length');
  }
  if (text.length % 4 == 1 || _b64urlRe.matchAsPrefix(text)?.end != text.length) {
    throw FormatException('invalid base64url');
  }
  final padded = text + '=' * ((-text.length) % 4);
  return Uint8List.fromList(base64Url.decode(padded));
}

int parseCounter(Object? text) {
  if (text is! String || _decimalRe.matchAsPrefix(text)?.end != text.length) {
    throw FormatException('invalid counter');
  }
  final value = int.tryParse(text);
  if (value == null) {
    throw FormatException('counter overflow');
  }
  return value;
}

/// Canonical v5 transcript; SHA-256 of it is the `transcript_hash`.
String buildTranscript({
  required bool community,
  required int authEpoch,
  required String policy,
  required String deviceId,
  required String nodeId,
  required String mac,
  required String firmwareVersion,
  required String mobilePub,
  required String devicePub,
  required String mobileNonce,
  required String deviceNonce,
}) {
  final button = policy == policyButton;
  if (!(button || (community && policy == policyApp))) {
    throw ArgumentError('unsupported pairing policy: $policy');
  }
  if (community ? authEpoch != 0 : authEpoch <= 0) {
    throw ArgumentError('invalid auth epoch: $authEpoch');
  }
  final fields = [
    deviceId, nodeId, mac, firmwareVersion,
    mobilePub, devicePub, mobileNonce, deviceNonce,
  ];
  if (fields.any((f) => f.isEmpty)) {
    throw ArgumentError('transcript fields must be non-empty');
  }
  return [
    'hatch-link-pairing-v$pairingVersion',
    'version=$pairingVersion',
    'initiator_role=mobile',
    'responder_role=link',
    'device_id=$deviceId',
    'node_id=$nodeId',
    'mac=$mac',
    'model=$pairingModel',
    'firmware_version=$firmwareVersion',
    'selected_cipher_suite=$pairingSuite',
    'pairing_auth=${community ? authCommunity : authOfficial}',
    'pairing_auth_epoch=$authEpoch',
    'pairing_policy=$policy',
    'confirm_timeout_seconds=${button ? buttonConfirmTimeoutS : 0}',
    'mobile_pub=$mobilePub',
    'device_pub=$devicePub',
    'mobile_nonce=$mobileNonce',
    'device_nonce=$deviceNonce',
  ].join('\n');
}

class SessionKeys {
  const SessionKeys({
    required this.mobileTxKey,
    required this.mobileRxKey,
    required this.sessionId,
  });

  /// Decrypts records the device receives.
  final Uint8List mobileTxKey;

  /// Encrypts records the device sends.
  final Uint8List mobileRxKey;
  final Uint8List sessionId;
}

Future<Uint8List> _hkdfExpand(
    Uint8List prk, Uint8List info, int length) async {
  final out = BytesBuilder();
  var previous = Uint8List(0);
  var counter = 1;
  while (out.length < length) {
    final input = BytesBuilder()
      ..add(previous)
      ..add(info)
      ..addByte(counter);
    previous = await hmacSha256(prk, input.toBytes());
    out.add(previous);
    counter += 1;
  }
  final bytes = out.toBytes();
  return bytes.sublist(0, length);
}

/// Derive `(mobileTxKey, mobileRxKey, sessionId)` from the ECDH secret.
Future<SessionKeys> deriveSessionKeys(
  Uint8List ecdhSecret,
  Uint8List mobileNonce,
  Uint8List deviceNonce,
  Uint8List transcriptHash,
) async {
  final saltInput = BytesBuilder()
    ..add(mobileNonce)
    ..add(deviceNonce)
    ..add(transcriptHash);
  final salt = await sha256Bytes(saltInput.toBytes());
  // HKDF-Extract(salt, ikm): PRK = HMAC(salt, ikm).
  final prk = await hmacSha256(salt, ecdhSecret);
  // The reference runs full HKDF here (extract then expand with the
  // record label), and expands the result again per direction below.
  final sessionSecret = await _hkdfExpand(
      prk, Uint8List.fromList(recordLabel.codeUnits), 32);
  final mobileTx = await _hkdfExpand(
      sessionSecret, Uint8List.fromList('mobile->device'.codeUnits), 32);
  final mobileRx = await _hkdfExpand(
      sessionSecret, Uint8List.fromList('device->mobile'.codeUnits), 32);
  final sessionIdInput = BytesBuilder()
    ..add(Uint8List.fromList(sessionIdLabel.codeUnits))
    ..add(transcriptHash)
    ..add(ecdhSecret);
  final sessionId =
      (await sha256Bytes(sessionIdInput.toBytes())).sublist(0, _sessionIdBytes);
  return SessionKeys(
      mobileTxKey: mobileTx, mobileRxKey: mobileRx, sessionId: sessionId);
}

Uint8List recordNonce(int direction, int counter) {
  final nonce = Uint8List(12);
  final view = ByteData.sublistView(nonce);
  nonce[0] = direction;
  view.setUint64(4, counter, Endian.big);
  return nonce;
}

Uint8List recordAad(String sessionIdB64, int direction, int counter) {
  final arrow = direction == _toDevice ? 'm2d' : 'd2m';
  return Uint8List.fromList(
      '$recordLabel|$sessionIdB64|$arrow|$counter'.codeUnits);
}

/// Generates device P-256 keys; injectable so tests can replay fixed sessions.
typedef DeviceKeyFactory = Future<P256KeyPair> Function();

Future<P256KeyPair> _defaultDeviceKeyFactory() async =>
    generateP256KeyPair();

typedef RandomBytes = Uint8List Function(int length);

Uint8List _defaultRandomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

/// One device's pairing state.
///
/// Methods that advance the handshake return a nonzero *generation* token.
/// Deferred work (provisioning) holds it and checks [isCurrent] before
/// acting, so work from an abandoned attempt can't act on a newer one.
class PairingSession {
  PairingSession({
    required String nodeId,
    required String deviceId,
    required String mac,
    required String firmwareVersion,
    String? sdkToken,
    MonotonicClock clock = _defaultClock,
    DeviceKeyFactory generateKey = _defaultDeviceKeyFactory,
    RandomBytes randomBytes = _defaultRandomBytes,
  })  : _nodeId = nodeId,
        _deviceId = deviceId,
        _mac = mac,
        _firmwareVersion =
            firmwareVersion.isEmpty ? 'unknown' : firmwareVersion,
        _sdkToken = sdkToken,
        _clock = clock,
        _generateKey = generateKey,
        _randomBytes = randomBytes;

  final String _nodeId;
  final String _deviceId;
  final String _mac;
  final String _firmwareVersion;
  final String? _sdkToken;
  final MonotonicClock _clock;
  final DeviceKeyFactory _generateKey;
  final RandomBytes _randomBytes;

  int _generation = 0;
  PairingState _state = PairingState.idle;
  double _deadline = 0;
  SecretKey? _rx;
  SecretKey? _tx;
  String _sessionIdB64 = '';
  int _rxCounter = 0;
  int _txCounter = 0;

  /// Pairing fields for the `get_device_info` response.
  Map<String, Object?> deviceInfo() => {
        'device_id': _deviceId,
        'mac': _mac,
        'model': pairingModel,
        'pairing_protocol': pairingVersion,
        'pairing_auth': authCommunity,
        'pairing_auth_epoch': 0,
        'pairing_policy': policyApp,
      };

  PairingState get state {
    _expireLocked();
    return _state;
  }

  bool get confirmed =>
      state == PairingState.ready || state == PairingState.provisioning;

  bool isCurrent(int generation) =>
      generation != 0 && generation == _generation;

  void reset() => _resetLocked();

  /// Start a session from `pairing_client_hello`; returns `pairing_ready`.
  Future<Map<String, Object?>> handleHello(Map<String, Object?> message) async {
    final version = message['version'];
    if (version is bool ||
        version is! num ||
        version != pairingVersion ||
        message['pairing_auth'] != authCommunity ||
        message['pairing_policy'] != policyApp) {
      throw PairingError(errorInvalidHello);
    }

    _resetLocked();
    late Uint8List mobilePub;
    late Uint8List mobileNonce;
    try {
      mobilePub = b64urlDecode(message['mobile_pub']);
      mobileNonce = b64urlDecode(message['mobile_nonce']);
      if (mobilePub.length != _p256PointBytes ||
          mobilePub[0] != 0x04 ||
          mobileNonce.length != _nonceBytes ||
          !p256IsOnCurve(
              mobilePub.sublist(1, 33), mobilePub.sublist(33, 65))) {
        throw const FormatException('invalid hello key material');
      }
    } on FormatException {
      _resetLocked();
      throw PairingError(errorInvalidHello);
    }

    final deviceKey = await _generateKey();
    final devicePub = _uncompressedPoint(deviceKey);
    final deviceNonce = _randomBytes(_nonceBytes);
    final transcript = buildTranscript(
      community: true,
      authEpoch: 0,
      policy: policyApp,
      deviceId: _deviceId,
      nodeId: _nodeId,
      mac: _mac,
      firmwareVersion: _firmwareVersion,
      mobilePub: b64urlEncode(mobilePub),
      devicePub: b64urlEncode(devicePub),
      mobileNonce: b64urlEncode(mobileNonce),
      deviceNonce: b64urlEncode(deviceNonce),
    );
    final transcriptHash =
        await sha256Bytes(Uint8List.fromList(transcript.codeUnits));
    late Uint8List ecdhSecret;
    try {
      ecdhSecret = p256Ecdh(deviceKey.d, mobilePub.sublist(1, 33),
          mobilePub.sublist(33, 65));
    } on ArgumentError {
      _resetLocked();
      throw PairingError(errorInvalidHello);
    }
    final keys = await deriveSessionKeys(
        ecdhSecret, mobileNonce, deviceNonce, transcriptHash);

    _rx = SecretKey(keys.mobileTxKey);
    _tx = SecretKey(keys.mobileRxKey);
    _sessionIdB64 = b64urlEncode(keys.sessionId);
    _rxCounter = 0;
    _txCounter = 0;
    _state = PairingState.waitClientFinished;
    _deadline = _clock() + clientFinishedTimeout.inSeconds;
    return {
      'type': 'pairing_ready',
      'version': pairingVersion,
      'device_id': _deviceId,
      'node_id': _nodeId,
      'mac': _mac,
      'model': pairingModel,
      'firmware_version': _firmwareVersion,
      'pairing_auth': authCommunity,
      'pairing_auth_epoch': 0,
      'pairing_policy': policyApp,
      'device_pub': b64urlEncode(devicePub),
      'device_nonce': b64urlEncode(deviceNonce),
      'transcript_hash': b64urlEncode(transcriptHash),
      'session_id': _sessionIdB64,
    };
  }

  /// Open one mobile-to-device `pairing_encrypted` record.
  ///
  /// Any failure clears the session, as the firmware does.
  Future<String> decrypt(Map<String, Object?> envelope) async {
    if (_expireLocked() || _state == PairingState.idle) {
      _resetLocked();
      throw PairingError(errorDecrypt);
    }
    late String plaintext;
    try {
      if (envelope['session_id'] != _sessionIdB64) {
        throw const FormatException('wrong session');
      }
      final counter = parseCounter(envelope['counter']);
      if (counter != _rxCounter) {
        throw const FormatException('unexpected counter');
      }
      final ciphertext =
          b64urlDecode(envelope['ciphertext'], _maxCiphertextB64Chars);
      final tag = b64urlDecode(envelope['tag']);
      if (tag.length != _tagBytes) {
        throw const FormatException('invalid tag length');
      }
      final box = SecretBox(
        ciphertext,
        nonce: recordNonce(_toDevice, counter),
        mac: Mac(tag),
      );
      final plain = await _aesGcm.decrypt(
        box,
        secretKey: _rx!,
        aad: recordAad(_sessionIdB64, _toDevice, counter),
      );
      plaintext = utf8.decode(plain);
    } on FormatException {
      _resetLocked();
      throw PairingError(errorDecrypt);
    } on SecretBoxAuthenticationError {
      _resetLocked();
      throw PairingError(errorDecrypt);
    }
    _rxCounter += 1;
    return plaintext;
  }

  /// Confirm the session after the first decrypted record.
  ///
  /// [command] must be exactly `{"action": "pairing_client_finished"}` and
  /// must have been the first record. Returns the new generation, or 0
  /// (after clearing the session) if the record is invalid.
  int handleClientFinished(Map<String, Object?> command) {
    final ok = command.length == 1 &&
        command['action'] == 'pairing_client_finished' &&
        !_expireLocked() &&
        _state == PairingState.waitClientFinished &&
        _rxCounter == 1;
    if (!ok) {
      _resetLocked();
      return 0;
    }
    _advanceGenerationLocked();
    _state = PairingState.ready;
    _deadline = _clock() + confirmedTimeout.inSeconds;
    return _generation;
  }

  /// Enter provisioning from a confirmed session; returns its generation.
  int markProvisioning() {
    if (!_expireLocked() && _state == PairingState.ready) {
      _advanceGenerationLocked();
      _state = PairingState.provisioning;
      _deadline = _clock() + provisioningTimeout.inSeconds;
    }
    if (_state == PairingState.provisioning) {
      return _generation;
    }
    return 0;
  }

  bool extendProvisioning(int generation) {
    final valid = _provisioningLocked(generation);
    if (valid) {
      _deadline = _clock() + provisioningTimeout.inSeconds;
    }
    return valid;
  }

  /// Run [commit] if the provisioning session is still valid.
  ///
  /// [commit] must only persist local state; no network or BLE calls.
  Future<bool> commitProvisioning(
      int generation, Future<bool> Function() commit) async {
    if (!_provisioningLocked(generation)) return false;
    return commit();
  }

  /// Seal a device-to-mobile record; null when there is no active session
  /// or a nonzero [generation] no longer matches.
  Future<Map<String, Object?>?> encryptJson(String plaintext,
      [int generation = 0]) async {
    if ((generation != 0 && generation != _generation) ||
        _expireLocked() ||
        _state == PairingState.idle) {
      return null;
    }
    final counter = _txCounter;
    final sealed = await _aesGcm.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
      secretKey: _tx!,
      nonce: recordNonce(_fromDevice, counter),
      aad: recordAad(_sessionIdB64, _fromDevice, counter),
    );
    _txCounter += 1;
    final cipherBytes = Uint8List.fromList(sealed.cipherText);
    final tagBytes = Uint8List.fromList(sealed.mac.bytes);
    return {
      'type': 'pairing_encrypted',
      'session_id': _sessionIdB64,
      'counter': counter.toString(),
      'ciphertext': b64urlEncode(cipherBytes),
      'tag': b64urlEncode(tagBytes),
    };
  }

  Future<Map<String, Object?>?> encryptStatus(String status,
      [int generation = 0]) async {
    final message = <String, Object?>{'type': 'status', 'status': status};
    // Apps read only type and status, so older ones ignore the token.
    if (_sdkToken != null &&
        _sdkToken.isNotEmpty &&
        status == 'pairing_confirmed') {
      message['sdk_token'] = _sdkToken;
    }
    return encryptJson(json.encode(message), generation);
  }

  bool _provisioningLocked(int generation) {
    return generation != 0 &&
        generation == _generation &&
        !_expireLocked() &&
        _state == PairingState.provisioning;
  }

  void _advanceGenerationLocked() {
    _generation += 1;
  }

  void _resetLocked() {
    _advanceGenerationLocked();
    _clearLocked();
  }

  void _clearLocked() {
    _state = PairingState.idle;
    _deadline = 0;
    _rx = null;
    _tx = null;
    _sessionIdB64 = '';
    _rxCounter = 0;
    _txCounter = 0;
  }

  bool _expireLocked() {
    if (_state == PairingState.idle || _clock() <= _deadline) {
      return false;
    }
    // Drop the keys but keep the generation, so the owner of the expired
    // session can still recognise it and close the connection.
    _clearLocked();
    return true;
  }
}

Uint8List _uncompressedPoint(P256KeyPair keyPair) {
  final out = Uint8List(65);
  out[0] = 0x04;
  // Left-pad coordinates that omit leading zero bytes.
  final x = _coordinate32(keyPair.x);
  final y = _coordinate32(keyPair.y);
  out.setRange(1, 33, x);
  out.setRange(33, 65, y);
  return out;
}

Uint8List _coordinate32(List<int> coordinate) {
  final bytes = Uint8List.fromList(coordinate);
  if (bytes.length == 32) return bytes;
  if (bytes.length > 32) return bytes.sublist(bytes.length - 32);
  final padded = Uint8List(32);
  padded.setRange(32 - bytes.length, 32, bytes);
  return padded;
}
