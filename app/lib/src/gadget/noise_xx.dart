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
// Dart port of the Muse Gadget SDK Noise XX handshake
// (linux/src/musegadget/noise/noise_xx.py).
//
// Cryptography runs through package:cryptography, so every operation that
// touches key material is async. Callers already run on async session loops.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Noise protocol name: XX handshake, X25519 DH, AES-GCM, SHA-256.
const String protocolName = 'Noise_XX_25519_AESGCM_SHA256';

const int dhKeyLen = 32;
const int aeadTagLen = 16;
const int minMsg2Len = dhKeyLen + (dhKeyLen + aeadTagLen) + aeadTagLen;
const int minMsg3Len = dhKeyLen + aeadTagLen + aeadTagLen;

/// Nonces stay exactly representable past this point; never use one beyond it.
const int maxSafeNonce = (1 << 53) - 1;

/// Thrown when a Noise handshake or transport state machine is violated.
class NoiseProtocolError extends Error {
  NoiseProtocolError(this.message);
  final String message;
  @override
  String toString() => 'NoiseProtocolError: $message';
}

/// X25519 public keys that must never complete a DH (RFC 7748 consensus).
const List<List<int>> _lowOrderPoints = [
  [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  ],
  [
    1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  ],
  [
    0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae,
    0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f, 0xc4, 0x6a,
    0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd,
    0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00, //
  ],
  [
    0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24,
    0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83, 0xef, 0x5b,
    0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86,
    0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57, //
  ],
  [
    0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, //
  ],
  [
    0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, //
  ],
  [
    0xee, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, //
  ],
];

final Uint8List _allZeros32 = Uint8List(32);

final Sha256 _sha256 = Sha256();
final Hmac _hmacSha256 = Hmac.sha256();
final AesGcm _aesGcm = AesGcm.with256bits();
final X25519 _x25519 = X25519();

Future<Uint8List> sha256Bytes(Uint8List data) async {
  final digest = await _sha256.hash(data);
  return Uint8List.fromList(digest.bytes);
}

Future<Uint8List> hmacSha256(Uint8List key, Uint8List data) async {
  final mac =
      await _hmacSha256.calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

Uint8List _concat(List<int> a, List<int> b) {
  final out = Uint8List(a.length + b.length);
  out.setRange(0, a.length, a);
  out.setRange(a.length, out.length, b);
  return out;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Noise HKDF: temp = HMAC(ck, ikm); out1 = HMAC(temp, 0x01); ...
Future<(Uint8List, Uint8List)> noiseHkdf(
    Uint8List chainingKey, Uint8List inputKeyMaterial) async {
  final tempKey = await hmacSha256(chainingKey, inputKeyMaterial);
  final output1 = await hmacSha256(tempKey, Uint8List.fromList([1]));
  final output2 =
      await hmacSha256(tempKey, _concat(output1, Uint8List.fromList([2])));
  return (output1, output2);
}

/// 12-byte AES-GCM nonce: four zero bytes plus the big-endian counter.
Uint8List buildNonceIv(int nonce) {
  if (nonce < 0 || nonce > 0xffffffffffffffff) {
    throw NoiseProtocolError('nonce outside uint64 range');
  }
  final iv = Uint8List(12);
  final view = ByteData.sublistView(iv);
  view.setUint32(0, 0);
  // setUint64 would throw for values above 2^63-1 on the VM; split it.
  view.setUint32(4, (nonce >> 32) & 0xffffffff);
  view.setUint32(8, nonce & 0xffffffff);
  return iv;
}

/// Serializes async critical sections (Dart has no thread locks).
class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() body) {
    final next = _tail.then((_) => body());
    // Keep the chain alive even if this body throws.
    _tail = next.then((_) {}, onError: (_) {});
    return next;
  }
}

/// Noise CipherState over AES-256-GCM.
class CipherState {
  SecretKey? _key;
  bool _keyed = false;
  int _nonce = 0;
  bool _poisoned = false;
  final _Mutex _mutex = _Mutex();

  void _assertAlive() {
    if (_poisoned) {
      throw NoiseProtocolError('CipherState: poisoned after prior failure');
    }
  }

  void initializeKey(Uint8List key) {
    _assertAlive();
    if (key.length != 32) {
      throw NoiseProtocolError('CipherState: AES-GCM key must be 32 bytes');
    }
    _key = SecretKey(Uint8List.fromList(key));
    _keyed = true;
    _nonce = 0;
  }

  bool hasKey() => _keyed;

  Future<Uint8List> encryptWithAd(Uint8List ad, Uint8List plaintext) {
    return _mutex.run(() => _doEncrypt(ad, plaintext));
  }

  Future<Uint8List> decryptWithAd(Uint8List ad, Uint8List ciphertext) {
    return _mutex.run(() => _doDecrypt(ad, ciphertext));
  }

