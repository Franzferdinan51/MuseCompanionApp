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
// Dart port of the Muse Gadget SDK BLE chunked framing
// (linux/src/musegadget/ble_framing.py).
//
// Both directions use the same frame: `0xFE`, chunk index, total chunks,
// then a payload fragment. A write or notification that does not start with
// `0xFE` is a complete, unchunked message.

import 'dart:typed_data';

const int chunkMagic = 0xfe;
const int headerBytes = 3;
const int maxPacketBytes = 160;
const int maxChunks = 255;
const int maxMessageBytes = 8192;
const int defaultAttMtu = 23;

/// Delay between notifications so phones can keep up.
const Duration chunkStagger = Duration(milliseconds: 50);

/// Split [data] into framed packets that fit one notification at [mtu].
List<Uint8List> encodeChunks(Uint8List data, [int mtu = defaultAttMtu]) {
  var notifyMax = mtu > 3 ? mtu - 3 : 20;
  if (notifyMax > maxPacketBytes) notifyMax = maxPacketBytes;
  final usable = notifyMax - headerBytes;
  final fragments = <Uint8List>[];
  for (var i = 0; i < data.length; i += usable) {
    var end = i + usable;
    if (end > data.length) end = data.length;
    fragments.add(Uint8List.sublistView(data, i, end));
  }
  if (fragments.isEmpty) {
    fragments.add(Uint8List(0));
  }
  if (fragments.length > maxChunks) {
    throw ArgumentError(
        'message needs ${fragments.length} chunks (max $maxChunks)');
  }
  final total = fragments.length;
  final out = <Uint8List>[];
  for (var i = 0; i < fragments.length; i++) {
    final packet =
        Uint8List(headerBytes + fragments[i].length);
    packet[0] = chunkMagic;
    packet[1] = i;
    packet[2] = total;
    packet.setRange(headerBytes, packet.length, fragments[i]);
    out.add(packet);
  }
  return out;
}

/// Reassembles chunked writes, strictly in order.
///
/// Index 0, or a change in the total, starts a new message. An out-of-order
/// chunk or an oversize message discards what has been collected.
class ChunkAssembler {
  ChunkAssembler({this.maxBytes = maxMessageBytes});

  final int maxBytes;
  final BytesBuilder _buf = BytesBuilder();
  int _bufLength = 0;
  int _total = 0;
  int _next = 0;

  void reset() {
    _buf.clear();
    _bufLength = 0;
    _total = 0;
    _next = 0;
  }

  /// Add one write; returns a complete message once one is available.
  Uint8List? feed(Uint8List packet) {
    if (packet.length < headerBytes || packet[0] != chunkMagic) {
      return Uint8List.fromList(packet);
    }
    final index = packet[1];
    final total = packet[2];
    final fragment = packet.sublist(headerBytes);
    if (total == 0) {
      reset();
      return null;
    }
    if (index == 0 || total != _total) {
      reset();
      _total = total;
    }
    if (index != _next || index >= _total) {
      reset();
      return null;
    }
    if (_bufLength + fragment.length > maxBytes) {
      reset();
      return null;
    }
    _buf.add(fragment);
    _bufLength += fragment.length;
    _next = index + 1;
    if (_next < _total) {
      return null;
    }
    final message = _buf.toBytes();
    reset();
    return message;
  }
}
