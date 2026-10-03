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
// Dart port of the Muse Gadget SDK Noise transport framing
// (linux/src/musegadget/noise/framing.py).

import 'dart:math';
import 'dart:typed_data';

import 'proto.dart';

/// Largest payload carried in one [NoiseTransportFrame].
const int maxChunkPayload = 65489;

/// Largest number of assemblies the decoder holds at once.
const int maxPendingAssemblies = 16;

/// Largest number of chunks in one framed message.
const int maxTotalChunks = 256;

/// Largest reassembled message the decoder accepts.
const int maxAssemblyBytes = 16 * 1024 * 1024;

/// How long an incomplete assembly is kept before eviction.
const Duration assemblyTtl = Duration(seconds: 60);

/// One chunk of a framed Noise transport message.
class NoiseTransportFrame {
  const NoiseTransportFrame({
    this.chunkId = 0,
    this.chunkIndex = 0,
    this.totalChunks = 1,
    this.payload,
  });

  final int chunkId;
  final int chunkIndex;
  final int totalChunks;
  final Uint8List? payload;
}

class _Assembly {
  _Assembly({
    required this.total,
    required this.createdAt,
  });

  final Map<int, Uint8List> chunks = {};
  final int total;
  int totalBytes = 0;
  final DateTime createdAt;
  late DateTime lastUpdated;
}

final Random _random = Random.secure();

int _randomInt64() {
  // Two 32-bit halves; the top bit of the high half becomes the sign.
  final high = _random.nextInt(1 << 32);
  final low = _random.nextInt(1 << 32);
  return (high << 32) | low;
}

Uint8List encodeNoiseFrame(NoiseTransportFrame frame) {
  final out = BytesBuilder();
  if (frame.chunkId != 0) {
    out.add(int64Field(1, frame.chunkId));
  }
  if (frame.chunkIndex != 0) {
    out.add(uint32Field(2, frame.chunkIndex));
  }
  if (frame.totalChunks != 0) {
    out.add(uint32Field(3, frame.totalChunks));
  }
  final payload = frame.payload;
  if (payload != null && payload.isNotEmpty) {
    out.add(bytesField(4, payload));
  }
  return out.toBytes();
}

