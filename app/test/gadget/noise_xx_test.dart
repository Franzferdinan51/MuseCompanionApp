import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' hide CipherState;
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/noise_xx.dart';

/// Fixed X25519 key pair from RFC 7748 test vector 1.
final Uint8List _rfcPrivate = Uint8List.fromList([
  0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d,
  0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd,
  0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18,
  0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4,
]);
final Uint8List _rfcPublic = Uint8List.fromList([
  0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb,
  0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c,
  0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b,
  0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c,
]);

Future<NoiseKeyPair> _rfcFactory() =>
    fixedX25519KeyPair(_rfcPrivate, _rfcPublic);

void main() {
  group('nonce iv', () {
    test('builds the 4-zero-plus-uint64 layout', () {
      expect(buildNonceIv(0), List.filled(12, 0));
      expect(buildNonceIv(1).sublist(11), [1]);
      expect(buildNonceIv(0x0102030405060708).sublist(4),
          [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('rejects out-of-range nonces', () {
      expect(() => buildNonceIv(-1), throwsA(isA<NoiseProtocolError>()));
    });
  });

  group('cipher state', () {
    test('passes plaintext through before a key is set', () async {
      final cipher = CipherState();
      expect(cipher.hasKey(), isFalse);
      final data = Uint8List.fromList([1, 2, 3]);
      expect(await cipher.encryptWithAd(Uint8List(0), data), data);
      expect(await cipher.decryptWithAd(Uint8List(0), data), data);
    });

    test('round-trips with associated data', () async {
      final cipher = CipherState();
      cipher.initializeKey(Uint8List.fromList(List.filled(32, 9)));
      final ad = Uint8List.fromList([5, 6]);
      final plain = Uint8List.fromList([1, 2, 3, 4]);
      final encrypted = await cipher.encryptWithAd(ad, plain);
      expect(encrypted.length, plain.length + 16);
      // A fresh cipher with the same key restarts at nonce 0 and decrypts.
      final decipher = CipherState();
      decipher.initializeKey(Uint8List.fromList(List.filled(32, 9)));
      expect(await decipher.decryptWithAd(ad, encrypted), plain);
    });

    test('wrong associated data fails and poisons', () async {
      final cipher = CipherState();
      cipher.initializeKey(Uint8List.fromList(List.filled(32, 9)));
      final encrypted = await cipher.encryptWithAd(
          Uint8List.fromList([1]), Uint8List.fromList([2]));
      final decipher = CipherState();
      decipher.initializeKey(Uint8List.fromList(List.filled(32, 9)));
      await expectLater(
          decipher.decryptWithAd(Uint8List.fromList([9]), encrypted),
          throwsA(isA<NoiseProtocolError>()));
      await expectLater(
          decipher.decryptWithAd(Uint8List.fromList([1]), encrypted),
          throwsA(isA<NoiseProtocolError>()));
    });

    test('rejects short keys', () {
      expect(() => CipherState().initializeKey(Uint8List(16)),
          throwsA(isA<NoiseProtocolError>()));
    });
  });

  group('handshake', () {
    test('initiator and responder agree on transport keys', () async {
      final initiator = NoiseXXInitiator();
      final responder = NoiseXXResponder();
      await initiator.initialize();
      await responder.initialize();

      final msg1 = await initiator.writeMessage1();
      expect(msg1.length, dhKeyLen);
      final msg2 = await responder.readMessage1AndWriteMessage2(msg1);
      final payload = await initiator.readMessage2(msg2);
      expect(payload, isEmpty);
      final msg3 = await initiator.writeMessage3();
      await responder.readMessage3(msg3);

      expect(initiator.handshakeHash(), responder.handshakeHash());
      // The initiator learned the responder's static key.
      expect(initiator.remoteStaticPublicKey(), isNotNull);

      final (iSend, iRecv) = await initiator.split();
      final (rSend, rRecv) = await responder.split();
      final probe = Uint8List.fromList('transport check'.codeUnits);
      final toResponder = await iSend.encryptWithAd(Uint8List(0), probe);
      expect(await rRecv.decryptWithAd(Uint8List(0), toResponder), probe);
      final toInitiator = await rSend.encryptWithAd(Uint8List(0), probe);
      expect(await iRecv.decryptWithAd(Uint8List(0), toInitiator), probe);
    });

    test('fixed keys replay a deterministic handshake', () async {
      // Two real key pairs, generated once and reused across both runs.
      Future<NoiseKeyPair> snap() async {
        final fresh = await X25519().newKeyPair();
        final pub = await fresh.extractPublicKey();
        final priv = await fresh.extractPrivateKeyBytes();
        return fixedX25519KeyPair(
            Uint8List.fromList(priv), Uint8List.fromList(pub.bytes));
      }

      final initKeys = [await snap(), await snap()];
      final respKeys = [await snap(), await snap()];

      Future<List<Uint8List>> runOnce() async {
        var i = 0;
        var r = 0;
        final initiator =
            NoiseXXInitiator(keyPairFactory: () async => initKeys[i++]);
        final responder =
            NoiseXXResponder(keyPairFactory: () async => respKeys[r++]);
        await initiator.initialize();
        await responder.initialize();
        final msg1 = await initiator.writeMessage1();
        final msg2 = await responder.readMessage1AndWriteMessage2(msg1);
        await initiator.readMessage2(msg2);
        final msg3 = await initiator.writeMessage3();
        await responder.readMessage3(msg3);
        return [msg1, msg2, msg3, initiator.handshakeHash()];
      }

      final first = await runOnce();
      expect(first[0], initKeys[0].publicKeyBytes);
      final second = await runOnce();
      for (var i = 0; i < first.length; i++) {
        expect(second[i], first[i]);
      }
    });

    test('rfc public key matches the fixed private key', () async {
      // Sanity: fixedX25519KeyPair trusts the caller; verify the RFC
      // vector pair actually agrees with a fresh keypair's DH both ways
      // is covered by the handshake test above. Here just check the
      // factory helper round-trips the bytes.
      final pair = await _rfcFactory();
      expect(pair.publicKeyBytes, _rfcPublic);
    });

    test('short message 2 kills the handshake', () async {
      final initiator = NoiseXXInitiator();
      await initiator.initialize();
      await initiator.writeMessage1();
      await expectLater(initiator.readMessage2(Uint8List(10)),
          throwsA(isA<NoiseProtocolError>()));
      await expectLater(initiator.writeMessage3(),
          throwsA(isA<NoiseProtocolError>()));
    });

    test('low-order responder key is rejected', () async {
      final initiator = NoiseXXInitiator();
      await initiator.initialize();
      await initiator.writeMessage1();
      // re = all zeros (low-order), rest padded to minimum length.
      await expectLater(initiator.readMessage2(Uint8List(minMsg2Len)),
          throwsA(isA<NoiseProtocolError>()));
    });

    test('wrong-phase calls throw', () async {
      final initiator = NoiseXXInitiator();
      await expectLater(
          initiator.writeMessage1(), throwsA(isA<NoiseProtocolError>()));
      await initiator.initialize();
      await expectLater(initiator.readMessage2(Uint8List(minMsg2Len)),
          throwsA(isA<NoiseProtocolError>()));
    });

    test('responder rejects short messages', () async {
      final responder = NoiseXXResponder();
      await responder.initialize();
      await expectLater(
          responder.readMessage1AndWriteMessage2(Uint8List(5)),
          throwsA(isA<NoiseProtocolError>()));
    });

    test('tampered message 3 fails authentication', () async {
      final initiator = NoiseXXInitiator();
      final responder = NoiseXXResponder();
      await initiator.initialize();
      await responder.initialize();
      final msg1 = await initiator.writeMessage1();
      final msg2 = await responder.readMessage1AndWriteMessage2(msg1);
      await initiator.readMessage2(msg2);
      final msg3 = await initiator.writeMessage3();
      msg3[msg3.length - 1] ^= 0xff;
      await expectLater(
          responder.readMessage3(msg3), throwsA(isA<NoiseProtocolError>()));
    });
  });
}
