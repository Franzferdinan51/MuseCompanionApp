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
// Diagnostics screen: connection and device state plus the BLE setup log.
//
// Everything here is read-only and local. The log tail comes from the
// peripheral manager's in-memory ring, so entries from before the screen
// opened are still visible, and new lines stream in while it is open.
// The copy button assembles a state dump for bug reports — it never
// includes credentials, which stay in secure storage.

import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app/ble_peripheral.dart';
import '../src/gadget/service.dart';
import 'muse_theme.dart';
import 'scope.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  StreamSubscription<ConnectionState>? _connectionSub;
  StreamSubscription<BlePeripheralState>? _bleSub;
  StreamSubscription<String>? _logSub;
  final List<String> _logs = <String>[];
  String _appVersion = '';
  bool _copied = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _connectionSub?.cancel();
    _bleSub?.cancel();
    _logSub?.cancel();
    final scope = AppScope.of(context);
    _logs
      ..clear()
      ..addAll(scope.ble.recentLogs);
    _connectionSub = scope.service.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _bleSub = scope.ble.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _logSub = scope.ble.logLines.listen((line) {
      if (!mounted) return;
      setState(() {
        _logs.add(line);
        while (_logs.length > BlePeripheralManager.maxRecentLogs) {
          _logs.removeAt(0);
        }
      });
    });
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _appVersion = '${info.version}+${info.buildNumber}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _appVersion = 'unknown');
    }
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _bleSub?.cancel();
    _logSub?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final scope = AppScope.of(context);
    final dump = _stateDump(
      scope.service,
      scope.ble,
      _appVersion.isEmpty ? 'unknown' : _appVersion,
      _logs,
    );
    await Clipboard.setData(ClipboardData(text: dump));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    return MusePage(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          TextButton.icon(
            onPressed: _copy,
            icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
            label: Text(_copied ? 'Copied' : 'Copy'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _Card(
            title: 'Link',
            rows: {
              'State': _connectionLabel(scope.service.connectionState),
              if (scope.service.statusDetail.isNotEmpty)
                'Detail': scope.service.statusDetail,
              'Agent': scope.service.agentName ?? '—',
              'Registered': scope.service.isRegistered ? 'yes' : 'no',
            },
          ),
          const SizedBox(height: 16),
          _Card(
            title: 'Device',
            rows: {
              'BLE name': scope.ble.deviceName,
              'Node ID': scope.ble.nodeId,
              'Identity': scope.ble.mac,
              'App': _appVersion.isEmpty ? '…' : _appVersion,
            },
          ),
          const SizedBox(height: 16),
          _Card(
            title: 'BLE setup',
            rows: {
              'State': scope.ble.state.name,
              if (scope.ble.detail.isNotEmpty) 'Detail': scope.ble.detail,
            },
          ),
          const SizedBox(height: 16),
          _Card(
            title: 'Setup log',
            child: _logs.isEmpty
                ? Text(
                    'No setup activity yet.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  )
                : SelectableText(
                    _logs.join('\n'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Courier'],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _connectionLabel(ConnectionState state) {
    switch (state) {
      case ConnectionState.connected:
        return 'connected';
      case ConnectionState.connecting:
        return 'connecting';
      case ConnectionState.waiting:
        return 'waiting';
      case ConnectionState.unpaired:
        return 'unpaired';
      case ConnectionState.stopped:
        return 'stopped';
    }
  }
}

String _stateDump(
  GadgetService service,
  BlePeripheralManager ble,
  String appVersion,
  List<String> logs,
) {
  final buf = StringBuffer()
    ..writeln('Muse Companion diagnostics')
    ..writeln('app: $appVersion')
    ..writeln(
      'link: ${service.connectionState.name}'
      '${service.statusDetail.isEmpty ? '' : ' (${service.statusDetail})'}',
    )
    ..writeln('agent: ${service.agentName ?? '-'}')
    ..writeln('registered: ${service.isRegistered}')
    ..writeln('ble_name: ${ble.deviceName}')
    ..writeln('node_id: ${ble.nodeId}')
    ..writeln(
      'ble_setup: ${ble.state.name}'
      '${ble.detail.isEmpty ? '' : ' (${ble.detail})'}',
    )
    ..writeln('--- setup log ---');
  for (final line in logs) {
    buf.writeln(line);
  }
  return buf.toString();
}

class _Card extends StatelessWidget {
  const _Card({required this.title, this.rows = const {}, this.child});

  final String title;
  final Map<String, String> rows;
  final Widget? child;

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
          ?child,
          for (final entry in rows.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      entry.key,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      entry.value,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
