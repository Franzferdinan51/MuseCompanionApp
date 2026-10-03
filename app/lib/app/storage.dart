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
// App-layer persistence for the companion app.
//
// Bridges the gadget stack's storage abstractions (PairingStore, Identity) and
// the settings surface to Flutter's secure/plain storage backends. The pairing
// record holds secrets, so it lives in flutter_secure_storage; settings and the
// last caption are non-secret and live in shared_preferences.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model.dart';

const String _pairingKey = 'muse_pairing_record';
const String _identityKey = 'muse_identity_mac';
const String _sdkTokenKey = 'muse_sdk_token';
const String _settingsPrefix = 'muse_settings_';
const String _statusKey = 'muse_last_status';
const String _introKey = 'muse_intro_sent';

/// PairingStore backed by encrypted device storage.
class SecurePairingStore implements PairingStore {
  SecurePairingStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, Object?>?> load() async {
    final raw = await _storage.read(key: _pairingKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = json.decode(raw) as Map<String, dynamic>;
    return decoded.cast<String, Object?>();
  }

  @override
  Future<void> save(Map<String, Object?> pairing) async {
    await _storage.write(key: _pairingKey, value: json.encode(pairing));
  }

  @override
  Future<void> delete() async {
    await _storage.delete(key: _pairingKey);
  }
}

/// Optional gadgets.muse.ai SDK token, kept in encrypted storage.
///
/// Community gadgets pair and run without one; when set, the service
/// reports it on token refresh so API-side gadget features light up.
class SecureSdkTokenStore {
  SecureSdkTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<String?> load() => _storage.read(key: _sdkTokenKey);

  Future<void> save(String token) =>
      _storage.write(key: _sdkTokenKey, value: token);

  Future<void> delete() => _storage.delete(key: _sdkTokenKey);
}

/// A stable device identity persisted across upgrades and unpairings.
class PersistentIdentity {
  PersistentIdentity(this._identity);

  final Identity _identity;

  Identity get identity => _identity;

  static Future<PersistentIdentity> loadOrCreate(
    FlutterSecureStorage storage,
  ) async {
    final saved = await storage.read(key: _identityKey);
    final mac = (saved != null && saved.isNotEmpty && isValidIdentityMac(saved))
        ? saved
        : generateMac();
    if (saved == null || saved != mac) {
      await storage.write(key: _identityKey, value: mac);
    }
    return PersistentIdentity(Identity(mac));
  }
}

/// Non-secret settings and the last caption, persisted via shared_preferences.
class SettingsStore {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SettingsStore> init() async =>
      SettingsStore(await SharedPreferences.getInstance());

  CompanionSettings loadSettings() {
    if (!_prefs.containsKey('${_settingsPrefix}theme')) {
      return const CompanionSettings();
    }
    return CompanionSettings.fromMap({
      'theme': _prefs.getString('${_settingsPrefix}theme'),
      'keep_screen_on':
          _prefs.getBool('${_settingsPrefix}keep_screen_on') ?? false,
      'speak_replies':
          _prefs.getBool('${_settingsPrefix}speak_replies') ?? true,
      'allow_calls': _prefs.getBool('${_settingsPrefix}allow_calls') ?? false,
      'allow_send_sms':
          _prefs.getBool('${_settingsPrefix}allow_send_sms') ?? false,
      'speech_volume': _prefs.getInt('${_settingsPrefix}speech_volume'),
      'speech_voice': _prefs.getString('${_settingsPrefix}speech_voice'),
      'camera_facing': _prefs.getString('${_settingsPrefix}camera_facing'),
    });
  }

  Future<void> saveSettings(CompanionSettings settings) async {
    await _prefs.setString('${_settingsPrefix}theme', settings.theme);
    await _prefs.setBool(
      '${_settingsPrefix}keep_screen_on',
      settings.keepScreenOn,
    );
    await _prefs.setBool(
      '${_settingsPrefix}speak_replies',
      settings.speakReplies,
    );
    await _prefs.setBool('${_settingsPrefix}allow_calls', settings.allowCalls);
    await _prefs.setBool(
      '${_settingsPrefix}allow_send_sms',
      settings.allowSendSms,
    );
    await _prefs.setInt(
      '${_settingsPrefix}speech_volume',
      settings.speechVolume,
    );
    await _prefs.setString(
      '${_settingsPrefix}speech_voice',
      settings.speechVoice,
    );
    await _prefs.setString(
      '${_settingsPrefix}camera_facing',
      settings.cameraFacing,
    );
  }

  String loadStatus() => _prefs.getString(_statusKey) ?? '';

  Future<void> saveStatus(String text) async {
    await _prefs.setString(_statusKey, text);
  }

  /// Whether the one-time setup message was already accepted by Muse.
  ///
  /// Opening the app starts a new process. Without this, every launch
  /// posts the initialize message again.
  bool loadIntroSent() => _prefs.getBool(_introKey) ?? false;

  Future<void> saveIntroSent(bool sent) async {
    await _prefs.setBool(_introKey, sent);
  }
}