NoiseTransportFrame decodeNoiseFrame(Uint8List data) {
  var chunkId = 0;
  var chunkIndex = 0;
  var totalChunks = 1;
  Uint8List payload = Uint8List(0);
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireVarint) {
        throw ProtoError('NoiseTransportFrame.chunk_id wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      chunkId = decodeInt64(raw.value);
    } else if (k.fieldNumber == 2) {
      if (k.wireType != wireVarint) {
        throw ProtoError('NoiseTransportFrame.chunk_index wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      chunkIndex = decodeUint32(raw.value);
    } else if (k.fieldNumber == 3) {
      if (k.wireType != wireVarint) {
        throw ProtoError('NoiseTransportFrame.total_chunks wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      totalChunks = decodeUint32(raw.value);
    } else if (k.fieldNumber == 4) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('NoiseTransportFrame.payload wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      payload = raw.value;
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  return NoiseTransportFrame(
    chunkId: chunkId,
    chunkIndex: chunkIndex,
    totalChunks: totalChunks,
    payload: payload,
  );
}

/// Split [data] into framed chunks, each fitting one Noise transport frame.
List<Uint8List> encodeNoiseFrames(Uint8List data, {int? chunkId}) {
  final selectedChunkId = chunkId ?? _randomInt64();
  final totalChunks =
      data.isEmpty ? 1 : (data.length + maxChunkPayload - 1) ~/ maxChunkPayload;
  if (totalChunks > maxTotalChunks) {
    throw ArgumentError(
        'payload too large for noise framing '
        '(${data.length} bytes, $totalChunks chunks > $maxTotalChunks)');
  }

  if (data.isEmpty) {
    return [
      encodeNoiseFrame(NoiseTransportFrame(
        chunkId: selectedChunkId,
        chunkIndex: 0,
        totalChunks: 1,
        payload: Uint8List(0),
      ))
    ];
  }

  final frames = <Uint8List>[];
  for (var index = 0; index < totalChunks; index++) {
    final start = index * maxChunkPayload;
    var end = start + maxChunkPayload;
    if (end > data.length) end = data.length;
    frames.add(encodeNoiseFrame(NoiseTransportFrame(
      chunkId: selectedChunkId,
      chunkIndex: index,
      totalChunks: totalChunks,
      payload: Uint8List.sublistView(data, start, end),
    )));
  }
  return frames;
}

/// Reassembles chunked Noise transport frames.
///
/// Like the reference implementation, the decoder is poisoned by any invalid
/// frame: after a failure every later call throws.
class NoiseFrameDecoder {
  final Map<int, _Assembly> _pending = {};
  bool _poisoned = false;

  /// Feed one decrypted frame; returns a complete message once reassembled.
  Uint8List? decode(Uint8List frameBytes) {
    if (_poisoned) {
      throw StateError('NoiseFrameDecoder: poisoned after prior failure');
    }
    try {
      final frame = decodeNoiseFrame(frameBytes);
      if (frame.totalChunks < 1 || frame.totalChunks > maxTotalChunks) {
        throw ArgumentError('invalid totalChunks: ${frame.totalChunks}');
      }
      if (frame.chunkIndex < 0 || frame.chunkIndex >= frame.totalChunks) {
        throw ArgumentError(
            'chunkIndex ${frame.chunkIndex} out of range '
            '[0, ${frame.totalChunks})');
      }
      final payload = frame.payload ?? Uint8List(0);
      if (payload.length > maxChunkPayload) {
        throw ArgumentError(
            'payload too large for noise frame (${payload.length} bytes)');
      }

      _evictExpired();

      var assembly = _pending[frame.chunkId];
      if (assembly == null) {
        if (_pending.length >= maxPendingAssemblies) {
          throw ArgumentError('too many pending noise frame assemblies');
        }
        final now = DateTime.now();
        assembly = _Assembly(total: frame.totalChunks, createdAt: now)
          ..lastUpdated = now;
        _pending[frame.chunkId] = assembly;
      }

      if (assembly.total != frame.totalChunks) {
        _pending.remove(frame.chunkId);
        throw ArgumentError(
            'inconsistent totalChunks for chunkId: '
            'expected ${assembly.total}, got ${frame.totalChunks}');
      }

      if (assembly.chunks.containsKey(frame.chunkIndex)) {
        _pending.remove(frame.chunkId);
        throw ArgumentError('duplicate chunkIndex ${frame.chunkIndex}');
      }

      assembly.lastUpdated = DateTime.now();
      assembly.totalBytes += payload.length;
      if (assembly.totalBytes > maxAssemblyBytes) {
        _pending.remove(frame.chunkId);
        throw ArgumentError('assembly exceeded byte budget');
      }

      assembly.chunks[frame.chunkIndex] = payload;
      if (assembly.chunks.length < assembly.total) {
        return null;
      }

      _pending.remove(frame.chunkId);
      if (assembly.total == 1) {
        return assembly.chunks[0]!;
      }
      final out = BytesBuilder();
      for (var i = 0; i < assembly.total; i++) {
        out.add(assembly.chunks[i]!);
      }
      return out.toBytes();
    } catch (_) {
      _poisoned = true;
      rethrow;
    }
  }

  void _evictExpired() {
    final now = DateTime.now();
    final expired = <int>[];
    _pending.forEach((chunkId, assembly) {
      if (now.difference(assembly.createdAt) > assemblyTtl) {
        expired.add(chunkId);
      }
    });
    for (final chunkId in expired) {
      _pending.remove(chunkId);
    }
  }
}
