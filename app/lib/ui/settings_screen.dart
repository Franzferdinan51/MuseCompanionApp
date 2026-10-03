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
// `companion.set_display`. Calls, texts, and the saved camera are not:
// only this screen can change those.

import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/foreground.dart';
import '../app/model.dart';
import '../src/gadget/phone_actions.dart';
import '../src/gadget/service.dart';
import 'dashboard_screen.dart';
import 'diagnostics_screen.dart';
import 'muse_theme.dart';
import 'pairing_screen.dart';
import 'scope.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshGrants();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _settings = scope.settings.loadSettings();
    _connectionSub?.cancel();
    _connection = scope.service.connectionState;
    _connectionSub = scope.service.onStateChanged.listen((state) {
      if (mounted) setState(() => _connection = state);
    });
    _refreshServiceState();
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
    WidgetsBinding.instance.removeObserver(this);
    _connectionSub?.cancel();
    super.dispose();
  }

  Future<void> _commit(CompanionSettings next) async {
    final scope = AppScope.of(context);
    await scope.settings.saveSettings(next);
    scope.presentation.applySettings(next);
    if (!mounted) return;
    setState(() => _settings = next);
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
      appBar: AppBar(title: const Text('Companion Settings')),
      body: ListView(
        padding: const EdgeInsets.all(24),
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
                  Icons.monitor_heart_outlined,
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
            title: 'Phone control',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Muse can use this phone: camera, microphone, volume, ringer, brightness, rotation, flashlight, vibration, alarms, timers, media keys, launchable apps, the clipboard, the share sheet, contacts, calendar, location, and notifications you allow. Wi-Fi, Bluetooth, NFC, and airplane mode open the system panel. Android does not let an app flip those radios itself. Placing a call or sending a text stays off until you turn it on.',
                ),
                const SizedBox(height: 8),
                if (_grants.isNotEmpty)
                  Wrap(
                    children: [
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
