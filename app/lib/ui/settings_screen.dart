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
// The settings surface: color theme, keep-screen-on, spoken replies, camera
// facing, permission grants, and the opt-in gates for real calls and texts.
// Values load from SettingsStore on entry and are persisted (and pushed to
// the presentation state) as the user changes them. Theme, keep-screen-on
// and spoken replies are also writable by the Muse through
// `companion.set_display`. Calls, texts, the saved camera, speech volume,
// the spoken voice, and Screen control are not: only this screen, or the
// system Accessibility page it opens, can change those.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../app/wake_word.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/foreground.dart';
import '../app/lmstudio_client.dart';
import '../app/model.dart';
import '../app/phone_bridge.dart';
import '../app/openrouter_tts.dart';
import '../app/storage.dart';
import '../src/gadget/phone_actions.dart';
import '../src/gadget/service.dart';
import '../src/gadget/chat_events.dart';
import 'dashboard_screen.dart';
import 'diagnostics_screen.dart';
import 'memory_screen.dart';
import 'muse_theme.dart';
import 'pairing_screen.dart';
import 'scope.dart';
import '../app/approval_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onSendChat, this.onBack});

  /// Callback to post a message to the Muse chat.
  final Future<Map<String, Object?>> Function(String, List<ChatAttachment>)?
      onSendChat;

  /// Back navigation for the detail-page pattern (dock is hidden here).
  final VoidCallback? onBack;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late CompanionSettings _settings;
  StreamSubscription<ConnectionState>? _connectionSub;
  ConnectionState _connection = ConnectionState.unpaired;
  bool _unpairing = false;
  bool? _serviceRunning;
  bool _serviceBusy = false;
  bool? _sdkSet;
  bool _grantsArmed = false;
  Map<String, Object?> _grants = const {};
  List<SpeechVoice> _voices = const [];
  String _speechEngine = '';
  bool _voicesLoaded = false;
  bool _voicesArmed = false;
  bool _showAllVoices = false;
  int _voiceLookupGeneration = 0;
  Timer? _voiceLookup;
  String? _adbInfoStatus;
  String _wakeStatus = 'Off.';

  // OpenRouter voice (opt-in cloud TTS for testing). The Android TTS path
  // above is untouched; these controls only configure the alternative.
  final TextEditingController _openRouterModelController =
      TextEditingController();
  final TextEditingController _openRouterKeyController =
      TextEditingController();
  final TextEditingController _openRouterVoiceController =
      TextEditingController();
  final TextEditingController _haUrlController = TextEditingController();
  final TextEditingController _mqttHostController = TextEditingController();
  final TextEditingController _mqttPortController = TextEditingController();
  final TextEditingController _mqttUserController = TextEditingController();
  final TextEditingController _mqttPrefixController = TextEditingController();
  bool _homeArmed = false;
  bool _haTokenSaved = false;
  bool _mqttPasswordSaved = false;
  bool _obscureOpenRouterKey = true;
  bool _openRouterKeySaved = false;
  bool _openRouterArmed = false;
  bool _testingOpenRouter = false;
  String? _openRouterTestResult;
  OpenRouterTts? _openRouterTestTts;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _refreshGrants();
    if (_voicesLoaded && _voices.isEmpty) {
      _voicesLoaded = false;
      _loadVoices();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _settings = scope.settings.loadSettings();
    if (!_homeArmed) {
      _homeArmed = true;
      _haUrlController.text = _settings.homeAssistantBaseUrl;
      _mqttHostController.text = _settings.mqttHost;
      _mqttPortController.text = _settings.mqttPort.toString();
      _mqttUserController.text = _settings.mqttUsername;
      _mqttPrefixController.text = _settings.mqttTopicPrefix;
      const HomeSecretsStore().loadHomeAssistantToken().then((saved) {
        if (mounted) {
          setState(
            () => _haTokenSaved = saved != null && saved.isNotEmpty,
          );
        }
      }).catchError((_) {});
      const HomeSecretsStore().loadMqttPassword().then((saved) {
        if (mounted) {
          setState(
            () => _mqttPasswordSaved = saved != null && saved.isNotEmpty,
          );
        }
      }).catchError((_) {});
    }
    if (!_openRouterArmed) {
      _openRouterArmed = true;
      _openRouterModelController.text = _settings.openRouterModel;
      _openRouterVoiceController.text = _settings.openRouterVoice;
      // Never fill the key field with the saved key; show saved/not-saved
      // state instead.
      const OpenRouterKeyStore().load().then((saved) {
        if (mounted) {
          setState(
            () => _openRouterKeySaved = saved != null && saved.isNotEmpty,
          );
        }
      }).catchError((_) {});
    }
    _connectionSub?.cancel();
    _connection = scope.service.connectionState;
    _connectionSub = scope.service.onStateChanged.listen((state) {
      if (mounted) setState(() => _connection = state);
    });
    _refreshServiceState();
    _refreshWakeStatus();
    scope.sdkTokens
        .load()
        .then((saved) {
          if (mounted) {
            setState(() => _sdkSet = saved != null && saved.isNotEmpty);
          }
        })
        .catchError((_) {
          if (mounted) setState(() => _sdkSet = false);
        });
    if (!_grantsArmed) {
      _grantsArmed = true;
      _refreshGrants();
    }
    if (!_voicesArmed) {
      _voicesArmed = true;
      _loadVoices();
    }
  }

  Future<void> _loadVoices() async {
    final phone = AppScope.of(context).phone;
    final generation = ++_voiceLookupGeneration;
    _voiceLookup?.cancel();
    // A widget test has no speech engine, so this lookup never answers.
    // The timer is cancelled in dispose and must not outlive the screen.
    _voiceLookup = Timer(const Duration(seconds: 8), () {
      if (!mounted || generation != _voiceLookupGeneration) return;
      setState(() => _voicesLoaded = true);
    });
    try {
      final catalog = await phone.listVoices();
      if (generation != _voiceLookupGeneration) return;
      _voiceLookup?.cancel();
      _voiceLookup = null;
      if (!mounted) return;
      setState(() {
        _voices = catalog.voices;
        _speechEngine = catalog.engine;
        _voicesLoaded = true;
      });
    } on PhoneActionException {
      if (generation != _voiceLookupGeneration) return;
      _voiceLookup?.cancel();
      _voiceLookup = null;
      if (!mounted) return;
      setState(() => _voicesLoaded = true);
    }
  }

  Future<void> _refreshGrants() async {
    try {
      final raw = await AppScope.of(
        context,
      ).phone.run('phone.capabilities', {});
      if (!mounted) return;
      setState(() => _grants = raw);
    } on PhoneActionException {
      // A desktop test or a missing plugin leaves the grant row empty.
    }
  }

  Future<void> _refreshServiceState() async {
    final running = await isLinkServiceRunning();
    if (mounted) setState(() => _serviceRunning = running);
  }

  /// Generic obscured secret dialog for the Home section: pre-fills from
  /// secure storage, saves (or clears when empty) through [save].
  Future<void> _editHomeSecret({
    required String title,
    required String label,
    required bool saved,
    required Future<String?> Function() load,
    required Future<void> Function(String value) save,
  }) async {
    String initial = '';
    try {
      initial = await load() ?? '';
    } catch (_) {
      initial = '';
    }
    if (!mounted) return;
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              saved
                  ? 'A value is saved (never shown). Enter a new one to '
                      'replace it, or empty to clear.'
                  : 'Stored in encrypted storage. Empty clears it.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: label,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    try {
      await save(result);
    } catch (_) {}
  }

  Future<void> _editSdkToken() async {
    final scope = AppScope.of(context);
    String initial = '';
    try {
      initial = await scope.sdkTokens.load() ?? '';
    } catch (_) {
      initial = '';
    }
    if (!mounted) return;
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SDK token'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Optional. From gadgets.muse.ai — reported on token refresh '
              'for developer gadget features. Empty clears it.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'SDK token',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    try {
      if (result.isEmpty) {
        await scope.sdkTokens.delete();
      } else {
        await scope.sdkTokens.save(result);
      }
      scope.service.setSdkToken(result.isEmpty ? null : result);
      scope.service.wake();
      setState(() => _sdkSet = result.isNotEmpty);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the SDK token.')),
      );
    }
  }

  Future<void> _toggleService() async {
    final scope = AppScope.of(context);
    setState(() => _serviceBusy = true);
    try {
      if (_serviceRunning == true) {
        await stopLinkService();
      } else {
        await startLinkService(
          linkNotificationText(
            scope.service.connectionState.name,
            scope.service.statusDetail,
            scope.service.agentName,
          ),
        );
      }
      await _refreshServiceState();
    } finally {
      if (mounted) setState(() => _serviceBusy = false);
    }
  }

  @override
  void dispose() {
    _openRouterModelController.dispose();
    _openRouterKeyController.dispose();
    _openRouterVoiceController.dispose();
    _haUrlController.dispose();
    _mqttHostController.dispose();
    _mqttPortController.dispose();
    _mqttUserController.dispose();
    _mqttPrefixController.dispose();
    _openRouterTestTts?.dispose();
    _voiceLookup?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _connectionSub?.cancel();
    super.dispose();
  }

  /// Display ADB connection info on demand.
  /// Shows USB/wireless debugging status, port, model, serial.
  String? _adbInfoText;

  Future<void> _shareAdbInfo() async {
    setState(() {
      _adbInfoStatus = 'Collecting ADB info...';
      _adbInfoText = null;
    });
    try {
      final phone = const PhoneBridge();
      final info = await phone.adbInfo();
      final adbOn = info['adb_enabled'] == true;
      final wifiOn = info['wifi_adb_enabled'] == true;
      final wifiPort = info['wifi_adb_port'] ?? 0;
      final model = info['model'] ?? 'unknown';
      final serial = info['serial'] ?? 'unknown';
      final text =
          'USB debugging: ${adbOn ? 'enabled' : 'disabled'}\n'
          'Wireless debugging: ${wifiOn ? 'enabled' : 'disabled'}'
          '${wifiOn && wifiPort != 0 ? ' (port $wifiPort)' : ''}\n'
          'Model: $model\nSerial: $serial';
      setState(() {
        _adbInfoStatus = text;
        _adbInfoText = text;
      });
    } catch (e) {
      setState(() => _adbInfoStatus = 'Error: $e');
    }
  }

  Future<void> _sendAdbInfoToChat() async {
    final text = _adbInfoText;
    final send = widget.onSendChat;
    if (text == null || send == null) return;
    setState(() => _adbInfoStatus = 'Sending to chat...');
    try {
      final result = await send('ADB info from ${DateTime.now()}:\n$text', []);
      if (result['ok'] == true) {
        setState(() => _adbInfoStatus = '$_adbInfoText\n\nSent to chat.');
      } else {
        setState(() => _adbInfoStatus =
            '$_adbInfoText\n\nFailed: ${result['error'] ?? 'unknown'}');
      }
    } catch (e) {
      setState(
          () => _adbInfoStatus = '$_adbInfoText\n\nError: $e');
    }
  }

  /// Save the typed API key to encrypted storage (or delete it when
  /// the field is empty). Updates the PhoneBridge routing immediately.
  Future<void> _saveOpenRouterKey() async {
    final key = _openRouterKeyController.text.trim();
    const store = OpenRouterKeyStore();
    if (key.isEmpty) {
      await store.delete();
    } else {
      await store.save(key);
    }
    PhoneBridge.openRouterApiKey = key.isEmpty ? null : key;
    if (!mounted) return;
    setState(() {
      _openRouterKeySaved = key.isNotEmpty;
      _openRouterKeyController.clear();
      _openRouterTestResult = key.isEmpty ? 'API key removed.' : null;
    });
  }

  /// Speak a short phrase through the configured OpenRouter settings so
  /// the user can verify the key and model work.
  Future<void> _testOpenRouterVoice() async {
    if (_testingOpenRouter) return;
    final typedKey = _openRouterKeyController.text.trim();
    final key = typedKey.isNotEmpty
        ? typedKey
        : await const OpenRouterKeyStore().load() ?? '';
    if (key.isEmpty) {
      setState(() => _openRouterTestResult = 'Save an API key first.');
      return;
    }
    final typedModel = _openRouterModelController.text.trim();
    final model =
        typedModel.isNotEmpty ? typedModel : _settings.openRouterModel;
    setState(() {
      _testingOpenRouter = true;
      _openRouterTestResult = null;
    });
    try {
      _openRouterTestTts = OpenRouterTts();
      await _openRouterTestTts!.synthesizeAndPlay(
        text: 'This is a test of the OpenRouter voice.',
        apiKey: key,
        model: model,
        voice: _openRouterVoiceController.text.trim(),
      );
      if (mounted) {
        setState(() => _openRouterTestResult = 'Voice test played.');
      }
    } on OpenRouterTtsException catch (e) {
      if (mounted) setState(() => _openRouterTestResult = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _openRouterTestResult = 'Voice test failed.');
      }
    } finally {
      await _openRouterTestTts?.dispose();
      _openRouterTestTts = null;
      if (mounted) setState(() => _testingOpenRouter = false);
    }
  }

  /// Recompute the wake-word status line from settings + device state.
  Future<void> _refreshWakeStatus() async {
    String status;
    if (!_settings.wakeWordEnabled) {
      status = 'Off.';
    } else if (!await Permission.microphone.isGranted) {
      status = 'Microphone permission not granted.';
    } else {
      status = 'Ready — listening for "$wakeWordUiLabel" on the companion screen.';
    }
    if (!mounted) return;
    setState(() => _wakeStatus = status);
  }

  Future<void> _commitWake(CompanionSettings next) async {
    await _commit(next);
    await _refreshWakeStatus();
  }

  Future<void> _requestWakeMic() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Microphone permission is required for wake word detection.',
          ),
        ),
      );
    }
    await _refreshWakeStatus();
  }

  Future<void> _commit(CompanionSettings next) async {
    final scope = AppScope.of(context);
    // In-memory first: settings listeners (e.g. syncSpeakEnabled in main.dart)
    // read presentation.settings, so it must be fresh before saveSettings
    // fires its notifications. (2026-10-04: fixed speak toggle not restoring
    // voice - the listener was reading the stale pre-toggle value.)
    scope.presentation.applySettings(next);
    await scope.settings.saveSettings(next);
    if (!mounted) return;
    setState(() => _settings = next);
  }

  String _voiceSummary() {
    final name = _settings.speechVoice;
    if (name.isEmpty) return 'Automatic';
    for (final voice in _voices) {
      if (voice.name == name) return voice.label;
    }
    if (!_voicesLoaded) return 'Saved voice';
    return 'Automatic';
  }

  String _voiceSubtitle() {
    if (!_voicesLoaded) return 'Looking up voices…';
    final engine = switch (_speechEngine) {
      'com.google.android.tts' => 'Google speech engine',
      '' => 'Speech engine',
      _ => "This phone's speech engine",
    };
    final name = _settings.speechVoice;
    final missing =
        name.isNotEmpty && !_voices.any((voice) => voice.name == name);
    if (missing) {
      return '$engine. The saved voice is not installed, so the clearest voice is used.';
    }
    if (name.isEmpty) return '$engine. Clearest voice for this language.';
    return engine;
  }

  List<SpeechVoice> _visibleVoices() {
    if (_showAllVoices) return _voices;
    final same = _voices.where((voice) => voice.sameLanguage).toList();
    final selected = _settings.speechVoice;
    if (selected.isEmpty || same.any((voice) => voice.name == selected)) {
      return same;
    }
    return [...same, ..._voices.where((voice) => voice.name == selected)];
  }

  Future<void> _openVoicePicker() async {
    final hasOthers = _voices.any((voice) => !voice.sameLanguage);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final shown = _visibleVoices();
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.6,
            child: Column(
              children: [
                if (hasOthers)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(
                        sheetContext,
                      ).pop(_showAllVoices ? '__language__' : '__all__'),
                      child: Text(
                        _showAllVoices ? 'This language' : 'Other languages',
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      ListTile(
                        title: const Text('Automatic'),
                        subtitle: const Text('Clearest voice for this phone'),
                        selected: _settings.speechVoice.isEmpty,
                        onTap: () => Navigator.of(sheetContext).pop(''),
                      ),
                      for (final voice in shown)
                        ListTile(
                          title: Text(voice.label),
                          selected: voice.name == _settings.speechVoice,
                          onTap: () =>
                              Navigator.of(sheetContext).pop(voice.name),
                        ),
                      if (shown.isEmpty)
                        const ListTile(
                          title: Text('No other voices are installed'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || chosen == null) return;
    if (chosen == '__all__' || chosen == '__language__') {
      setState(() => _showAllVoices = chosen == '__all__');
      await _openVoicePicker();
      return;
    }
    await _pickVoice(chosen);
  }

  Future<void> _pickVoice(String name) async {
    final next = _settings.copyWith(speechVoice: name);
    await _commit(next);
    if (!mounted) return;
    final phone = AppScope.of(context).phone;
    try {
      await phone.applySpeechVoice(next.speechVoice);
      await phone.run('phone.volume', {'level': next.speechVolume});
      await phone.speak('Hi, this is how I sound.');
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _openTtsSettings() async {
    try {
      await AppScope.of(context).phone.openTtsSettings();
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _unpair() async {
    final scope = AppScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unpair this companion?'),
        content: const Text(
          'The saved credentials are deleted and the connection drops. '
          'The device identity is kept, so re-pairing advertises the same name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _unpairing = true);
    try {
      // Restart the loop so the open session drops and the unpaired
      // state surfaces immediately.
      await scope.service.stop();
      await scope.service.unpair();
      unawaited(scope.service.start());
    } finally {
      if (mounted) setState(() => _unpairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MusePage(
      appBar: AppBar(
        title: const Text('Companion Settings'),
        leading: widget.onBack == null
            ? null
            : BackButton(onPressed: widget.onBack),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        children: [
          _PairingCard(
            connection: _connection,
            unpairing: _unpairing,
            onUnpair: _unpair,
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'SDK token',
            child: Row(
              children: [
                Icon(
                  Icons.key_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _sdkSet == null
                        ? 'Checking…'
                        : _sdkSet == true
                        ? 'Set — reported on token refresh.'
                        : 'Not set — pairing works without it.',
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _editSdkToken,
                  child: Text(_sdkSet == true ? 'Edit' : 'Set'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Background connection',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.notifications_active_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _serviceRunning == null
                            ? 'Checking…'
                            : _serviceRunning == true
                            ? 'Keep-alive is running — the link survives in the background.'
                            : 'Keep-alive is off — Android may drop the link in the background.',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.tonal(
                      onPressed: _serviceBusy ? null : _toggleService,
                      child: Text(
                        _serviceRunning == true
                            ? 'Stop keep-alive'
                            : 'Start keep-alive',
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: openBatteryOptimizationSettings,
                      child: const Text('Battery settings'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Dashboard',
            child: Row(
              children: [
                Icon(
                  Icons.dashboard_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Character, caption, and whether commands are getting through',
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DashboardScreen(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Diagnostics',
            child: Row(
              children: [
                Icon(
                  Icons.bug_report_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Link state, device identity and the setup log'),
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DiagnosticsScreen(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Agent memory',
            child: Row(
              children: [
                Icon(
                  Icons.psychology_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Facts the on-device agent remembers about you, '
                    'stored only on this phone',
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const MemoryScreen(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Theme',
            child: Row(
              children: [
                Icon(Icons.palette_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final option in CompanionSettings.themeOptions)
                        ChoiceChip(
                          label: Text(
                            '${option[0].toUpperCase()}${option.substring(1)}',
                          ),
                          selected: _settings.theme == option,
                          onSelected: (_) =>
                              _commit(_settings.copyWith(theme: option)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Keep screen on',
            child: Row(
              children: [
                const Icon(Icons.visibility_outlined),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Keep the display awake while the companion screen is visible',
                  ),
                ),
                Switch(
                  value: _settings.keepScreenOn,
                  onChanged: (v) =>
                      _commit(_settings.copyWith(keepScreenOn: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Speak replies',
            child: Row(
              children: [
                const Icon(Icons.record_voice_over_outlined),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Read Muse replies aloud on this phone'),
                ),
                Switch(
                  value: _settings.speakReplies,
                  onChanged: (v) =>
                      _commit(_settings.copyWith(speakReplies: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Speech volume',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'How loud spoken replies are. Same idea as the volume dial on a Muse voice gadget.',
                ),
                Row(
                  children: [
                    const Icon(Icons.volume_up_outlined),
                    Expanded(
                      child: Slider(
                        value: _settings.speechVolume.toDouble(),
                        min: 0,
                        max: 100,
                        divisions: 10,
                        label: '${_settings.speechVolume}',
                        onChanged: (v) => _commit(
                          _settings.copyWith(speechVolume: v.round()),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text('${_settings.speechVolume}'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Voice',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Spoken replies use the clearest voice on this phone. Pick one to hear a sample. Muse cannot change this.',
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.record_voice_over_outlined),
                  title: Text(_voiceSummary()),
                  subtitle: Text(_voiceSubtitle()),
                  trailing: const Icon(Icons.unfold_more),
                  onTap: _openVoicePicker,
                ),
                TextButton(
                  onPressed: _openTtsSettings,
                  child: const Text('Get clearer voices'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Voice provider',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Android TTS is the default and stays as-is. OpenRouter '
                  'is an opt-in cloud voice for testing.',
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'android',
                      label: Text('Android TTS'),
                      icon: Icon(Icons.smartphone_outlined),
                    ),
                    ButtonSegment(
                      value: 'openrouter',
                      label: Text('OpenRouter'),
                      icon: Icon(Icons.cloud_outlined),
                    ),
                  ],
                  selected: {_settings.voiceProvider},
                  onSelectionChanged: (next) => _commit(
                    _settings.copyWith(voiceProvider: next.first),
                  ),
                ),
                if (_settings.voiceProvider == 'openrouter') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _openRouterModelController,
                    decoration: const InputDecoration(
                      labelText: 'Model',
                      hintText: 'fish-audio/s2.1-pro-free:free',
                      helperText: 'OpenRouter changes free models often - '
                          'update this when they do.',
                    ),
                    onSubmitted: (v) => _commit(
                      _settings.copyWith(openRouterModel: v.trim()),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _openRouterKeyController,
                    obscureText: _obscureOpenRouterKey,
                    decoration: InputDecoration(
                      labelText: 'API key',
                      hintText: _openRouterKeySaved
                          ? 'Key saved - paste a new one to replace it'
                          : 'Paste your OpenRouter API key',
                      helperText: _openRouterKeySaved
                          ? 'A key is saved in secure storage.'
                          : 'Stored encrypted on this phone, never logged.',
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              _obscureOpenRouterKey
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            tooltip: _obscureOpenRouterKey
                                ? 'Show key'
                                : 'Hide key',
                            onPressed: () => setState(
                              () => _obscureOpenRouterKey =
                                  !_obscureOpenRouterKey,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.save_outlined),
                            tooltip: 'Save key',
                            onPressed: _saveOpenRouterKey,
                          ),
                        ],
                      ),
                    ),
                    onSubmitted: (_) => _saveOpenRouterKey(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _openRouterVoiceController,
                    decoration: const InputDecoration(
                      labelText: 'Voice id (optional)',
                      hintText: 'Fish Audio reference id',
                      helperText:
                          "Leave empty for the model's default voice.",
                    ),
                    onSubmitted: (v) => _commit(
                      _settings.copyWith(openRouterVoice: v.trim()),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'fish-audio/s2.1-pro-free is free on OpenRouter.',
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed:
                        _testingOpenRouter ? null : _testOpenRouterVoice,
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: Text(
                      _testingOpenRouter ? 'Testing...' : 'Test voice',
                    ),
                  ),
                  if (_openRouterTestResult != null) ...[
                    const SizedBox(height: 8),
                    Text(_openRouterTestResult!),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Wake word',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Say "$wakeWordUiLabel" on the companion screen to start a '
                  'voice note \u2014 no hands needed. Detection runs on-device '
                  'via openWakeWord: three tiny TFLite models on 16kHz '
                  'audio, no account, no cloud, no streaming, no full '
                  'speech recognition. Audio never leaves your phone.',
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Listen for "$wakeWordLabel"'),
                  subtitle: const Text(
                    'Opt-in. Only runs on the companion screen.',
                  ),
                  value: _settings.wakeWordEnabled,
                  onChanged: (v) => _commitWake(
                    _settings.copyWith(wakeWordEnabled: v),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keyword'),
                  subtitle: Text('"$wakeWordUiLabel"'),
                  trailing: TextButton(
                    onPressed: _requestWakeMic,
                    child: const Text('Grant mic'),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.tune_outlined),
                    Expanded(
                      child: Slider(
                        value: _settings.wakeWordSensitivity,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        label:
                            '${(_settings.wakeWordSensitivity * 100).round()}%',
                        onChanged: (v) => _commitWake(
                          _settings.copyWith(wakeWordSensitivity: v),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${(_settings.wakeWordSensitivity * 100).round()}%',
                      ),
                    ),
                  ],
                ),
                const Text(
                  'Sensitivity: higher hears more (and false-alarms more).',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  'Status: $_wakeStatus',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Battery: the mic stays open while the companion screen '
                  'is in the foreground. openWakeWord is built for this \u2014 '
                  'three tiny on-device TFLite models, roughly 1\u20133% per '
                  'hour on most phones. Detection pauses automatically when the app '
                  'is backgrounded, the screen sleeps, or a voice note '
                  'records, so the drain is bounded by active screen time. '
                  'It does not listen on the lock screen.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Camera',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The camera button and vision.capture use this camera unless Muse names the other one.',
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'back',
                      label: Text('Back'),
                      icon: Icon(Icons.camera_rear_outlined),
                    ),
                    ButtonSegment(
                      value: 'front',
                      label: Text('Front'),
                      icon: Icon(Icons.camera_front_outlined),
                    ),
                  ],
                  selected: {_settings.cameraFacing},
                  onSelectionChanged: (next) =>
                      _commit(_settings.copyWith(cameraFacing: next.first)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'USB',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'USB devices plugged in over OTG. Muse can browse flash '
                  'drives and talk to serial devices. Turn either off to '
                  'block those commands.',
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('USB storage (OTG)'),
                  subtitle: const Text(
                    'Flash drives: list, browse, and read files',
                  ),
                  value: _settings.usbStorageEnabled,
                  onChanged: (v) => _commit(
                    _settings.copyWith(usbStorageEnabled: v),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('USB serial'),
                  subtitle: const Text(
                    'Serial devices: open ports, send and receive data',
                  ),
                  value: _settings.usbSerialEnabled,
                  onChanged: (v) => _commit(
                    _settings.copyWith(usbSerialEnabled: v),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Home',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Smart-home integrations for Muse: Home Assistant '
                  'states and services, MQTT publishes. Both strictly '
                  'opt-in. Tokens and passwords stay in encrypted '
                  'storage — commands can never read or change them.',
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Home Assistant'),
                  subtitle: const Text(
                    'Read states and call services (needs URL + token)',
                  ),
                  value: _settings.homeAssistantEnabled,
                  onChanged: (v) => _commit(
                    _settings.copyWith(homeAssistantEnabled: v),
                  ),
                ),
                if (_settings.homeAssistantEnabled) ...[
                  TextField(
                    controller: _haUrlController,
                    keyboardType: TextInputType.url,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'http://homeassistant.local:8123',
                    ),
                    onSubmitted: (v) => _commit(
                      _settings.copyWith(homeAssistantBaseUrl: v.trim()),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _haTokenSaved
                          ? 'Token saved — enter a new one to replace it'
                          : 'Long-lived access token (Profile → Security)',
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: () => _editHomeSecret(
                        title: 'Home Assistant token',
                        label: 'Long-lived access token',
                        saved: _haTokenSaved,
                        load: const HomeSecretsStore().loadHomeAssistantToken,
                        save: (v) async {
                          if (v.isEmpty) {
                            await const HomeSecretsStore()
                                .deleteHomeAssistantToken();
                          } else {
                            await const HomeSecretsStore()
                                .saveHomeAssistantToken(v);
                          }
                          if (mounted) {
                            setState(() => _haTokenSaved = v.isNotEmpty);
                          }
                        },
                      ),
                      child: Text(_haTokenSaved ? 'Replace' : 'Set token'),
                    ),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('MQTT'),
                  subtitle: const Text(
                    'Publish under one topic prefix (needs broker host)',
                  ),
                  value: _settings.mqttEnabled,
                  onChanged: (v) => _commit(
                    _settings.copyWith(mqttEnabled: v),
                  ),
                ),
                if (_settings.mqttEnabled) ...[
                  TextField(
                    controller: _mqttHostController,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Broker host',
                      hintText: '192.168.1.10',
                    ),
                    onSubmitted: (v) => _commit(
                      _settings.copyWith(mqttHost: v.trim()),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _mqttPortController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Broker port',
                      hintText: '1883 (8883 for TLS)',
                    ),
                    onSubmitted: (v) {
                      final port = int.tryParse(v.trim());
                      if (port == null) return;
                      _commit(_settings.copyWith(mqttPort: port));
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _mqttUserController,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Username (optional)',
                      hintText: 'Empty for anonymous',
                    ),
                    onSubmitted: (v) => _commit(
                      _settings.copyWith(mqttUsername: v.trim()),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _mqttPrefixController,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Topic prefix',
                      hintText: 'muse/',
                      helperText:
                          'Agent publishes stay under this prefix.',
                    ),
                    onSubmitted: (v) => _commit(
                      _settings.copyWith(mqttTopicPrefix: v.trim()),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _mqttPasswordSaved
                          ? 'Password saved — enter a new one to replace it'
                          : 'Broker password (optional)',
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: () => _editHomeSecret(
                        title: 'MQTT password',
                        label: 'Broker password',
                        saved: _mqttPasswordSaved,
                        load: const HomeSecretsStore().loadMqttPassword,
                        save: (v) async {
                          if (v.isEmpty) {
                            await const HomeSecretsStore()
                                .deleteMqttPassword();
                          } else {
                            await const HomeSecretsStore().saveMqttPassword(v);
                          }
                          if (mounted) {
                            setState(
                              () => _mqttPasswordSaved = v.isNotEmpty,
                            );
                          }
                        },
                      ),
                      child: Text(_mqttPasswordSaved ? 'Replace' : 'Set password'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Local AI (LM Studio)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Let a local model control the phone through LM Studio, '
                  'bypassing the Muse link. The model gets phone tools and '
                  'runs tasks on-device.',
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable local AI'),
                  subtitle: const Text(
                    'Allow local models to run phone tasks',
                  ),
                  value: _settings.lmStudioEnabled,
                  onChanged: (v) => _commit(
                    _settings.copyWith(lmStudioEnabled: v),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: _settings.lmStudioUrl,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'http://100.68.208.113:1234',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  onChanged: (v) => _commit(
                    _settings.copyWith(lmStudioUrl: v.trim()),
                  ),
                ),
                const SizedBox(height: 8),
                _ModelSelector(
                  serverUrl: _settings.lmStudioUrl,
                  label: 'Chat model',
                  selectedModel: _settings.lmStudioChatModel,
                  onChanged: (v) => _commit(
                    _settings.copyWith(lmStudioChatModel: v),
                  ),
                ),
                const SizedBox(height: 8),
                _ModelSelector(
                  serverUrl: _settings.lmStudioUrl,
                  label: 'Agent model',
                  selectedModel: _settings.lmStudioAgentModel,
                  onChanged: (v) => _commit(
                    _settings.copyWith(lmStudioAgentModel: v),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use SystemOne tool routing'),
                  subtitle: const Text(
                    'Narrow the phone tool list per task via SystemOne',
                  ),
                  value: _settings.systemOneEnabled,
                  onChanged: (v) => _commit(
                    _settings.copyWith(systemOneEnabled: v),
                  ),
                ),
                if (_settings.systemOneEnabled) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: _settings.systemOneUrl,
                    decoration: const InputDecoration(
                      labelText: 'SystemOne URL',
                      hintText: 'http://100.68.208.113:8765',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    onChanged: (v) => _commit(
                      _settings.copyWith(systemOneUrl: v.trim()),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: _TestLmStudioButton(settings: _settings),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Auto-capture',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Automatically take photos and post them to the Muse chat. '
                  'Works without remote commands.',
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Enable auto-capture'),
                  value: _settings.autoCaptureEnabled,
                  onChanged: (v) => _commit(
                    _settings.copyWith(autoCaptureEnabled: v),
                  ),
                ),
                if (_settings.autoCaptureEnabled) ...[
                  const SizedBox(height: 8),
                  const Text('Photo interval'),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 60, label: Text('Hourly')),
                      ButtonSegment(value: 360, label: Text('6 hr')),
                      ButtonSegment(value: 720, label: Text('12 hr')),
                      ButtonSegment(value: 1440, label: Text('Daily')),
                    ],
                    selected: {_settings.autoCaptureIntervalMinutes},
                    onSelectionChanged: (next) => _commit(
                      _settings.copyWith(
                        autoCaptureIntervalMinutes: next.first,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'ADB info sharing',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Check ADB/wireless-ADB status for troubleshooting. Tap to view.',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _shareAdbInfo,
                  icon: const Icon(Icons.adb),
                  label: const Text('Check ADB info'),
                ),
                if (_adbInfoStatus != null) ...[
                  const SizedBox(height: 8),
                  Text(_adbInfoStatus!,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
                if (_adbInfoText != null && widget.onSendChat != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _sendAdbInfoToChat,
                    icon: const Icon(Icons.send),
                    label: const Text('Send to Juno'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Screen control',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This is how Muse uses the phone the way computer use works on a desktop. It can see the screen, take a screenshot, tap, swipe, type, and open apps while Companion is in the background. You turn it on yourself in system Accessibility settings. It does not run a shell. If the switch is greyed out, open this app in system settings, allow restricted settings, then turn Screen control on.',
                ),
                const SizedBox(height: 8),
                Text(
                  _grants['screen_control'] == true
                      ? 'Screen control is on.'
                      : 'Screen control is off.',
                ),
                const SizedBox(height: 8),
                _permitButton('Turn on screen control', _openScreenControl),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Phone control',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Muse can use this phone: camera, microphone, volume, ringer, brightness, rotation, flashlight, vibration, alarms, timers, media keys, launchable apps, the clipboard, the share sheet, contacts, calendar, location, and notifications you allow. Seeing the screen, tapping, and typing need Screen control above. Wi-Fi, Bluetooth, NFC, and airplane mode open the system panel. Android does not let an app flip those radios itself. Placing a call or sending a text stays off until you turn it on.',
                ),
                const SizedBox(height: 8),
                if (_grants.isNotEmpty)
                  Wrap(
                    children: [
                      _grantChip('screen_control', 'Screen control'),
                      _grantChip('camera', 'Camera'),
                      _grantChip('microphone', 'Microphone'),
                      _grantChip('location', 'Location'),
                      _grantChip('contacts', 'Contacts'),
                      _grantChip('calendar', 'Calendar'),
                      _grantChip('sms', 'SMS'),
                      _grantChip('phone', 'Phone'),
                      _grantChip('notifications', 'Notifications'),
                      _grantChip(
                        'notification_listener',
                        'Notification access',
                      ),
                      _grantChip('write_settings', 'System settings'),
                      _grantChip('dnd', 'Do Not Disturb'),
                    ],
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _permitButton(
                      'Camera',
                      () => _ask(Permission.camera, 'Camera'),
                    ),
                    _permitButton(
                      'Microphone',
                      () => _ask(Permission.microphone, 'Microphone'),
                    ),
                    _permitButton(
                      'Location',
                      () => _ask(Permission.locationWhenInUse, 'Location'),
                    ),
                    _permitButton(
                      'Contacts',
                      () => _ask(Permission.contacts, 'Contacts'),
                    ),
                    _permitButton(
                      'Calendar',
                      () => _ask(Permission.calendarFullAccess, 'Calendar'),
                    ),
                    if (!Platform.isIOS)
                      _permitButton('SMS', () => _ask(Permission.sms, 'SMS')),
                    _permitButton(
                      'Phone',
                      () => _ask(Permission.phone, 'Phone'),
                    ),
                    _permitButton(
                      'Notifications',
                      () => _ask(Permission.notification, 'Notifications'),
                    ),
                    _permitButton(
                      'Notification access',
                      _openNotificationAccess,
                    ),
                    _permitButton('System settings', () => _openPage('write')),
                    _permitButton('Do Not Disturb', () => _openPage('dnd')),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow Muse to place calls'),
                  value: _settings.allowCalls,
                  onChanged: (v) => _commit(_settings.copyWith(allowCalls: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow Muse to send texts'),
                  value: _settings.allowSendSms,
                  onChanged: (v) =>
                      _commit(_settings.copyWith(allowSendSms: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingCard(
            title: 'Debug',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Trigger a test approval popup to verify the flow works.',
                ),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: () {
                    ApprovalService.instance.requestApproval(
                      title: 'Allow "take_photo"?',
                      body:
                          'The agent wants to take a photo with the rear camera. This is a test prompt.',
                    );
                  },
                  child: const Text('Test approval popup'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _grantChip(String key, String label) {
    final value = _grants[key];
    if (value is! bool) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 8),
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(
          value ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 18,
        ),
        label: Text(label),
      ),
    );
  }

  Widget _permitButton(String label, VoidCallback onPressed) {
    return FilledButton.tonal(onPressed: onPressed, child: Text(label));
  }

  Future<void> _ask(Permission permission, String name) async {
    try {
      var status = await permission.status;
      if (status.isGranted) {
        await _refreshGrants();
        return;
      }
      if (status.isPermanentlyDenied) {
        await openAppSettings();
        return;
      }
      status = await permission.request();
      if (!status.isGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name stays off until it is allowed')),
        );
      }
    } on MissingPluginException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone permissions need the Android app')),
      );
    } finally {
      await _refreshGrants();
    }
  }

  Future<void> _openPage(String page) async {
    try {
      await AppScope.of(context).phone.run('phone.settings', {'page': page});
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _openScreenControl() async {
    try {
      await AppScope.of(
        context,
      ).phone.run('phone.screen_control', {'action': 'open'});
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _openNotificationAccess() async {
    try {
      await AppScope.of(context).phone.openNotificationAccess();
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({
    required this.connection,
    required this.unpairing,
    required this.onUnpair,
  });

  final ConnectionState connection;
  final bool unpairing;
  final Future<void> Function() onUnpair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ble = AppScope.of(context).ble;
    final paired =
        connection != ConnectionState.unpaired &&
        connection != ConnectionState.stopped;
    return _SettingCard(
      title: 'Pairing',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bluetooth, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ble.deviceName, style: theme.textTheme.titleSmall),
                    Text(
                      ble.nodeId,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: paired
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  paired ? connectionStatusLabel(connection) : 'Not paired',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: paired
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.outline,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) => const PairingScreen(),
                  ),
                ),
                icon: const Icon(Icons.bluetooth_searching, size: 18),
                label: Text(paired ? 'Re-pair' : 'Pair a Muse'),
              ),
              const SizedBox(width: 12),
              if (paired)
                OutlinedButton(
                  onPressed: unpairing ? null : onUnpair,
                  child: Text(unpairing ? 'Unpairing…' : 'Unpair'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingCard extends StatelessWidget {
  const _SettingCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MuseBubble(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Test button for the LM Studio connection: hits /v1/models and reports.
class _TestLmStudioButton extends StatefulWidget {
  const _TestLmStudioButton({required this.settings});

  final CompanionSettings settings;

  @override
  State<_TestLmStudioButton> createState() => _TestLmStudioButtonState();
}

class _TestLmStudioButtonState extends State<_TestLmStudioButton> {
  String? _result;
  bool _testing = false;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final service = LocalAiService(
      baseUrl: widget.settings.lmStudioUrl,
      model: widget.settings.lmStudioAgentModel,
      phone: const PhoneBridge(),
      usbStorageEnabled: widget.settings.usbStorageEnabled,
      usbSerialEnabled: widget.settings.usbSerialEnabled,
      speakAllowed: widget.settings.speakReplies,
    );
    final error = await service.testConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = error.isEmpty ? 'Connected.' : error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ElevatedButton(
          onPressed: _testing ? null : _test,
          child: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Test connection'),
        ),
        if (_result != null) ...[
          const SizedBox(height: 4),
          Text(
            _result!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: _result == 'Connected.'
                  ? Colors.green
                  : Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}


/// Dropdown selector for the LM Studio model, auto-fetched from the server.
///
/// - Fetches GET {serverUrl}/v1/models when the settings screen opens and
///   whenever [serverUrl] changes (debounced).
/// - "Auto (app picks the best model)" (value '') lets the app resolve the
///   model deterministically at task time: an agent task prefers a clef
///   decision model, a chat task prefers a conversational model, else the
///   first loaded model. No configuration needed.
/// - Manual refresh button is a backup; auto-fetch is the primary path.
/// - On fetch failure the last known list is shown with a stale badge;
///   with no cached list it falls back to a free-text field.
/// - A previously saved id missing from the fresh list is kept as a
///   "(custom)" entry rather than silently dropped.
class _ModelSelector extends StatefulWidget {
  const _ModelSelector({
    required this.serverUrl,
    required this.selectedModel,
    required this.onChanged,
    this.label = 'Model',
  });

  final String serverUrl;
  final String selectedModel;
  final ValueChanged<String> onChanged;
  final String label;

  @override
  State<_ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends State<_ModelSelector> {
  List<String> _models = const [];
  bool _loading = true;
  bool _stale = false;
  bool _textMode = false;
  int _generation = 0;
  Timer? _urlDebounce;
  late TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.selectedModel);
    _loadCached().then((_) {
      if (mounted) _fetch();
    });
  }

  @override
  void didUpdateWidget(covariant _ModelSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) {
      // Debounce: the URL field commits on every keystroke.
      _urlDebounce?.cancel();
      _urlDebounce = Timer(const Duration(seconds: 1), () {
        if (mounted) _fetch();
      });
    }
    if (oldWidget.selectedModel != widget.selectedModel &&
        _textController.text != widget.selectedModel) {
      _textController.text = widget.selectedModel;
    }
  }

  @override
  void dispose() {
    _urlDebounce?.cancel();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(lmStudioModelListCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final ids = decoded.whereType<String>().toList();
      if (ids.isEmpty || !mounted) return;
      setState(() => _models = ids);
    } catch (_) {
      // Cache is best-effort; a corrupt entry just means a fresh fetch.
    }
  }

  Future<void> _fetch() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _stale = false;
    });
    final ids = await LocalAiService.fetchModelIds(widget.serverUrl);
    if (!mounted || gen != _generation) return;
    if (ids.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(lmStudioModelListCacheKey, jsonEncode(ids));
      } catch (_) {
        // Cache write failure is non-fatal.
      }
      setState(() {
        _models = ids;
        _loading = false;
        _stale = false;
        _textMode = false;
      });
    } else {
      // Fetch failed: keep the last known list (stale) or fall back to text.
      setState(() {
        _loading = false;
        if (_models.isEmpty) {
          _textMode = true;
        } else {
          _stale = true;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_textMode) {
      return TextFormField(
        controller: _textController,
        decoration: InputDecoration(
          labelText: '${widget.label} (optional)',
          hintText: 'Server unreachable — leave blank, the app auto-picks',
          border: const OutlineInputBorder(),
        ),
        onChanged: (v) => widget.onChanged(v.trim()),
      );
    }

    final saved = widget.selectedModel;
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: '',
        child: Text('Auto (app picks the best model)'),
      ),
    ];
    final known = <String>{''};
    for (final id in _models) {
      if (known.add(id)) {
        items.add(DropdownMenuItem(value: id, child: Text(id)));
      }
    }
    // Keep a previously saved id that isn't in the fresh list.
    if (saved.isNotEmpty && !known.contains(saved)) {
      items.add(DropdownMenuItem(
        value: saved,
        child: Text('$saved (custom)'),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: saved,
                decoration: InputDecoration(
                  labelText: widget.label,
                  border: const OutlineInputBorder(),
                ),
                items: items,
                onChanged: _loading
                    ? null
                    : (v) => widget.onChanged((v ?? '').trim()),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: IconButton(
                tooltip: 'Refresh model list',
                onPressed: _loading ? null : _fetch,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ),
          ],
        ),
        if (_stale)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Server unreachable — showing last known list (may be stale).',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.orange),
            ),
          ),
      ],
    );
  }
}
