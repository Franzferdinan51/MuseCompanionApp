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
import 'package:flutter/foundation.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'approval_service.dart';
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

const String _openRouterKeyKey = 'muse_openrouter_api_key';

/// OpenRouter API key for cloud TTS, kept in encrypted storage.
///
/// The key is a secret: it lives ONLY here (flutter_secure_storage), never
/// in SharedPreferences, and is never logged.
class OpenRouterKeyStore {
  const OpenRouterKeyStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  Future<String?> load() => _storage.read(key: _openRouterKeyKey);

  Future<void> save(String key) =>
      _storage.write(key: _openRouterKeyKey, value: key);

  Future<void> delete() => _storage.delete(key: _openRouterKeyKey);
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
      'auto_capture_enabled':
          _prefs.getBool('${_settingsPrefix}auto_capture_enabled') ?? false,
      'auto_capture_interval_minutes':
          _prefs.getInt('${_settingsPrefix}auto_capture_interval_minutes') ?? 60,
      'adb_info_sharing_enabled':
          _prefs.getBool('${_settingsPrefix}adb_info_sharing_enabled') ?? false,
      'usb_storage_enabled':
          _prefs.getBool('${_settingsPrefix}usb_storage_enabled') ?? true,
      'usb_serial_enabled':
          _prefs.getBool('${_settingsPrefix}usb_serial_enabled') ?? true,
      'lm_studio_enabled':
          _prefs.getBool('${_settingsPrefix}lm_studio_enabled') ?? false,
      'lm_studio_url':
          _prefs.getString('${_settingsPrefix}lm_studio_url'),
      'lm_studio_model':
          _prefs.getString('${_settingsPrefix}lm_studio_model'),
      'lm_studio_chat_model':
          _prefs.getString('${_settingsPrefix}lm_studio_chat_model'),
      'lm_studio_agent_model':
          _prefs.getString('${_settingsPrefix}lm_studio_agent_model'),
      'system_one_enabled':
          _prefs.getBool('${_settingsPrefix}system_one_enabled') ?? false,
      'system_one_url':
          _prefs.getString('${_settingsPrefix}system_one_url'),
      'voice_provider':
          _prefs.getString('${_settingsPrefix}voice_provider'),
      'openrouter_model':
          _prefs.getString('${_settingsPrefix}openrouter_model'),
      'openrouter_voice':
          _prefs.getString('${_settingsPrefix}openrouter_voice'),
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
    await _prefs.setBool(
      '${_settingsPrefix}auto_capture_enabled',
      settings.autoCaptureEnabled,
    );
    await _prefs.setInt(
      '${_settingsPrefix}auto_capture_interval_minutes',
      settings.autoCaptureIntervalMinutes,
    );
    await _prefs.setBool(
      '${_settingsPrefix}adb_info_sharing_enabled',
      settings.adbInfoSharingEnabled,
    );
    await _prefs.setBool(
      '${_settingsPrefix}usb_storage_enabled',
      settings.usbStorageEnabled,
    );
    await _prefs.setBool(
      '${_settingsPrefix}usb_serial_enabled',
      settings.usbSerialEnabled,
    );
    await _prefs.setBool(
      '${_settingsPrefix}lm_studio_enabled',
      settings.lmStudioEnabled,
    );
    await _prefs.setString(
      '${_settingsPrefix}lm_studio_url',
      settings.lmStudioUrl,
    );
    await _prefs.setString(
      '${_settingsPrefix}lm_studio_model',
      settings.lmStudioModel,
    );
    await _prefs.setString(
      '${_settingsPrefix}lm_studio_chat_model',
      settings.lmStudioChatModel,
    );
    await _prefs.setString(
      '${_settingsPrefix}lm_studio_agent_model',
      settings.lmStudioAgentModel,
    );
    await _prefs.setBool(
      '${_settingsPrefix}system_one_enabled',
      settings.systemOneEnabled,
    );
    await _prefs.setString(
      '${_settingsPrefix}system_one_url',
      settings.systemOneUrl,
    );
    await _prefs.setString(
      '${_settingsPrefix}voice_provider',
      settings.voiceProvider,
    );
    await _prefs.setString(
      '${_settingsPrefix}openrouter_model',
      settings.openRouterModel,
    );
    await _prefs.setString(
      '${_settingsPrefix}openrouter_voice',
      settings.openRouterVoice,
    );
    _notifyListeners();
  }

  final List<VoidCallback> _listeners = [];

  /// Register a callback for settings changes.
  void addListener(VoidCallback listener) => _listeners.add(listener);

  /// Remove a settings change callback.
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notifyListeners() {
    for (final l in List<VoidCallback>.from(_listeners)) {
      try {
        l();
      } catch (_) {}
    }
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

  /// Persistent "always allow" approval decisions, backed by
  /// [SharedPrefsAlwaysAllowStore].
  AlwaysAllowStore approvalAllowances() => SharedPrefsAlwaysAllowStore(_prefs);
}

const String _alwaysAllowedToolsKey = 'muse_always_allowed_tools';

/// Persists "always allow" approval decisions (tool name set) in
/// SharedPreferences. Tool names are non-secret preferences, not secrets:
/// they name capabilities ("take_photo"), never credentials.
class SharedPrefsAlwaysAllowStore implements AlwaysAllowStore {
  SharedPrefsAlwaysAllowStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  Set<String> loadAllowed() {
    final raw = _prefs.getString(_alwaysAllowedToolsKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toSet();
      }
      return <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  @override
  Future<void> setAllowed(String toolName, bool allowed) async {
    final current = loadAllowed();
    if (allowed) {
      current.add(toolName);
    } else {
      current.remove(toolName);
    }
    await _prefs.setString(_alwaysAllowedToolsKey, json.encode(current.toList()));
  }
}
