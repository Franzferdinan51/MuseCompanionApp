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
// Android foreground service keep-alive for the Muse link.
//
// The link loop runs in the main isolate; without a foreground service
// Android may kill the process minutes after the app leaves the screen,
// dropping the VM connection and BLE advertising. The service carries
// no work of its own — it holds a persistent notification showing the
// live link state and keeps the process alive. Battery impact is
// limited to the link itself: no wake lock, no periodic task, no
// boot restart (a headless restart could not run the main-isolate
// loop anyway).
//
// Every entry point is safe to call on any platform and without the
// plugin (tests, desktop): failures degrade to "service unavailable"
// instead of throwing.

import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

const int _linkServiceId = 0xC0FFEE;
const String _stopButtonId = 'stop';

/// Task-side entry point. Must stay top-level for the background isolate.
@pragma('vm:entry-point')
void startLinkServiceCallback() {
  FlutterForegroundTask.setTaskHandler(LinkTaskHandler());
}

/// The background isolate does no work; the link lives in the main
/// isolate. The handler only fields notification-button presses.
class LinkTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == _stopButtonId) {
      FlutterForegroundTask.stopService();
    }
  }
}

/// Register the main/task communication port. Call once in `main()`.
void initForegroundSupport() {
  try {
    FlutterForegroundTask.initCommunicationPort();
  } catch (_) {
    // No plugin on this platform; the link simply has no keep-alive.
  }
}

/// Configure the notification channel and task behavior (idempotent).
void initLinkService() {
  if (!Platform.isAndroid) return;
  try {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'muse_link',
        channelName: 'Muse link',
        channelDescription:
            'Keeps the companion connected while the app is in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.once(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: false,
        allowWifiLock: false,
      ),
    );
  } catch (_) {
    // Leave the service uninitialized; start attempts will fail softly.
  }
}

/// Start the keep-alive; returns true while the service is up.
Future<bool> startLinkService(String notificationText) async {
  if (!Platform.isAndroid) return false;
  try {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
          notificationText: notificationText);
      return true;
    }
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: _linkServiceId,
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'Muse Companion',
      notificationText: notificationText,
      notificationButtons: const [
        NotificationButton(id: _stopButtonId, text: 'Stop'),
      ],
      notificationInitialRoute: '/',
      callback: startLinkServiceCallback,
    );
    return result is ServiceRequestSuccess;
  } catch (_) {
    return false;
  }
}

/// Refresh the notification line; no-op unless the service runs.
Future<void> updateLinkNotification(String notificationText) async {
  if (!Platform.isAndroid) return;
  try {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
          notificationText: notificationText);
    }
  } catch (_) {
    // The notification is best-effort.
  }
}

/// Stop the keep-alive; returns true when it is down afterwards.
Future<bool> stopLinkService() async {
  if (!Platform.isAndroid) return true;
  try {
    if (!await FlutterForegroundTask.isRunningService) return true;
    final result = await FlutterForegroundTask.stopService();
    return result is ServiceRequestSuccess;
  } catch (_) {
    return false;
  }
}

/// Whether the keep-alive is currently up.
Future<bool> isLinkServiceRunning() async {
  if (!Platform.isAndroid) return false;
  try {
    return await FlutterForegroundTask.isRunningService;
  } catch (_) {
    return false;
  }
}

/// One-line notification copy for the link state. Pure for tests.
String linkNotificationText(
    String state, String detail, String? agentName) {
  switch (state) {
    case 'connected':
      final who = agentName?.isNotEmpty == true ? agentName! : 'your Muse';
      return 'Connected to $who';
    case 'connecting':
      return detail.isEmpty ? 'Connecting…' : detail;
    case 'waiting':
      return detail.isEmpty ? 'Waiting to retry' : detail;
    case 'unpaired':
      return 'Not paired — open the app to pair';
    case 'stopped':
      return 'Link stopped';
    default:
      return detail.isEmpty ? 'Muse Companion' : detail;
  }
}

/// Open the battery-optimization settings so the user can exempt the app.
///
/// Long-lived links die under aggressive doze on some OEM skins. This
/// only launches settings — the user decides.
Future<void> openBatteryOptimizationSettings() async {
  if (!Platform.isAndroid) return;
  try {
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  } catch (_) {
    // OEMs without the settings page land here; nothing to do.
  }
}
