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
// Device tab: phone health + Muse link status dashboard.

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app/companion_platform.dart';
import '../app/model.dart';
import 'muse_theme.dart';
import 'scope.dart';

/// Device health dashboard: this phone's battery/model/app version plus
/// the Muse link state. The gadget firmware's `device.health` is queried
/// through the Muse link when available; until then the phone side is
/// shown with the link state beside it.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  Map<String, Object?>? _health;
  bool _loading = true;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await PackageInfo.fromPlatform();
      final health = await AppCompanionHealth(
        appVersion: '${info.version}+${info.buildNumber}',
      ).health();
      if (!mounted) return;
      setState(() {
        _health = health;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);
    final service = scope.service;
    return MusePage(
      appBar: AppBar(
        title: const Text('Device'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not read device health:\n$_error',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionCard(
                  title: 'This phone',
                  rows: [
                    _row(
                      theme,
                      Icons.battery_std_outlined,
                      'Battery',
                      _batteryLabel(_health),
                    ),
                    _row(
                      theme,
                      Icons.smartphone_outlined,
                      'Model',
                      '${_health?['model'] ?? 'unknown'}'
                          '${_health?['os'] != null ? ' · ${_health!['os']}' : ''}',
                    ),
                    _row(
                      theme,
                      Icons.apps_outlined,
                      'App version',
                      '${_health?['app_version'] ?? 'unknown'}',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SectionCard(
                  title: 'Muse link',
                  rows: [
                    _row(
                      theme,
                      Icons.link_outlined,
                      'Connection',
                      connectionStatusLabel(
                        service.connectionState,
                      ),
                    ),
                    _row(
                      theme,
                      Icons.bolt_outlined,
                      'Invokes seen',
                      '${service.invokesSeen}',
                    ),
                    _row(
                      theme,
                      Icons.smart_toy_outlined,
                      'Agent',
                      service.agentName ?? 'not registered',
                    ),
                    _row(
                      theme,
                      Icons.info_outline,
                      'Detail',
                      service.statusDetail.isEmpty
                          ? '—'
                          : service.statusDetail,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SectionCard(
                  title: 'Gadget',
                  rows: [
                    _row(
                      theme,
                      Icons.watch_outlined,
                      'Firmware health',
                      'Query via the Muse link — coming with the 2.06 board',
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  String _batteryLabel(Map<String, Object?>? health) {
    final level = health?['battery_level'];
    final charging = health?['charging'] == true;
    if (level is int) {
      return '$level%${charging ? ' · charging' : ''}';
    }
    return charging ? 'charging' : 'unknown';
  }

  Widget _row(ThemeData theme, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MuseBubble(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const Divider(height: 16),
          ...rows,
        ],
      ),
    );
  }
}
