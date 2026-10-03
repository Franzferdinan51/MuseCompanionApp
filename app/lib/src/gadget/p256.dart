// P-256 (secp256r1) ECDH in pure Dart, for BLE pairing.
//
// package:cryptography only implements ECDH through native delegates, so the
// companion carries its own small P-256 to behave identically on Android,
// iOS, macOS and Windows with no platform plugins. Only key generation and
// ECDH are implemented; pairing sessions are ephemeral and community
// pairing performs no peer authentication, so side-channel hardening of
// the scalar multiplication is out of scope.
//
// Verified against the official link_pairing_v5 vectors (see
// test/gadget/p256_test.dart): scalar 1 and 2 reproduce the vector public
// keys and their ECDH secret.

import 'dart:math';
import 'dart:typed_data';

final BigInt _p = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16);
final BigInt _a = _p - BigInt.from(3);
final BigInt _b = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16);
final BigInt _gx = BigInt.parse(
    '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
    radix: 16);
final BigInt _gy = BigInt.parse(
    '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
    radix: 16);
final BigInt _n = BigInt.parse(
    'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b6dac2fc632551',
    radix: 16);

final Random _secureRandom = Random.secure();

class _Point {
  const _Point(this.x, this.y);
  final BigInt x;
  final BigInt y;
}

BigInt _toInt(Uint8List bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _toBytes32(BigInt value) {
  if (value < BigInt.zero) {
    throw ArgumentError('negative coordinate');
  }
  final hex = value.toRadixString(16).padLeft(64, '0');
  if (hex.length > 64) {
    throw ArgumentError('coordinate overflow');
  }
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

BigInt _inv(BigInt a) => a.modPow(_p - BigInt.two, _p);

bool _isOnCurve(BigInt x, BigInt y) {
  if (x < BigInt.zero ||
      x >= _p ||
      y < BigInt.zero ||
      y >= _p) {
    return false;
  }
  final left = (y * y) % _p;
  final right = (((x * x) % _p * x) % _p + _a * x + _b) % _p;
  return left == right;
}

/// Point doubling (affine). Null is the point at infinity.
_Point? _double(_Point? p) {
  if (p == null) return null;
  if (p.y == BigInt.zero) return null;
  final lam = (((BigInt.from(3) * p.x % _p * p.x) % _p + _a) % _p *
          _inv((BigInt.two * p.y) % _p)) %
      _p;
  final xr = (lam * lam % _p - p.x - p.x) % _p;
  final yr = ((lam * ((p.x - xr) % _p)) % _p - p.y) % _p;
  return _Point(xr, yr);
}

/// Point addition (affine). Null is the point at infinity.
_Point? _add(_Point? p, _Point? q) {
  if (p == null) return q;
  if (q == null) return p;
  if (p.x == q.x) {
    if ((p.y + q.y) % _p == BigInt.zero) return null;
    return _double(p);
  }
  final lam = (((q.y - p.y) % _p) * _inv((q.x - p.x) % _p)) % _p;
  final xr = (lam * lam % _p - p.x - q.x) % _p;
  final yr = ((lam * ((p.x - xr) % _p)) % _p - p.y) % _p;
  return _Point(xr, yr);
}

/// Scalar multiplication by double-and-add, 256 rounds.
_Point? _scalarMult(BigInt k, _Point? point) {
  _Point? result;
  _Point? addend = point;
  var scalar = k;
  for (var i = 0; i < 256; i++) {
    if ((scalar & BigInt.one) == BigInt.one) {
      result = _add(result, addend);
    }
    addend = _double(addend);
    scalar = scalar >> 1;
  }
  return result;
}

/// A P-256 key pair: 32-byte big-endian d, x and y.
class P256KeyPair {
  const P256KeyPair({required this.d, required this.x, required this.y});
  final Uint8List d;
  final Uint8List x;
  final Uint8List y;
}

/// Generate a fresh key pair with the given (or secure) randomness.
P256KeyPair generateP256KeyPair([Uint8List Function(int)? randomBytes]) {
  final rand = randomBytes ??
      (length) {
        final out = Uint8List(length);
        for (var i = 0; i < length; i++) {
          out[i] = _secureRandom.nextInt(256);
        }
        return out;
      };
  final d = (_toInt(rand(32)) % (_n - BigInt.one)) + BigInt.one;
  return p256KeyPairFromPrivate(_toBytes32(d));
}

/// Rebuild a key pair from a 32-byte private scalar.
P256KeyPair p256KeyPairFromPrivate(Uint8List d) {
  if (d.length != 32) {
    throw ArgumentError('P-256 private scalar must be 32 bytes');
  }
  final scalar = _toInt(d);
  if (scalar <= BigInt.zero || scalar >= _n) {
    throw ArgumentError('P-256 private scalar out of range');
  }
  final q = _scalarMult(scalar, _Point(_gx, _gy))!;
  return P256KeyPair(d: Uint8List.fromList(d), x: _toBytes32(q.x), y: _toBytes32(q.y));
}

/// True if (x, y) is a valid P-256 public point.
bool p256IsOnCurve(Uint8List x, Uint8List y) {
  if (x.length != 32 || y.length != 32) return false;
  return _isOnCurve(_toInt(x), _toInt(y));
}

/// ECDH: x-coordinate of d*Q as 32 big-endian bytes.
Uint8List p256Ecdh(Uint8List d, Uint8List peerX, Uint8List peerY) {
  if (d.length != 32 || peerX.length != 32 || peerY.length != 32) {
    throw ArgumentError('P-256 ECDH inputs must be 32 bytes');
  }
  final scalar = _toInt(d);
  if (scalar <= BigInt.zero || scalar >= _n) {
    throw ArgumentError('P-256 private scalar out of range');
  }
  final qx = _toInt(peerX);
  final qy = _toInt(peerY);
  if (!_isOnCurve(qx, qy)) {
    throw ArgumentError('P-256 peer point is not on the curve');
  }
  final shared = _scalarMult(scalar, _Point(qx, qy));
  if (shared == null) {
    throw ArgumentError('P-256 ECDH reached the point at infinity');
  }
  return _toBytes32(shared.x);
}

/// The curve order (exposed for tests).
BigInt p256Order() => _n;

/// The generator point (exposed for tests).
(Uint8List, Uint8List) p256Generator() =>
    (_toBytes32(_gx), _toBytes32(_gy));
