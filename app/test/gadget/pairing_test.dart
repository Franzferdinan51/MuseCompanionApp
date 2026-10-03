import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' hide CipherState;
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/p256.dart';
import 'package:muse_companion/src/gadget/pairing.dart';

Map<String, Map<String, Object?>> _loadVectors() {
  final file = File('test/testdata/link_pairing_v5.json');
  final decoded = json.decode(file.readAsStringSync()) as Map<String, Object?>;
  final vectors = decoded['vectors'] as List;
  final out = <String, Map<String, Object?>>{};
  for (final vector in vectors) {
    final map = (vector as Map).cast<String, Object?>();
    out[map['name'] as String] = map;
  }
  return out;
}

String _s(Map<String, Object?> v, String key) => v[key] as String;

Uint8List _hex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Fixed device key from a vector's device scalar and device_pub point.
P256KeyPair _deviceKey(Map<String, Object?> v) {
  final point = b64urlDecode(_s(v, 'device_pub'));
  return P256KeyPair(
    d: _hex(_s(v, 'device_private_scalar_hex')),
    x: point.sublist(1, 33),
    y: point.sublist(33, 65),
  );
}

void main() {
  final vectors = _loadVectors();

  group('pairing vectors', () {
    test('community confirm_app transcript matches', () {
      final v = vectors['community_app_v5']!;
      final transcript = buildTranscript(
        community: true,
        authEpoch: 0,
        policy: 'confirm_app',
        deviceId: _s(v, 'device_id'),
        nodeId: _s(v, 'node_id'),
        mac: _s(v, 'mac'),
        firmwareVersion: _s(v, 'firmware_version'),
        mobilePub: _s(v, 'mobile_pub'),
        devicePub: _s(v, 'device_pub'),
        mobileNonce: _s(v, 'mobile_nonce'),
        deviceNonce: _s(v, 'device_nonce'),
      );
      expect(transcript, _s(v, 'transcript'));
    });

    test('community confirm_press transcript matches', () {
      final v = vectors['community_v5']!;
      final transcript = buildTranscript(
        community: true,
        authEpoch: 0,
        policy: 'confirm_press',
        deviceId: _s(v, 'device_id'),
        nodeId: _s(v, 'node_id'),
        mac: _s(v, 'mac'),
        firmwareVersion: _s(v, 'firmware_version'),
        mobilePub: _s(v, 'mobile_pub'),
        devicePub: _s(v, 'device_pub'),
        mobileNonce: _s(v, 'mobile_nonce'),
        deviceNonce: _s(v, 'device_nonce'),
      );
      expect(transcript, _s(v, 'transcript'));
    });

    test('session keys and session id match', () async {
      final v = vectors['community_app_v5']!;
      final transcriptHash = b64urlDecode(_s(v, 'transcript_hash'));
      final keys = await deriveSessionKeys(
        _hex(_s(v, 'ecdh_secret_hex')),
        b64urlDecode(_s(v, 'mobile_nonce')),
        b64urlDecode(_s(v, 'device_nonce')),
        transcriptHash,
      );
      expect(
          keys.mobileTxKey,
          _hex(_s(v, 'mobile_tx_key_hex')),
          reason: 'mobile_tx_key');
      expect(
          keys.mobileRxKey,
          _hex(_s(v, 'mobile_rx_key_hex')),
          reason: 'mobile_rx_key');
      expect(b64urlEncode(keys.sessionId), _s(v, 'session_id'));
    });

    test('record aad matches', () {
      final v = vectors['community_app_v5']!;
      final aad = recordAad(_s(v, 'session_id'), 0, 0);
      expect(utf8.decode(aad), _s(v, 'client_finished_aad'));
    });

    test('full hello/decrypt/confirm replays the vector', () async {
      final v = vectors['community_app_v5']!;
      final session = PairingSession(
        nodeId: _s(v, 'node_id'),
        deviceId: _s(v, 'device_id'),
        mac: _s(v, 'mac'),
        firmwareVersion: _s(v, 'firmware_version'),
        generateKey: () async => _deviceKey(v),
        randomBytes: (_) => b64urlDecode(_s(v, 'device_nonce')),
      );

      final ready = await session.handleHello({
        'action': 'pairing_client_hello',
        'version': 5,
        'pairing_auth': 'none',
        'pairing_policy': 'confirm_app',
        'mobile_pub': _s(v, 'mobile_pub'),
        'mobile_nonce': _s(v, 'mobile_nonce'),
      });
      expect(ready['type'], 'pairing_ready');
      expect(ready['device_pub'], _s(v, 'device_pub'));
      expect(ready['device_nonce'], _s(v, 'device_nonce'));
      expect(ready['transcript_hash'], _s(v, 'transcript_hash'));
      expect(ready['session_id'], _s(v, 'session_id'));

      // The vector's sealed client_finished record opens.
      final plaintext = await session.decrypt({
        'action': 'pairing_encrypted',
        'session_id': _s(v, 'session_id'),
        'counter': '0',
        'ciphertext': _s(v, 'client_finished_ciphertext'),
        'tag': _s(v, 'client_finished_tag'),
      });
      expect(plaintext, _s(v, 'client_finished_plaintext'));

      final generation = session.handleClientFinished(
          {'action': 'pairing_client_finished'});
      expect(generation, isNonZero);
      expect(session.confirmed, isTrue);

      // Device-to-mobile records seal under the vector rx key: counter 0
      // decrypts with mobile_rx_key from the vector.
      final sealed =
          await session.encryptStatus('pairing_confirmed', generation);
      expect(sealed!['counter'], '0');
      final opened = await AesGcm.with256bits().decrypt(
        SecretBox(
          b64urlDecode(sealed['ciphertext']),
          nonce: recordNonce(1, 0),
          mac: Mac(b64urlDecode(sealed['tag'])),
        ),
        secretKey: SecretKey(_hex(_s(v, 'mobile_rx_key_hex'))),
        aad: recordAad(_s(v, 'session_id'), 1, 0),
      );
      expect(utf8.decode(opened), contains('pairing_confirmed'));
    });
  });

  group('pairing errors', () {
    PairingSession makeSession() => PairingSession(
          nodeId: 'homelink-abcdef',
          deviceId: 'hatch-link:02:aa:bb:cc:dd:ee',
          mac: '02:aa:bb:cc:dd:ee',
          firmwareVersion: '0.1.0',
        );

    // A well-formed hello with a fresh mobile key.
    Future<Map<String, Object?>> freshHello() async {
      final mobile = generateP256KeyPair();
      final point = Uint8List(65)
        ..[0] = 0x04
        ..setRange(1, 33, mobile.x)
        ..setRange(33, 65, mobile.y);
      return {
        'action': 'pairing_client_hello',
        'version': 5,
        'pairing_auth': 'none',
        'pairing_policy': 'confirm_app',
        'mobile_pub': b64urlEncode(point),
        'mobile_nonce': b64urlEncode(Uint8List.fromList(
            List.generate(16, (i) => i))),
      };
    }

    test('hello rejects wrong version, auth and policy', () async {
      for (final mutate in [
        (Map<String, Object?> m) => m['version'] = 4,
        (Map<String, Object?> m) => m['pairing_auth'] = 'fleet_ecdsa_p256_v1',
        (Map<String, Object?> m) => m['pairing_policy'] = 'confirm_press',
        (Map<String, Object?> m) => m['mobile_pub'] = '!!!',
        (Map<String, Object?> m) => m.remove('mobile_nonce'),
      ]) {
        final hello = await freshHello();
        mutate(hello);
        await expectLater(makeSession().handleHello(hello),
            throwsA(isA<PairingError>()));
      }
    });

    test('decrypt rejects wrong session, counter and tag', () async {
      Future<PairingSession> helloed() async {
        final session = makeSession();
        await session.handleHello(await freshHello());
        return session;
      }

      // Wrong session id.
      var session = await helloed();
      await expectLater(
          session.decrypt({
            'session_id': 'wrong',
            'counter': '0',
            'ciphertext': 'eA',
            'tag': b64urlEncode(Uint8List(16)),
          }),
          throwsA(isA<PairingError>()));
      expect(session.state, PairingState.idle);

      // Skipped counter.
      session = await helloed();
      await expectLater(
          session.decrypt({
            'session_id': (await session.handleHello(await freshHello()))[
                'session_id'],
            'counter': '1',
            'ciphertext': 'eA',
            'tag': b64urlEncode(Uint8List(16)),
          }),
          throwsA(isA<PairingError>()));

      // Bad tag length.
      session = await helloed();
      final ready = await session.handleHello(await freshHello());
      await expectLater(
          session.decrypt({
            'session_id': ready['session_id'],
            'counter': '0',
            'ciphertext': 'eA',
            'tag': 'eA',
          }),
          throwsA(isA<PairingError>()));
    });

    test('client finished requires the exact first record', () async {
      final session = makeSession();
      // No hello yet.
      expect(session.handleClientFinished(
          {'action': 'pairing_client_finished'}), 0);
      // Wrong shape after hello.
      await session.handleHello(await freshHello());
      expect(session.handleClientFinished({'action': 'nope'}), 0);
      expect(session.state, PairingState.idle);
    });

    test('provisioning generations gate commits', () async {
      final session = makeSession();
      expect(session.markProvisioning(), 0);
      expect(session.extendProvisioning(7), isFalse);
      expect(await session.commitProvisioning(7, () async => true), isFalse);
      // Stale generations cannot seal records.
      expect(await session.encryptJson('{}', 7), isNull);
    });

    test('sessions expire on the clock', () async {
      var now = 1000.0;
      final session = PairingSession(
        nodeId: 'homelink-abcdef',
        deviceId: 'hatch-link:02:aa:bb:cc:dd:ee',
        mac: '02:aa:bb:cc:dd:ee',
        firmwareVersion: '0.1.0',
        clock: () => now,
      );
      await session.handleHello(await freshHello());
      expect(session.state, PairingState.waitClientFinished);
      now += 61;
      expect(session.state, PairingState.idle);
      expect(await session.encryptJson('{}'), isNull);
    });
  });

  group('codec helpers', () {
    test('b64url round-trips without padding', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encoded = b64urlEncode(data);
      expect(encoded.contains('='), isFalse);
      expect(b64urlDecode(encoded), data);
    });

    test('b64url rejects bad input', () {
      for (final bad in ['a', '!!!', '', 'a b', null, 42]) {
        expect(() => b64urlDecode(bad), throwsFormatException);
      }
    });

    test('parseCounter accepts decimals only', () {
      expect(parseCounter('0'), 0);
      expect(parseCounter('42'), 42);
      for (final bad in ['-1', '1.5', 'x', '', null]) {
        expect(() => parseCounter(bad), throwsFormatException);
      }
    });
  });
}
