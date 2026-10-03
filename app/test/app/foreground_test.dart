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
import 'package:muse_companion/app/foreground.dart';

void main() {
  test('notification copy names the agent when connected', () {
    expect(linkNotificationText('connected', '', 'Pixel Pup'),
        'Connected to Pixel Pup');
    expect(linkNotificationText('connected', '', null),
        'Connected to your Muse');
    expect(linkNotificationText('connected', '', ''), 'Connected to your Muse');
  });

  test('notification copy prefers live detail while working', () {
    expect(linkNotificationText('connecting', 'finding your Muse…', null),
        'finding your Muse…');
    expect(linkNotificationText('connecting', '', null), 'Connecting…');
    expect(linkNotificationText('waiting', 'retrying in 4s', null),
        'retrying in 4s');
    expect(linkNotificationText('waiting', '', null), 'Waiting to retry');
  });

  test('notification copy covers idle states', () {
    expect(linkNotificationText('unpaired', '', null),
        'Not paired — open the app to pair');
    expect(linkNotificationText('stopped', '', null), 'Link stopped');
    expect(linkNotificationText('bogus', '', null), 'Muse Companion');
    expect(linkNotificationText('bogus', 'custom', null), 'custom');
  });

  test('service helpers degrade safely without Android', () async {
    // Tests run off-Android with no plugin: everything must resolve to
    // its safe default instead of throwing.
    initForegroundSupport();
    initLinkService();
    expect(await startLinkService('hello'), isFalse);
    await updateLinkNotification('hello');
    expect(await stopLinkService(), isTrue);
    expect(await isLinkServiceRunning(), isFalse);
    await openBatteryOptimizationSettings();
  });
}
