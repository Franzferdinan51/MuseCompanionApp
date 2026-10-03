import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/p256.dart';
import 'package:muse_companion/src/gadget/pairing.dart'
    show b64urlDecode, b64urlEncode;

Map<String, Object?> _vector(String name) {
  final file = File('test/testdata/link_pairing_v5.json');
  final decoded = json.decode(file.readAsStringSync()) as Map<String, Object?>;
  for (final vector in decoded['vectors'] as List) {
    final map = (vector as Map).cast<String, Object?>();
    if (map['name'] == name) return map;
  }
  throw StateError('no vector $name');
}

Uint8List _hex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('p256', () {
    test('scalar 1 reproduces the vector mobile key', () {
      final v = _vector('community_app_v5');
      final pair = p256KeyPairFromPrivate(
          _hex(v['mobile_private_scalar_hex'] as String));
      final point = Uint8List(65)
        ..[0] = 0x04
        ..setRange(1, 33, pair.x)
        ..setRange(33, 65, pair.y);
      expect(b64urlEncode(point), v['mobile_pub']);
    });

    test('scalar 2 reproduces the vector device key', () {
      final v = _vector('community_app_v5');
      final pair = p256KeyPairFromPrivate(
          _hex(v['device_private_scalar_hex'] as String));
      final point = Uint8List(65)
        ..[0] = 0x04
        ..setRange(1, 33, pair.x)
        ..setRange(33, 65, pair.y);
      expect(b64urlEncode(point), v['device_pub']);
    });

    test('ecdh reproduces the vector secret both ways', () {
      final v = _vector('community_app_v5');
      final mobilePoint = b64urlDecode(v['mobile_pub'] as String);
      final devicePoint = b64urlDecode(v['device_pub'] as String);
      final expected = v['ecdh_secret_hex'] as String;
      expect(
          _hexOf(p256Ecdh(
              _hex(v['device_private_scalar_hex'] as String),
              mobilePoint.sublist(1, 33),
              mobilePoint.sublist(33, 65))),
          expected);
      expect(
          _hexOf(p256Ecdh(
              _hex(v['mobile_private_scalar_hex'] as String),
              devicePoint.sublist(1, 33),
              devicePoint.sublist(33, 65))),
          expected);
    });

    test('generated keys agree on ecdh both ways', () {
      final a = generateP256KeyPair();
      final b = generateP256KeyPair();
      expect(p256IsOnCurve(a.x, a.y), isTrue);
      expect(p256IsOnCurve(b.x, b.y), isTrue);
      expect(p256Ecdh(a.d, b.x, b.y), p256Ecdh(b.d, a.x, a.y));
    });

    test('off-curve points are rejected', () {
      final a = generateP256KeyPair();
      final badX = Uint8List.fromList(a.x)..[31] ^= 0x01;
      expect(p256IsOnCurve(badX, a.y), isFalse);
      expect(() => p256Ecdh(a.d, badX, a.y), throwsArgumentError);
      expect(
          p256IsOnCurve(Uint8List(32), Uint8List(32)), isFalse);
    });

    test('out-of-range scalars are rejected', () {
      final a = generateP256KeyPair();
      expect(() => p256KeyPairFromPrivate(Uint8List(32)),
          throwsArgumentError);
      expect(() => p256Ecdh(Uint8List(32), a.x, a.y), throwsArgumentError);
      expect(() => p256KeyPairFromPrivate(Uint8List(31)),
          throwsArgumentError);
    });
  });
}
