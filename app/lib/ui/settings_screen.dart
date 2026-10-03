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
// The settings surface: color theme and keep-screen-on. Values load from
// SettingsStore on entry and are persisted (and pushed to the presentation
// state) as the user changes them. The same preferences are writable by the
// Muse through `companion.set_display`.

import 'package:flutter/material.dart';

import '../app/model.dart';
import 'scope.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late CompanionSettings _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = AppScope.of(context).settings.loadSettings();
  }

  Future<void> _commit(CompanionSettings next) async {
    final scope = AppScope.of(context);
    await scope.settings.saveSettings(next);
    scope.presentation.applySettings(next);
    if (!mounted) return;
    setState(() => _settings = next);
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
