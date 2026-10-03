import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/ble_framing.dart';

void main() {
  group('ble chunk framing', () {
    test('short writes pass through unchunked', () {
      final assembler = ChunkAssembler();
      final packet = Uint8List.fromList('hello'.codeUnits);
      expect(assembler.feed(packet), packet);
    });

    test('short packets are still framed on send', () {
      final packets = encodeChunks(Uint8List.fromList([1, 2, 3]));
      expect(packets, hasLength(1));
      expect(packets.single.sublist(0, 3), [chunkMagic, 0, 1]);
    });

    test('messages round-trip across chunked packets', () {
      final message = Uint8List.fromList(
          List.generate(500, (i) => i % 251));
      for (final mtu in [23, 64, 163]) {
        final packets = encodeChunks(message, mtu);
        expect(packets.length, greaterThan(1));
        for (final packet in packets) {
          expect(packet.length, lessThanOrEqualTo(mtu - 3));
        }
        final assembler = ChunkAssembler();
        Uint8List? out;
        for (final packet in packets) {
          out = assembler.feed(packet);
        }
        expect(out, message);
      }
    });

    test('index 0 restarts the assembly', () {
      final message = Uint8List.fromList(List.filled(100, 9));
      final packets = encodeChunks(message);
      final assembler = ChunkAssembler();
      expect(assembler.feed(packets[0]), isNull);
      // A new message starting at 0 discards the partial one.
      expect(assembler.feed(packets[0]), isNull);
      Uint8List? out;
      for (final packet in packets.skip(1)) {
        out = assembler.feed(packet);
      }
      expect(out, message);
    });

    test('out-of-order chunk discards the assembly', () {
      final message = Uint8List.fromList(List.filled(100, 9));
      final packets = encodeChunks(message);
      expect(packets.length, greaterThan(2));
      final assembler = ChunkAssembler();
      expect(assembler.feed(packets[0]), isNull);
      expect(assembler.feed(packets[2]), isNull);
      // The assembly restarted; the full message still completes.
      Uint8List? out;
      for (final packet in packets) {
        out = assembler.feed(packet);
      }
      expect(out, message);
    });

    test('oversize messages are discarded', () {
      final assembler = ChunkAssembler(maxBytes: 10);
      final packets = encodeChunks(Uint8List.fromList(List.filled(100, 1)));
      Uint8List? out;
      for (final packet in packets) {
        out = assembler.feed(packet);
      }
      expect(out, isNull);
    });

    test('zero total resets without a message', () {
      final assembler = ChunkAssembler();
      expect(
          assembler.feed(Uint8List.fromList([chunkMagic, 0, 0])), isNull);
    });

    test('too-large messages are rejected on send', () {
      final huge = Uint8List(maxChunks * 20 + 1);
      expect(() => encodeChunks(huge), throwsArgumentError);
    });
  });
}
