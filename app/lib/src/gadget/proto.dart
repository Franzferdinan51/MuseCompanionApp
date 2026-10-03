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
// Dart port of the Muse Gadget SDK protobuf wire codec
// (linux/src/musegadget/noise/_proto.py).

import 'dart:convert';
import 'dart:typed_data';

/// Wire types used by the gadget Noise protobuf messages.
const int wireVarint = 0;
const int wireFixed64 = 1;
const int wireDelimited = 2;
const int wireFixed32 = 5;

/// Thrown when a gadget Noise protobuf message is malformed.
class ProtoError extends Error {
  ProtoError(this.message);
  final String message;
  @override
  String toString() => 'ProtoError: $message';
}

const int _maxFieldNumber = (1 << 29) - 1;
const int _firstReservedFieldNumber = 19000;
const int _lastReservedFieldNumber = 19999;

bool _validFieldNumber(int fieldNumber) {
  return fieldNumber != 0 &&
      fieldNumber <= _maxFieldNumber &&
      !(fieldNumber >= _firstReservedFieldNumber &&
          fieldNumber <= _lastReservedFieldNumber);
}

/// Encode a non-negative integer as a protobuf varint.
Uint8List encodeVarint(int value) {
  if (value < 0) {
    throw ProtoError('varint value must be non-negative');
  }
  return _encodeVarintBig(BigInt.from(value));
}

Uint8List _encodeVarintBig(BigInt value) {
  if (value < BigInt.zero || value >= (BigInt.one << 64)) {
    throw ProtoError('varint value exceeds uint64 range');
  }
  final out = BytesBuilder();
  var v = value;
  while (true) {
    var byte = (v & BigInt.from(0x7f)).toInt();
    v = v >> 7;
    if (v != BigInt.zero) {
      out.addByte(byte | 0x80);
    } else {
      out.addByte(byte);
      return out.toBytes();
    }
  }
}

/// Map a signed int64 to its unsigned 64-bit wire value.
BigInt signedInt64Value(int value) => _signedToUnsigned(value, 64);

/// Map a signed int32 to its unsigned 64-bit wire value.
BigInt signedInt32Value(int value) {
  if (value < -(1 << 31) || value > (1 << 31) - 1) {
    throw ProtoError('int32 value out of range');
  }
  return _signedToUnsigned(value, 64);
}

BigInt _signedToUnsigned(int value, int bits) {
  var v = BigInt.from(value);
  if (v < BigInt.zero) {
    v += BigInt.one << bits;
  }
  return v;
}

/// Decode a varint wire value as int64.
///
/// [raw] is the wrapped 64-bit accumulator from [readVarint], which already
/// holds the signed interpretation, so this only validates the range.
int decodeInt64(int raw) => raw;

/// Decode a varint wire value as int32, range-checking it.
int decodeInt32(int raw) {
  if (raw < -(1 << 31) || raw > (1 << 31) - 1) {
    throw ProtoError('int32 value out of range');
  }
  return raw;
}

/// Decode a varint wire value as uint32, range-checking it.
int decodeUint32(int raw) {
  if (raw < 0 || raw > 0xffffffff) {
    throw ProtoError('uint32 value out of range');
  }
  return raw;
}

Uint8List encodeKey(int fieldNumber, int wireType) {
  if (!_validFieldNumber(fieldNumber)) {
    throw ProtoError('invalid field number');
  }
  if (wireType != wireVarint &&
      wireType != wireFixed64 &&
      wireType != wireDelimited &&
      wireType != wireFixed32) {
    throw ProtoError('invalid wire type');
  }
  return encodeVarint((fieldNumber << 3) | wireType);
}

Uint8List varintField(int fieldNumber, int value) =>
    _concat([encodeKey(fieldNumber, wireVarint), encodeVarint(value)]);

Uint8List int64Field(int fieldNumber, int value) => _concat([
      encodeKey(fieldNumber, wireVarint),
      _encodeVarintBig(signedInt64Value(value)),
    ]);

Uint8List int32Field(int fieldNumber, int value) => _concat([
      encodeKey(fieldNumber, wireVarint),
      _encodeVarintBig(signedInt32Value(value)),
    ]);

Uint8List uint32Field(int fieldNumber, int value) {
  if (value < 0 || value > 0xffffffff) {
    throw ProtoError('uint32 value out of range');
  }
  return varintField(fieldNumber, value);
}

Uint8List boolField(int fieldNumber, bool value) =>
    varintField(fieldNumber, value ? 1 : 0);

Uint8List delimitedField(int fieldNumber, Uint8List payload) => _concat([
      encodeKey(fieldNumber, wireDelimited),
      encodeVarint(payload.length),
      payload,
    ]);

Uint8List stringField(int fieldNumber, String value) =>
    delimitedField(fieldNumber, Uint8List.fromList(utf8.encode(value)));

Uint8List bytesField(int fieldNumber, Uint8List value) =>
    delimitedField(fieldNumber, value);

/// Result of reading one value from a buffer: the value and next offset.
class ReadResult<T> {
  const ReadResult(this.value, this.offset);
  final T value;
  final int offset;
}

/// Read a varint at [offset]; the value wraps mod 2^64 like the wire format.
ReadResult<int> readVarint(Uint8List data, int offset) {
  var value = 0;
  var shift = 0;
  for (var i = 0; i < 10; i++) {
    if (offset >= data.length) {
      throw ProtoError('truncated varint');
    }
    final byte = data[offset];
    offset += 1;
    if (i == 9 && (byte & 0xfe) != 0) {
      throw ProtoError('malformed varint');
    }
    // `<<` and `|` wrap mod 2^64, matching the unsigned wire value.
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) {
      return ReadResult(value, offset);
    }
    shift += 7;
  }
  throw ProtoError('malformed varint');
}

class KeyResult {
  const KeyResult(this.fieldNumber, this.wireType, this.offset);
  final int fieldNumber;
  final int wireType;
  final int offset;
}

KeyResult readKey(Uint8List data, int offset) {
  final key = readVarint(data, offset);
  final fieldNumber = key.value >> 3;
  final wireType = key.value & 0x07;
  if (!_validFieldNumber(fieldNumber)) {
    throw ProtoError('invalid field number');
  }
  if (wireType != wireVarint &&
      wireType != wireFixed64 &&
      wireType != wireDelimited &&
      wireType != wireFixed32) {
    throw ProtoError('invalid wire type');
  }
  return KeyResult(fieldNumber, wireType, key.offset);
}

ReadResult<Uint8List> readDelimited(Uint8List data, int offset) {
  final length = readVarint(data, offset);
  final end = length.offset + length.value;
  if (length.value < 0 || end > data.length) {
    throw ProtoError('truncated delimited field');
  }
  return ReadResult(
      Uint8List.sublistView(data, length.offset, end), end);
}

int skipField(Uint8List data, int offset, int wireType) {
  if (wireType == wireVarint) {
    return readVarint(data, offset).offset;
  }
  if (wireType == wireFixed64) {
    final end = offset + 8;
    if (end > data.length) {
      throw ProtoError('truncated fixed64 field');
    }
    return end;
  }
  if (wireType == wireDelimited) {
    return readDelimited(data, offset).offset;
  }
  if (wireType == wireFixed32) {
    final end = offset + 4;
    if (end > data.length) {
      throw ProtoError('truncated fixed32 field');
    }
    return end;
  }
  throw ProtoError('invalid wire type');
}

Uint8List _concat(List<Uint8List> parts) {
  final builder = BytesBuilder();
  for (final part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}
