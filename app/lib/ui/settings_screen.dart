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
// The settings surface: color theme, keep-screen-on, spoken replies, and
// the opt-in gates for real calls and texts. Values load from SettingsStore
// on entry and are persisted (and pushed to the presentation state) as the
// user changes them. Theme, keep-screen-on and spoken replies are also
// writable by the Muse through `companion.set_display`. Calls and texts are
// not: only this screen can turn those on.

import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;

import '../app/foreground.dart';
import '../app/model.dart';
import '../src/gadget/phone_actions.dart';
import '../src/gadget/service.dart';
import 'diagnostics_screen.dart';
import 'pairing_screen.dart';
import 'scope.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late CompanionSettings _settings;
  StreamSubscription<ConnectionState>? _connectionSub;
  ConnectionState _connection = ConnectionState.unpaired;
  bool _unpairing = false;
  bool? _serviceRunning;
  bool _serviceBusy = false;
  bool? _sdkSet;

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
    scope.sdkTokens.load().then((saved) {
      if (mounted) {
        setState(() => _sdkSet = saved != null && saved.isNotEmpty);
      }
    }).catchError((_) {
      if (mounted) setState(() => _sdkSet = false);
    });
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
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
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
        await startLinkService(linkNotificationText(
          scope.service.connectionState.name,
          scope.service.statusDetail,
          scope.service.agentName,
        ));
      }
      await _refreshServiceState();
    } finally {
      if (mounted) setState(() => _serviceBusy = false);
    }
  }

  @override
  void dispose() {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Companion Settings'),
        backgroundColor: theme.colorScheme.surface,
      ),
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
                Icon(Icons.key_outlined,
                    color: Theme.of(context).colorScheme.primary),
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
                    Icon(Icons.notifications_active_outlined,
                        color: Theme.of(context).colorScheme.primary),
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
                      onPressed:
                          _serviceBusy ? null : _toggleService,
                      child: Text(_serviceRunning == true
                          ? 'Stop keep-alive'
                          : 'Start keep-alive'),
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
            title: 'Diagnostics',
            child: Row(
              children: [
                Icon(Icons.monitor_heart_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Link state, device identity and the setup log',
                  ),
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
                Icon(Icons.palette_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final option in CompanionSettings.themeOptions)
                        ChoiceChip(
                          label: Text(
                              '${option[0].toUpperCase()}${option.substring(1)}'),
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
                  child: Text(
                    'Read Muse replies aloud on this phone',
                  ),
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
                            _settings.copyWith(speechVolume: v.round())),
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
            title: 'Phone actions',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your Muse can open the dialer, the message composer, '
                  'apps, and the camera without these. Placing a call or '
                  'sending a text directly stays off until you turn it on.',
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow Muse to place calls'),
                  value: _settings.allowCalls,
                  onChanged: (v) =>
                      _commit(_settings.copyWith(allowCalls: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow Muse to send texts'),
                  value: _settings.allowSendSms,
                  onChanged: (v) =>
                      _commit(_settings.copyWith(allowSendSms: v)),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: _openNotificationAccess,
                  icon: const Icon(Icons.notifications_outlined),
                  label: const Text('Notification access'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openNotificationAccess() async {
    try {
      await AppScope.of(context).phone.openNotificationAccess();
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
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
    final paired = connection != ConnectionState.unpaired &&
        connection != ConnectionState.stopped;
    return _SettingCard(
      title: 'Pairing',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bluetooth,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ble.deviceName,
                        style: theme.textTheme.titleSmall),
                    Text(ble.nodeId,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: paired
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  paired ? _labelFor(connection) : 'Not paired',
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

  String _labelFor(ConnectionState state) {
    switch (state) {
      case ConnectionState.connected:
        return 'Connected';
      case ConnectionState.connecting:
        return 'Connecting…';
      case ConnectionState.waiting:
        return 'Waiting';
      case ConnectionState.unpaired:
        return 'Not paired';
      case ConnectionState.stopped:
        return 'Stopped';
    }
  }
}

class _SettingCard extends StatelessWidget {
  const _SettingCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
