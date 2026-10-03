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
// A status page in the spirit of the reTerminal e-paper gadget: the
// agent's name, the character, and one status line, plus the command
// channel so a timed-out Muse command is visible on the phone.

import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;

import '../app/model.dart';
import '../src/gadget/service.dart';
import 'scope.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  StreamSubscription<void>? _presentationSub;
  StreamSubscription<void>? _linkSub;
  StreamSubscription<ConnectionState>? _connectionSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _presentationSub?.cancel();
    _linkSub?.cancel();
    _connectionSub?.cancel();
    final scope = AppScope.of(context);
    void redraw() {
      if (mounted) setState(() {});
    }

    _presentationSub = scope.presentation.stream.listen((_) => redraw());
    _linkSub = scope.service.onLink.listen((_) => redraw());
    _connectionSub = scope.service.onStateChanged.listen((_) => redraw());
  }

  @override
  void dispose() {
    _presentationSub?.cancel();
    _linkSub?.cancel();
    _connectionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final presentation = scope.presentation;
    final service = scope.service;
    final theme = Theme.of(context);
    final name = presentation.name ?? service.agentName ?? 'Muse';
    final connection = presentation.connection ?? service.connectionState;
    final log = service.linkLog.reversed.take(12).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            name,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Center(child: _Preview(presentation: presentation)),
          const SizedBox(height: 12),
          Text(
            presentation.statusText.isEmpty
                ? 'No caption yet'
                : presentation.statusText,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          _Row('Link', _connectionLabel(connection)),
          if (presentation.statusDetail.isNotEmpty)
            _Row('Detail', presentation.statusDetail),
          _Row(
            'Battery',
            presentation.battery == null
                ? 'Unknown'
                : '${presentation.battery}%',
          ),
          _Row('Pose', presentation.pose.name),
          _Row('Speech volume', '${presentation.settings.speechVolume}'),
          const Divider(height: 32),
          Text('Command channel', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _Row('Invokes seen', '${service.invokesSeen}'),
          _Row('Results sent', '${service.resultsSent}'),
          _Row('Last command',
              service.lastCommand.isEmpty ? '—' : service.lastCommand),
          _Row(
            'Last result',
            service.lastCommandResult.isEmpty
                ? '—'
                : service.lastCommandResult,
          ),
          const SizedBox(height: 8),
          Text(
            service.invokesSeen == 0
                ? 'If Muse says a command timed out and invokes stay at 0, the phone is not receiving device.invoke.'
                : service.resultsSent < service.invokesSeen
                    ? 'Invokes are arriving. A result that stays behind means the reply is not leaving the phone.'
                    : 'Commands are arriving and the phone is sending link.result.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const Divider(height: 32),
          Text('Recent link log', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (log.isEmpty)
            Text(
              'Nothing logged yet. Connect, then ask Muse to run device.health.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            )
          else
            for (final line in log)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(line, style: theme.textTheme.bodySmall),
              ),
        ],
      ),
    );
  }

  String _connectionLabel(ConnectionState state) {
    switch (state) {
      case ConnectionState.connected:
        return 'Connected';
      case ConnectionState.connecting:
        return 'Connecting';
      case ConnectionState.waiting:
        return 'Waiting';
      case ConnectionState.unpaired:
        return 'Not paired';
      case ConnectionState.stopped:
        return 'Stopped';
    }
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.presentation});

  final PresentationState presentation;

  @override
  Widget build(BuildContext context) {
    final bytes = presentation.character;
    final theme = Theme.of(context);
    Widget child;
    if (bytes == null) {
      child = Icon(Icons.image_outlined,
          size: 72, color: theme.colorScheme.outline);
    } else if (presentation.characterIsModel) {
      child = Icon(Icons.view_in_ar_outlined,
          size: 72, color: theme.colorScheme.primary);
    } else {
      child = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 180,
        height: 180,
        color: theme.colorScheme.surfaceContainerHighest,
        child: child,
      ),
    );
  }
}
