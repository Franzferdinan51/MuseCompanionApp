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

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/sensors_snapshot.dart';

void main() {
  test('read reports samples and availability', () async {
    final reader = SensorReader(
      sampler: (_) async => const SensorSample(
        accelerometer: [0.1, 9.7, 0.2],
        gyroscope: null,
        magnetometer: [20.0, -5.0, 44.0],
      ),
    );
    final snapshot = await reader.read();
    final available = snapshot['available'] as Map;
    expect(available['accelerometer'], isTrue);
    expect(available['gyroscope'], isFalse);
    expect(available['magnetometer'], isTrue);
    expect(snapshot['accelerometer'], [0.1, 9.7, 0.2]);
    expect(snapshot['gyroscope'], isNull);
    expect(snapshot, contains('taken_at'));
  });

  test('a throwing sampler yields an all-absent snapshot', () async {
    final reader = SensorReader(
      sampler: (_) async => throw StateError('no hardware'),
    );
    final snapshot = await reader.read();
    final available = snapshot['available'] as Map;
    expect(available.values.every((v) => v == false), isTrue);
  });
}
