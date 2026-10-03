// Dart port of the Muse Gadget SDK protocol tests, plus interop goldens.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/proto.dart';

void main() {
  group('varint', () {
    test('encodes small values in one byte', () {
      expect(encodeVarint(0), [0]);
      expect(encodeVarint(1), [1]);
      expect(encodeVarint(127), [127]);
    });

    test('encodes multi-byte values', () {
      expect(encodeVarint(128), [0x80, 0x01]);
      expect(encodeVarint(300), [0xac, 0x02]);
      expect(encodeVarint(0xffffffff), [0xff, 0xff, 0xff, 0xff, 0x0f]);
    });

    test('rejects negative values', () {
      expect(() => encodeVarint(-1), throwsA(isA<ProtoError>()));
    });

    test('round-trips through readVarint', () {
      for (final value in [0, 1, 127, 128, 300, 16384, 0xffffffff]) {
        final encoded = encodeVarint(value);
        final result = readVarint(encoded, 0);
        expect(result.value, value);
        expect(result.offset, encoded.length);
      }
    });

    test('rejects truncated and malformed varints', () {
      expect(() => readVarint(Uint8List.fromList([0x80]), 0),
          throwsA(isA<ProtoError>()));
      // Ten continuation bytes with payload in the top bits.
      expect(
          () => readVarint(
              Uint8List.fromList(
                  [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02]),
              0),
          throwsA(isA<ProtoError>()));
    });
  });

  group('signed integers', () {
    test('int64 -1 encodes as ten bytes', () {
      final field = int64Field(1, -1);
      // Key (field 1, varint) + 0xffffffffffffffff as varint.
      expect(field, [
        0x08,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01,
      ]);
    });

    test('int64 extremes round-trip', () {
      const minInt64 = -9223372036854775808;
      const maxInt64 = 9223372036854775807;
      for (final value in [minInt64, -1, 0, 1, maxInt64]) {
        final field = int64Field(1, value);
        final key = readKey(field, 0);
        expect((key.fieldNumber, key.wireType), (1, wireVarint));
        final raw = readVarint(field, key.offset);
        expect(decodeInt64(raw.value), value);
      }
    });

    test('int32 extremes round-trip', () {
      for (final value in [-2147483648, -1, 0, 1, 2147483647]) {
        final field = int32Field(1, value);
        final key = readKey(field, 0);
        final raw = readVarint(field, key.offset);
        expect(decodeInt32(raw.value), value);
      }
    });

    test('int32 rejects out-of-range values', () {
      expect(() => decodeInt32(2147483648), throwsA(isA<ProtoError>()));
      expect(() => decodeInt32(-2147483649), throwsA(isA<ProtoError>()));
      expect(() => int32Field(1, 2147483648), throwsA(isA<ProtoError>()));
    });

    test('uint32 accepts only the unsigned range', () {
      expect(decodeUint32(0xffffffff), 0xffffffff);
      expect(() => decodeUint32(-1), throwsA(isA<ProtoError>()));
      expect(() => uint32Field(1, -1), throwsA(isA<ProtoError>()));
      expect(() => uint32Field(1, 0x100000000), throwsA(isA<ProtoError>()));
    });
  });

  group('fields', () {
    test('string, bytes and bool round-trip', () {
      final s = stringField(1, 'héllo');
      final key = readKey(s, 0);
      expect((key.fieldNumber, key.wireType), (1, wireDelimited));
      final raw = readDelimited(s, key.offset);
      expect(raw.value, utf8.encode('héllo')); // proto strings are UTF-8

      final b = bytesField(4, Uint8List.fromList([1, 2, 3]));
      final bkey = readKey(b, 0);
      expect((bkey.fieldNumber, bkey.wireType), (4, wireDelimited));

      final t = boolField(5, true);
      final tkey = readKey(t, 0);
      final tval = readVarint(t, tkey.offset);
      expect(tval.value, 1);
    });

    test('delimited fields reject truncation', () {
      expect(() => readDelimited(Uint8List.fromList([0x05, 0x01]), 0),
          throwsA(isA<ProtoError>()));
    });

    test('readKey rejects reserved field numbers', () {
      // Field 19000 is in the reserved range.
      final key = encodeVarint((19000 << 3) | wireVarint);
      expect(() => readKey(key, 0), throwsA(isA<ProtoError>()));
    });

    test('skipField skips every wire type', () {
      final buf = BytesBuilder()
        ..add(varintField(1, 300))
        ..add(stringField(2, 'x'))
        ..add(encodeKey(3, wireFixed32))
        ..add([1, 2, 3, 4])
        ..add(encodeKey(4, wireFixed64))
        ..add([1, 2, 3, 4, 5, 6, 7, 8]);
      final data = buf.toBytes();
      var offset = 0;
      while (offset < data.length) {
        final key = readKey(data, offset);
        offset = skipField(data, key.offset, key.wireType);
      }
      expect(offset, data.length);
    });
  });
}
