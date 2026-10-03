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

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../src/gadget/phone_actions.dart';

const MethodChannel _phoneChannel = MethodChannel('dev.musecompanion/phone');

/// One installed text-to-speech voice. [name] is the engine id that is
/// stored in settings. Empty is not used here; automatic is a separate choice.
class SpeechVoice {
  const SpeechVoice({
    required this.name,
    required this.language,
    required this.region,
    required this.quality,
    required this.network,
    required this.sameLanguage,
  });

  final String name;
  final String language;
  final String region;
  final String quality;
  final bool network;
  final bool sameLanguage;

  String get label {
    final place = region.isEmpty ? language : '$language ($region)';
    final where = network ? 'Online' : 'On device';
    final tag = speechVoiceTag(name);
    final tail = tag.isEmpty ? '' : ' · $tag';
    return '$place · $quality · $where$tail';
  }
}

/// Voices reported by the Android speech engine.
class SpeechCatalog {
  const SpeechCatalog({required this.engine, required this.voices});

  static const empty = SpeechCatalog(engine: '', voices: <SpeechVoice>[]);

  /// Package name, such as `com.google.android.tts`, or empty.
  final String engine;
  final List<SpeechVoice> voices;
}

/// A short token so two voices with the same language and quality can be
/// told apart. Language and engine words are dropped.
String speechVoiceTag(String name) {
  const skip = <String>{
    'en',
    'us',
    'uk',
    'gb',
    'local',
    'network',
    'language',
    'x',
  };
  final parts = name
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((part) => part.isNotEmpty);
  for (final part in parts.toList().reversed) {
    if (part.length < 2 || part.length > 12) continue;
    if (skip.contains(part.toLowerCase())) continue;
    return part;
  }
  return '';
}

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

  /// Remember [name] for every later speak, including Muse `phone.speak`.
  /// Empty selects the clearest voice. Failures are ignored so a desktop
  /// test or a cold engine still starts.
  Future<void> applySpeechVoice(String name) async {
    try {
      await _call<void>('setSpeechVoice', {'name': name});
    } on PhoneActionException {
      // The engine keeps the previous choice, or its automatic voice.
    }
  }

  /// Installed voices. Completes when the speech engine is ready.
  Future<SpeechCatalog> listVoices() async {
    final raw = await _call<Map>('listVoices');
    if (raw == null) return SpeechCatalog.empty;
    final engine = raw['engine'] is String ? raw['engine']! as String : '';
    final listed = raw['voices'];
    final voices = <SpeechVoice>[];
    if (listed is List) {
      for (final item in listed) {
        if (item is! Map) continue;
        final name = item['name'];
        if (name is! String || name.isEmpty) continue;
        voices.add(
          SpeechVoice(
            name: name,
            language: item['language'] is String
                ? item['language']! as String
                : '',
            region: item['region'] is String ? item['region']! as String : '',
            quality: item['quality'] is String
                ? item['quality']! as String
                : '',
            network: item['network'] == true,
            sameLanguage: item['sameLanguage'] == true,
          ),
        );
      }
    }
    return SpeechCatalog(engine: engine, voices: voices);
  }

  /// Open the system screen where higher-quality voices can be installed.
  Future<void> openTtsSettings() async {
    await _call<void>('openTtsSettings');
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
        if (Platform.isIOS) {
          throw const PhoneActionException(
            'SMS is not available on iOS - Apple does not allow apps to '
            'read or send text messages. Use iMessage sharing instead.',
          );
        }
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
