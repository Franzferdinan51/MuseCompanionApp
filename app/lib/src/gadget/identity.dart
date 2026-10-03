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
// Dart port of the Muse Gadget SDK device identity
// (linux/src/musegadget/identity.py).
//
// Stable device identity. The identity is a random, locally administered
// MAC-shaped value generated once and kept across upgrades and unpairing.
// It is not read from a network interface, so it never exposes a real
// hardware address. The derived names follow the Muse Gadget conventions
// the apps expect: the node id and the BLE name end in the same six hex
// digits.

import 'dart:math';

const String nodeIdPrefix = 'homelink-';
const String bleNamePrefix = 'MuseGadget';

final RegExp _macRe = RegExp(r'^[0-9a-f]{2}(:[0-9a-f]{2}){5}$');
final Random _secureRandom = Random.secure();

class Identity {
  const Identity(this.mac);

  /// Lowercase colon-separated MAC-shaped identity, e.g. `02:ab:..`.
  final String mac;

  /// Last six hex digits, shared by the node id and BLE name.
  String get suffix => mac.replaceAll(':', '').substring(6);

  String get nodeId => '$nodeIdPrefix$suffix';

  String get deviceId => 'hatch-link:$mac';

  /// No separator: the apps compare the text after the prefix with the
  /// text after "homelink-" in the node id.
  String get bleName => '$bleNamePrefix${suffix.toUpperCase()}';
}

bool isValidIdentityMac(String mac) => _macRe.hasMatch(mac);

/// Generate a random unicast, locally administered MAC-shaped value.
String generateMac() {
  final octets = List<int>.generate(6, (_) => _secureRandom.nextInt(256));
  octets[0] = (octets[0] & 0xfc) | 0x02;
  return octets.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
}
