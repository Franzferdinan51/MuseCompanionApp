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
// Android phone controls behind the gadget commands. The channel is a
// no-op on desktop tests: missing plugins become a clear error instead
// of a crash. Permissions are requested here so both the chat screen
// and a Muse `link.invoke` ask the user the same way.

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../src/gadget/phone_actions.dart';

const MethodChannel _phoneChannel = MethodChannel('dev.musecompanion/phone');

class PhoneBridge implements PhoneActions {
  const PhoneBridge({MethodChannel? channel})
    : _channel = channel ?? _phoneChannel;

  final MethodChannel _channel;

  @override
  Future<Uint8List> captureJpeg({String facing = 'back'}) async {
    await _ensure(Permission.camera, 'Camera');
    final bytes = await _call<Uint8List>('captureJpeg', {'facing': facing});
    if (bytes == null || bytes.isEmpty) {
      throw const PhoneActionException('the camera returned nothing');
    }
    return bytes;
  }

  @override
  Future<Uint8List> recordWav(int seconds) async {
    await _ensure(Permission.microphone, 'Microphone');
    final bytes = await _call<Uint8List>('recordWav', {'seconds': seconds});
    if (bytes == null || bytes.isEmpty) {
      throw const PhoneActionException('the microphone returned nothing');
    }
    return bytes;
  }

  /// Hold-to-talk: start, then [stopRecording] for the WAV bytes.
  Future<void> startRecording() async {
    await _ensure(Permission.microphone, 'Microphone');
    await _call<void>('startRecording');
  }

  Future<Uint8List> stopRecording() async {
    final bytes = await _call<Uint8List>('stopRecording');
    if (bytes == null || bytes.isEmpty) {
      throw const PhoneActionException('the microphone returned nothing');
    }
    return bytes;
  }

  @override
  Future<void> speak(String text) async {
    await _call<void>('speak', {'text': text});
  }

  @override
  Future<void> openNotificationAccess() async {
    await _call<void>('openNotificationAccess');
  }

  @override
  Future<Map<String, Object?>> run(
    String command,
    Map<String, Object?> params,
  ) async {
    await _ensureFor(command);
    final raw = await _call<Map>('run', {'command': command, 'params': params});
    if (raw == null) return const {};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> _ensureFor(String command) async {
    switch (command) {
      case 'phone.location':
        await _ensure(Permission.locationWhenInUse, 'Location');
      case 'phone.call':
        await _ensure(Permission.phone, 'Phone');
      case 'phone.sms':
      case 'phone.messages':
        await _ensure(Permission.sms, 'SMS');
      case 'phone.contacts':
        await _ensure(Permission.contacts, 'Contacts');
      case 'phone.events':
        await _ensure(Permission.calendarFullAccess, 'Calendar');
      case 'phone.notify':
        await _ensure(Permission.notification, 'Notifications');
    }
  }

  Future<void> _ensure(Permission permission, String name) async {
    try {
      var status = await permission.status;
      if (!status.isGranted) {
        status = await permission.request();
      }
      if (!status.isGranted) {
        throw PhoneActionException('$name permission is not granted');
      }
    } on PhoneActionException {
      rethrow;
    } on MissingPluginException {
      throw const PhoneActionException('phone controls need the Android app');
    } on PlatformException catch (e) {
      throw PhoneActionException(e.message ?? '$name permission failed');
    }
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PhoneActionException {
      rethrow;
    } on MissingPluginException {
      throw const PhoneActionException('phone controls need the Android app');
    } on PlatformException catch (e) {
      throw PhoneActionException(
        e.message?.isNotEmpty == true ? e.message! : e.code,
      );
    }
  }
}