  int _nextNonce() {
    if (_nonce >= maxSafeNonce) {
      _poisoned = true;
      throw NoiseProtocolError('CipherState: nonce exhausted');
    }
    final current = _nonce;
    _nonce += 1;
    return current;
  }

  Future<Uint8List> _doEncrypt(Uint8List ad, Uint8List plaintext) async {
    _assertAlive();
    if (!_keyed) {
      return Uint8List.fromList(plaintext);
    }
    final nonce = _nextNonce();
    try {
      final box = await _aesGcm.encrypt(
        plaintext,
        secretKey: _key!,
        nonce: buildNonceIv(nonce),
        aad: ad,
      );
      return _concat(box.cipherText, box.mac.bytes);
    } catch (_) {
      _poisoned = true;
      rethrow;
    }
  }

  Future<Uint8List> _doDecrypt(Uint8List ad, Uint8List ciphertext) async {
    _assertAlive();
    if (!_keyed) {
      return Uint8List.fromList(ciphertext);
    }
    if (ciphertext.length < aeadTagLen) {
      _poisoned = true;
      throw NoiseProtocolError('CipherState: decrypt failed');
    }
    final nonce = _nextNonce();
    try {
      final box = SecretBox(
        ciphertext.sublist(0, ciphertext.length - aeadTagLen),
        nonce: buildNonceIv(nonce),
        mac: Mac(ciphertext.sublist(ciphertext.length - aeadTagLen)),
      );
      final plain =
          await _aesGcm.decrypt(box, secretKey: _key!, aad: ad);
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError catch (e) {
      _poisoned = true;
      throw NoiseProtocolError('CipherState: decrypt failed: $e');
    } catch (_) {
      _poisoned = true;
      rethrow;
    }
  }
}

class NoiseKeyPair {
  NoiseKeyPair(this.keyPair, this.publicKeyBytes);
  final SimpleKeyPair keyPair;
  final Uint8List publicKeyBytes;
}

/// Creates X25519 key pairs; injectable so tests can replay fixed handshakes.
typedef X25519KeyPairFactory = Future<NoiseKeyPair> Function();

Future<NoiseKeyPair> _defaultKeyPairFactory() async {
  final keyPair = await _x25519.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  return NoiseKeyPair(keyPair, Uint8List.fromList(publicKey.bytes));
}

/// Build a key pair from known raw bytes (tests only).
Future<NoiseKeyPair> fixedX25519KeyPair(
    Uint8List privateBytes, Uint8List publicBytes) async {
  final keyPair = SimpleKeyPairData(
    privateBytes,
    publicKey:
        SimplePublicKey(publicBytes, type: KeyPairType.x25519),
    type: KeyPairType.x25519,
  );
  return NoiseKeyPair(keyPair, Uint8List.fromList(publicBytes));
}

Future<Uint8List> _x25519Dh(
    SimpleKeyPair privateKey, Uint8List publicKeyBytes) async {
  if (publicKeyBytes.length != dhKeyLen) {
    throw NoiseProtocolError('x25519: invalid public key length');
  }
  for (final lowOrder in _lowOrderPoints) {
    if (_constantTimeEquals(publicKeyBytes, lowOrder)) {
      throw NoiseProtocolError('x25519: rejected low-order public key');
    }
  }
  final remote =
      SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519);
  final shared = await _x25519.sharedSecretKey(
      keyPair: privateKey, remotePublicKey: remote);
  final sharedBytes = Uint8List.fromList(await shared.extractBytes());
  if (_constantTimeEquals(sharedBytes, _allZeros32)) {
    throw NoiseProtocolError('x25519: DH produced all-zeros output');
  }
  return sharedBytes;
}

class _SymmetricState {
  Uint8List _ck = Uint8List(32);
  Uint8List _h = Uint8List(32);
  CipherState _cipher = CipherState();

  Future<void> initialize() async {
    final padded = Uint8List(32);
    final name = Uint8List.fromList(protocolName.codeUnits);
    padded.setRange(0, name.length, name);
    _h = padded;
    _ck = Uint8List.fromList(_h);
    await mixHash(Uint8List(0));
  }

  Future<void> mixHash(Uint8List data) async {
    _h = await sha256Bytes(_concat(_h, data));
  }

  Future<void> mixKey(Uint8List inputKeyMaterial) async {
    final (ck, tempK) = await noiseHkdf(_ck, inputKeyMaterial);
    _ck = ck;
    _cipher = CipherState();
    _cipher.initializeKey(tempK);
  }

  Future<Uint8List> encryptAndHash(Uint8List plaintext) async {
    final ciphertext = await _cipher.encryptWithAd(_h, plaintext);
    await mixHash(ciphertext);
    return ciphertext;
  }

