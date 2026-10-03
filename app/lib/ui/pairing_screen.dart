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
// Pairing wizard: this phone advertises as the gadget while the Muse app
// provisions it. The wizard shows the advertised name, walks through the
// setup steps as the protocol engine reports them, and hands off to the
// connection loop once the pairing is saved.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/ble_peripheral.dart';
import '../src/gadget/ble_setup.dart';
import 'scope.dart';

/// Wizard step derived from the peripheral state and latest setup event.
///
/// Pure so the mapping is unit-testable: 0 waiting for the Muse app,
/// 1 handshake, 2 credentials, 3 verifying, 4 done.
int pairingStepIndex(BlePeripheralState state, SetupEventKind? last) {
  if (state == BlePeripheralState.done || last == SetupEventKind.authOk) {
    return 4;
  }
  switch (last) {
    case SetupEventKind.provisioning:
    case SetupEventKind.wifiConnecting:
    case SetupEventKind.wifiConnected:
    case SetupEventKind.wifiFailed:
    case SetupEventKind.failed:
      return 3;
    case SetupEventKind.pairingConfirmed:
      return 2;
    case SetupEventKind.helloReceived:
      return 1;
    case SetupEventKind.authOk:
      return 4;
    case SetupEventKind.started:
    case SetupEventKind.clientDisconnected:
    case null:
      break;
  }
  return switch (state) {
    BlePeripheralState.connected => 1,
    BlePeripheralState.advertising => 0,
    BlePeripheralState.starting => 0,
    _ => 0,
  };
}

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  StreamSubscription<BlePeripheralState>? _stateSub;
  StreamSubscription<SetupEvent>? _setupSub;
  final _sdkController = TextEditingController();
  bool _sdkLoaded = false;
  SetupEventKind? _lastSetup;
  String _setupDetail = '';
  bool _busy = false;
  bool _leaving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stateSub?.cancel();
    _setupSub?.cancel();
    final scope = AppScope.of(context);
    _stateSub = scope.ble.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _setupSub = scope.ble.setupEvents.listen((event) {
      if (!mounted) return;
      setState(() {
        _lastSetup = event.kind;
        _setupDetail = event.detail;
      });
    });
    if (!_sdkLoaded) {
      _sdkLoaded = true;
      scope.sdkTokens.load().then((saved) {
        if (!mounted || saved == null || saved.isEmpty) return;
        _sdkController.text = saved;
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _setupSub?.cancel();
    _sdkController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final scope = AppScope.of(context);
    final ble = scope.ble;
    setState(() => _busy = true);
    await _saveSdkToken(scope);
    try {
      if (Platform.isAndroid) {
        final statuses = await [
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
        ].request();
        final blocked = statuses.values.any(
            (s) => s.isDenied || s.isPermanentlyDenied || s.isRestricted);
        if (blocked) {
          if (!mounted) return;
          setState(() => _busy = false);
          final permanently =
              statuses.values.any((s) => s.isPermanentlyDenied);
          await _showPermissionSheet(permanently);
          return;
        }
      }
      await ble.start();
    } on MissingPluginException {
      // No permission plugin (tests, desktop): the manager reports what
      // the native side can actually do.
      await ble.start();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Persist the SDK token field (empty clears it) and apply it live.
  ///
  /// A storage failure must not block pairing: the token is optional, so
  /// the wizard notes it and carries on.
  Future<void> _saveSdkToken(AppScope scope) async {
    final token = _sdkController.text.trim();
    try {
      if (token.isEmpty) {
        await scope.sdkTokens.delete();
      } else {
        await scope.sdkTokens.save(token);
      }
      scope.service.setSdkToken(token.isEmpty ? null : token);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Could not save the SDK token; continuing without it.')),
      );
    }
  }

  Future<void> _showPermissionSheet(bool permanently) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bluetooth permission needed',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'The companion advertises as your gadget so the Muse app '
              'can find and provision it. Without nearby-device Bluetooth '
              'access it cannot be discovered.',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (permanently)
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      openAppSettings();
                    },
                    child: const Text('Open settings'),
                  ),
                if (permanently) const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await AppScope.of(context).ble.stop();
      _lastSetup = null;
      _setupDetail = '';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    if (_leaving) return;
    _leaving = true;
    await AppScope.of(context).ble.stop();
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ble = AppScope.of(context).ble;
    final state = ble.state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair a Muse'),
        backgroundColor: theme.colorScheme.surface,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _NameCard(name: ble.deviceName, active: ble.isActive),
          const SizedBox(height: 16),
          switch (state) {
            BlePeripheralState.idle => _IdleCard(
                busy: _busy,
                sdkController: _sdkController,
                onStart: _start,
              ),
            BlePeripheralState.starting => _WorkingCard(
                label: _busy
                    ? 'Requesting Bluetooth…'
                    : 'Starting advertiser…',
              ),
            BlePeripheralState.advertising ||
            BlePeripheralState.connected =>
              _ProgressCard(
                state: state,
                lastSetup: _lastSetup,
                detail: _setupDetail,
                busy: _busy,
                onStop: _stop,
              ),
            BlePeripheralState.done => _DoneCard(onFinish: _finish),
            BlePeripheralState.error => _ErrorCard(
                detail: ble.detail,
                busy: _busy,
                onRetry: _start,
              ),
            BlePeripheralState.unsupported => _UnsupportedCard(
                detail: ble.detail,
              ),
          },
        ],
      ),
    );
  }
}

