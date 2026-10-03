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
// The primary companion surface: name + battery header, a centered
// full-color character image, status lines below it, and a bottom bar
// showing connection state with a settings affordance. Layout mirrors
// muse-pocket's defined display (see muse-pocket README "What appears on
// the screen"), rendered at the phone's resolution in full color.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide ConnectionState;

import '../app/model.dart';
import '../src/gadget/service.dart';
import 'scope.dart';
import 'settings_screen.dart';

class CompanionScreen extends StatefulWidget {
  const CompanionScreen({super.key});

  @override
  State<CompanionScreen> createState() => _CompanionScreenState();
}

class _CompanionScreenState extends State<CompanionScreen> {
  StreamSubscription<ConnectionState>? _connectionSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // (Re)bind once per scope: dependOnInheritedWidget cannot run in
    // initState, and the subscription must be released on dispose.
    _connectionSub?.cancel();
    final scope = AppScope.of(context);
    scope.presentation.applyConnection(scope.service.connectionState,
        detail: scope.service.statusDetail);
    scope.presentation.applyName(scope.service.agentName);
    _connectionSub = scope.service.onStateChanged.listen((state) {
      if (!mounted) return;
      scope.presentation.applyConnection(
          state, detail: scope.service.statusDetail);
      scope.presentation.applyName(scope.service.agentName);
    });
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return StreamBuilder<void>(
      stream: scope.presentation.stream,
      builder: (context, _) => _Surface(scope: scope),
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({required this.scope}) : super(key: const ValueKey('companion_surface'));

  final AppScope scope;

  @override
  Widget build(BuildContext context) {
    final presentation = scope.presentation;
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              name: presentation.name ?? 'Muse',
              battery: presentation.battery,
            ),
            const Divider(height: 24, thickness: 1),
            Expanded(child: _Character(presentation: presentation)),
            _StatusLines(lines: presentation.lines),
            const SizedBox(height: 24),
            _BottomBar(
              state: presentation.connection ?? ConnectionState.unpaired,
              detail: presentation.statusDetail,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.battery})
      : super(key: const ValueKey('companion_header'));

  final String name;
  final int? battery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          Icon(Icons.monitor_heart_outlined,
              color: theme.colorScheme.primary, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _BatteryIndicator(battery: battery),
        ],
      ),
    );
  }
}

class _BatteryIndicator extends StatelessWidget {
  const _BatteryIndicator({required this.battery})
      : super(key: const ValueKey('companion_battery'));

  final int? battery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = battery;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          percent == null ? Icons.battery_unknown : _iconFor(percent),
          size: 18,
          color: theme.colorScheme.onSurface,
        ),
        const SizedBox(width: 4),
        if (percent != null)
          Text(
            '$percent%',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }

  IconData _iconFor(int p) {
    if (p >= 95) return Icons.battery_full;
    if (p >= 80) return Icons.battery_6_bar;
    if (p >= 65) return Icons.battery_5_bar;
    if (p >= 50) return Icons.battery_4_bar;
    if (p >= 35) return Icons.battery_3_bar;
    if (p >= 20) return Icons.battery_2_bar;
    if (p >= 10) return Icons.battery_1_bar;
    return Icons.battery_alert;
  }
}

class _Character extends StatelessWidget {
  const _Character({required this.presentation})
      : super(key: const ValueKey('companion_character'));

  final PresentationState presentation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = presentation.character;
    // A square canvas sized to the available space: phones vary, so the
    // character fills whatever the layout offers rather than a fixed
    // 480x480 box.
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          var side = constraints.maxWidth;
          if (constraints.maxHeight < side) side = constraints.maxHeight;
          if (side <= 0 || side == double.infinity) side = 320;
          return SizedBox(
            width: side,
            height: side,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: bytes == null
                    ? const _Placeholder()
                    : _CharacterImage(bytes: bytes),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined,
              size: 96, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('Waiting for character',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}

class _CharacterImage extends StatelessWidget {
  const _CharacterImage({required this.bytes}) : super();

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.cover,
      child: Image.memory(bytes, gaplessPlayback: true),
    );
  }
}

class _StatusLines extends StatelessWidget {
  const _StatusLines({required this.lines}) : super();

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.state, required this.detail}) : super();

  final ConnectionState state;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              _StatusDot(state: state),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(
                  detail.isEmpty ? _labelFor(state) : detail,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SettingsScreen(),
              ),
            ),
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
        return 'Waiting to retry';
      case ConnectionState.unpaired:
        return 'Not paired';
      case ConnectionState.stopped:
        return 'Stopped';
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.state}) : super();

  final ConnectionState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      ConnectionState.connected => Colors.green,
      ConnectionState.connecting => Colors.amber,
      ConnectionState.waiting => Colors.orange,
      ConnectionState.unpaired => Colors.grey,
      ConnectionState.stopped => Colors.grey,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