  Future<Uint8List> decryptAndHash(Uint8List ciphertext) async {
    final plaintext = await _cipher.decryptWithAd(_h, ciphertext);
    await mixHash(ciphertext);
    return plaintext;
  }

  Future<(CipherState, CipherState)> split() async {
    final (tempK1, tempK2) = await noiseHkdf(_ck, Uint8List(0));
    _ck = Uint8List(32);
    _h = Uint8List(32);
    final c1 = CipherState();
    c1.initializeKey(tempK1);
    final c2 = CipherState();
    c2.initializeKey(tempK2);
    return (c1, c2);
  }

  Uint8List handshakeHash() => Uint8List.fromList(_h);
}

enum _Phase { created, initialized, msg1Sent, msg2Read, msg3Sent, split, dead }

/// Noise XX initiator (the gadget side of the VM session handshake).
class NoiseXXInitiator {
  NoiseXXInitiator({X25519KeyPairFactory? keyPairFactory})
      : _keyPairFactory = keyPairFactory ?? _defaultKeyPairFactory;

  final X25519KeyPairFactory _keyPairFactory;
  final _SymmetricState _ss = _SymmetricState();
  NoiseKeyPair? _e;
  NoiseKeyPair? _s;
  Uint8List? _re;
  Uint8List? _rs;
  _Phase _phase = _Phase.created;

  void _requirePhase(_Phase expected, String method) {
    if (_phase == _Phase.dead) {
      throw NoiseProtocolError('NoiseXX: $method called on dead handshake');
    }
    if (_phase != expected) {
      throw NoiseProtocolError(
          'NoiseXX: $method called in wrong phase '
          '(expected $expected, got $_phase)');
    }
  }

  Future<void> initialize() async {
    _requirePhase(_Phase.created, 'initialize');
    await _ss.initialize();
    _phase = _Phase.initialized;
  }

  /// Message 1: ephemeral public key.
  Future<Uint8List> writeMessage1() async {
    _requirePhase(_Phase.initialized, 'writeMessage1');
    try {
      _e = await _keyPairFactory();
      await _ss.mixHash(_e!.publicKeyBytes);
      await _ss.encryptAndHash(Uint8List(0));
      _phase = _Phase.msg1Sent;
      return Uint8List.fromList(_e!.publicKeyBytes);
    } catch (_) {
      _phase = _Phase.dead;
      rethrow;
    }
  }

  /// Message 2 from the responder; returns the decrypted payload.
  Future<Uint8List> readMessage2(Uint8List msg) async {
    _requirePhase(_Phase.msg1Sent, 'readMessage2');
    if (msg.length < minMsg2Len) {
      _phase = _Phase.dead;
      throw NoiseProtocolError(
          'NoiseXX: message 2 too short (${msg.length} < $minMsg2Len)');
    }
    try {
      var offset = 0;
      _re = msg.sublist(offset, offset + dhKeyLen);
      await _ss.mixHash(_re!);
      offset += dhKeyLen;

      final e = _e;
      if (e == null) {
        throw NoiseProtocolError('NoiseXX: missing initiator ephemeral key');
      }
      final ee = await _x25519Dh(e.keyPair, _re!);
      await _ss.mixKey(ee);

      _rs = await _ss.decryptAndHash(
          msg.sublist(offset, offset + dhKeyLen + aeadTagLen));
      offset += dhKeyLen + aeadTagLen;

      final es = await _x25519Dh(e.keyPair, _rs!);
      await _ss.mixKey(es);

      final payload = await _ss.decryptAndHash(msg.sublist(offset));
      _phase = _Phase.msg2Read;
      return payload;
    } catch (_) {
      _phase = _Phase.dead;
      rethrow;
    }
  }

  /// Message 3: encrypted static key plus empty payload.
  Future<Uint8List> writeMessage3() async {
    _requirePhase(_Phase.msg2Read, 'writeMessage3');
    try {
      _s = await _keyPairFactory();
      final encS = await _ss.encryptAndHash(_s!.publicKeyBytes);

      final re = _re;
      if (re == null) {
        throw NoiseProtocolError('NoiseXX: missing responder ephemeral key');
      }
      final se = await _x25519Dh(_s!.keyPair, re);
      await _ss.mixKey(se);

      final encPayload = await _ss.encryptAndHash(Uint8List(0));
      _phase = _Phase.msg3Sent;
      return _concat(encS, encPayload);
    } catch (_) {
      _phase = _Phase.dead;
      rethrow;
    }
  }

  /// Split into (send, receive) transport ciphers.
  Future<(CipherState, CipherState)> split() async {
    _requirePhase(_Phase.msg3Sent, 'split');
    _phase = _Phase.split;
    final result = await _ss.split();
    _e = null;
    _s = null;
    _re = null;
    _rs = null;
    return result;
  }
}