class _NameCard extends StatelessWidget {
  const _NameCard({required this.name, required this.active});

  final String name;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                if (active)
                  const SizedBox(
                    width: 56,
                    height: 56,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                Icon(Icons.bluetooth,
                    size: 28, color: theme.colorScheme.primary),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('This phone advertises as',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline)),
                  SelectableText(name,
                      style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdleCard extends StatelessWidget {
  const _IdleCard({
    required this.busy,
    required this.sdkController,
    required this.onStart,
  });

  final bool busy;
  final TextEditingController sdkController;
  final Future<void> Function() onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('How pairing works', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            const _Step('Start advertising below.'),
            const _Step(
                'Open the Muse app and add a gadget.'),
            const _Step('Pick this phone from the list and approve.'),
            const _Step('Credentials are verified, then saved securely.'),
            const SizedBox(height: 16),
            TextField(
              controller: sdkController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'SDK token (optional)',
                helperText:
                    'From gadgets.muse.ai — only for developer gadget features.',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key_outlined),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : onStart,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bluetooth_searching),
              label: Text(busy ? 'Starting…' : 'Start pairing'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ', style: Theme.of(context).textTheme.bodyMedium),
          Expanded(
              child: Text(text,
                  style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _WorkingCard extends StatelessWidget {
  const _WorkingCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Text(label, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.state,
    required this.lastSetup,
    required this.detail,
    required this.busy,
    required this.onStop,
  });

  final BlePeripheralState state;
  final SetupEventKind? lastSetup;
  final String detail;
  final bool busy;
  final Future<void> Function() onStop;

  static const _labels = [
    'Waiting for the Muse app',
    'Secure handshake',
    'Receiving credentials',
    'Verifying and saving',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = pairingStepIndex(state, lastSetup);
    final failed = lastSetup == SetupEventKind.failed ||
        lastSetup == SetupEventKind.wifiFailed;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              state == BlePeripheralState.connected
                  ? 'Muse app connected'
                  : 'Advertising — open the Muse app',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _labels.length; i++)
              _ProgressRow(
                label: _labels[i],
                done: i < index,
                active: i == index && !failed,
                failed: i == index && failed,
              ),
            if (failed && detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _friendlyDetail(detail),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: busy ? null : onStop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ),
      ),
    );
  }

  String _friendlyDetail(String detail) {
    return switch (detail) {
      'provision_unauthorized' =>
        'The Muse app sent credentials the API rejected.',
      'provision_verify_failed' =>
        'Could not reach the Muse API to verify. Check the connection.',
      'provision_commit_failed' => 'Could not save the pairing.',
      'wifi_failed' => 'This phone is offline.',
      'error_pairing_invalid_hello' =>
        'The Muse app sent an incompatible handshake — update both apps.',
      'error_pairing_decrypt' =>
        'Handshake encryption mismatch. Stop and try pairing again.',
      'error_pairing_confirm_required' =>
        'Confirm the pairing in the Muse app, then retry.',
      'error_missing_credentials' =>
        'The Muse app did not send login credentials.',
      'error_encryption_required' => 'The link dropped its encryption.',
      'error_unknown_action' =>
        'The Muse app sent something unexpected ($detail).',
      _ => detail,
    };
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    required this.label,
    required this.done,
    required this.active,
    required this.failed,
  });

  final String label;
  final bool done;
  final bool active;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget icon;
    if (done) {
      icon = Icon(Icons.check_circle,
          color: theme.colorScheme.primary, size: 20);
    } else if (failed) {
      icon =
          Icon(Icons.error, color: theme.colorScheme.error, size: 20);
    } else if (active) {
      icon = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
            strokeWidth: 2, color: theme.colorScheme.primary),
      );
    } else {
      icon = Icon(Icons.circle_outlined,
          color: theme.colorScheme.outline, size: 20);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 12),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: done || active || failed
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.outline,
              fontWeight:
                  active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _DoneCard extends StatelessWidget {
  const _DoneCard({required this.onFinish});

  final Future<void> Function() onFinish;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle,
                    size: 32, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Paired!',
                      style: theme.textTheme.headlineSmall),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
                'Credentials verified and saved. The companion is connecting to your Muse now.'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onFinish,
              child: const Text('Show my companion'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.detail,
    required this.busy,
    required this.onRetry,
  });

  final String detail;
  final bool busy;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline,
                    color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Text('Pairing failed',
                    style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              detail.isEmpty ? 'Bluetooth could not start.' : detail,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnsupportedCard extends StatelessWidget {
  const _UnsupportedCard({required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bluetooth_disabled,
                    color: theme.colorScheme.outline),
                const SizedBox(width: 8),
                Text('Not available',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              detail.isEmpty
                  ? 'BLE advertising is not available on this device.'
                  : detail,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
