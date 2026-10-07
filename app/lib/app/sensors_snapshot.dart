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
// One-shot sensor readings for the agent.
//
// Motion and magnetic-field samples (accelerometer, gyroscope,
// magnetometer) taken briefly on request, with per-sensor availability:
// hardware that never produces a sample within the timeout reports
// absent instead of failing the whole read. The agent reaches this
// through the `sensors.read` command and the sensors_read local tool.
// Unit tests inject a fake sampler; no hardware needed.

import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

/// One raw sample batch. Null per sensor when unavailable.
class SensorSample {
  const SensorSample({this.accelerometer, this.gyroscope, this.magnetometer});

  final List<double>? accelerometer;
  final List<double>? gyroscope;
  final List<double>? magnetometer;

  Map<String, Object?> toJson() => {
    'accelerometer': accelerometer,
    'gyroscope': gyroscope,
    'magnetometer': magnetometer,
  };
}

/// Produces one [SensorSample]; the default reads real hardware.
typedef SensorSampler = Future<SensorSample> Function(Duration timeout);

/// First event per stream wins; timeout or error yields null.
Future<List<double>?> _firstOf<T>(
  Stream<T> stream,
  List<double> Function(T event) pick,
  Duration timeout,
) async {
  try {
    return pick(await stream.first.timeout(timeout));
  } catch (_) {
    return null;
  }
}

/// Reads real sensors: first event per stream wins, timeout per sensor.
Future<SensorSample> readHardwareSensors(Duration timeout) async {
  final results = await Future.wait([
    _firstOf(accelerometerEventStream(), (e) => [e.x, e.y, e.z], timeout),
    _firstOf(gyroscopeEventStream(), (e) => [e.x, e.y, e.z], timeout),
    _firstOf(magnetometerEventStream(), (e) => [e.x, e.y, e.z], timeout),
  ]);
  return SensorSample(
    accelerometer: results[0],
    gyroscope: results[1],
    magnetometer: results[2],
  );
}

class SensorReader {
  /// When [sampler] is set, hardware is never touched (unit tests).
  SensorReader({SensorSampler? sampler})
    : _sampler = sampler ?? readHardwareSensors;

  final SensorSampler _sampler;

  /// How long to wait per sensor for one sample.
  static const Duration sampleTimeout = Duration(seconds: 2);

  /// Take one snapshot. Never throws: missing hardware yields nulls.
  Future<Map<String, Object?>> read({Duration timeout = sampleTimeout}) async {
    SensorSample sample;
    try {
      sample = await _sampler(timeout);
    } catch (_) {
      sample = const SensorSample();
    }
    return {
      'taken_at': DateTime.now().toIso8601String(),
      'available': {
        'accelerometer': sample.accelerometer != null,
        'gyroscope': sample.gyroscope != null,
        'magnetometer': sample.magnetometer != null,
      },
      ...sample.toJson(),
    };
  }
}
