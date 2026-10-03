import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/framing.dart';
import 'package:muse_companion/src/gadget/proto.dart';

void main() {
  group('noise transport framing', () {
    test('single frame round-trips', () {
      const frame = NoiseTransportFrame(
          chunkId: 123, chunkIndex: 0, totalChunks: 1);
      final decoded = decodeNoiseFrame(encodeNoiseFrame(frame));
      expect(
          (decoded.chunkId, decoded.chunkIndex, decoded.totalChunks),
          (123, 0, 1));
      expect(decoded.payload, isEmpty);
    });

    test('negative chunk ids survive the int64 encoding', () {
      const frame = NoiseTransportFrame(chunkId: -42);
      final decoded = decodeNoiseFrame(encodeNoiseFrame(frame));
      expect(decoded.chunkId, -42);
    });

    test('empty payload encodes as one frame', () {
      final frames = encodeNoiseFrames(Uint8List(0), chunkId: 7);
      expect(frames, hasLength(1));
      final decoded = decodeNoiseFrame(frames.single);
      expect((decoded.chunkId, decoded.totalChunks), (7, 1));
    });

    test('large payloads split across chunks and reassemble', () {
      final payload =
          Uint8List.fromList(List.generate(200000, (i) => i % 251));
      final frames = encodeNoiseFrames(payload, chunkId: 9);
      expect(frames.length, greaterThan(1));
      final decoder = NoiseFrameDecoder();
      Uint8List? message;
      for (final frame in frames) {
        message = decoder.decode(frame);
      }
      expect(message, payload);
    });

    test('chunks reassemble in any arrival order', () {
      final payload = Uint8List.fromList(List.filled(70000, 7));
      final frames = encodeNoiseFrames(payload, chunkId: 11);
      expect(frames.length, 2);
      final decoder = NoiseFrameDecoder();
      // Index 1 first: buffered, no message yet.
      expect(decoder.decode(frames[1]), isNull);
      // Index 0 completes the assembly.
      expect(decoder.decode(frames[0]), payload);
    });

    test('duplicate chunk poisons the decoder', () {
      final payload = Uint8List.fromList(List.filled(70000, 7));
      final frames = encodeNoiseFrames(payload, chunkId: 12);
      final decoder = NoiseFrameDecoder();
      expect(decoder.decode(frames[0]), isNull);
      expect(() => decoder.decode(frames[0]), throwsArgumentError);
      // Poisoned: even valid frames now throw.
      expect(() => decoder.decode(frames[1]), throwsStateError);
    });

    test('chunk index outside its total is rejected', () {
      final frame = NoiseTransportFrame(
          chunkId: 15,
          chunkIndex: 2,
          totalChunks: 2,
          payload: Uint8List.fromList([1]));
      expect(() => NoiseFrameDecoder().decode(encodeNoiseFrame(frame)),
          throwsArgumentError);
    });

    test('oversize payload is rejected', () {
      final frame = NoiseTransportFrame(
          chunkId: 13,
          payload: Uint8List(maxChunkPayload + 1));
      expect(() => NoiseFrameDecoder().decode(encodeNoiseFrame(frame)),
          throwsArgumentError);
    });

    test('zero total chunks is rejected', () {
      // total_chunks = 0 cannot be produced by the encoder (proto3
      // default), so build the raw bytes explicitly.
      final bad = BytesBuilder()
        ..add(int64Field(1, 14))
        ..add(uint32Field(3, 0));
      expect(() => NoiseFrameDecoder().decode(bad.toBytes()),
          throwsArgumentError);
    });
  });
}
