// Fullscreen live conversation screen: the UI half of live mode.
//
// Shows the session phase as a big animated mic indicator, the current
// utterance's transcript (what the Muse heard), the agent's reply text as
// it streams, elapsed time, and a prominent STOP button. Entry point is
// the Live button in the chat composer.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/chat.dart';
import '../app/live_mode.dart';
import '../app/phone_bridge.dart';
import '../src/gadget/service.dart';

/// Fullscreen hands-free conversation. Owns a [LiveModeController] for the
/// route's lifetime: starting it on open, stopping it on close.
class LiveScreen extends StatefulWidget {
  const LiveScreen({
    super.key,
    required this.phone,
    required this.chat,
    required this.service,
  });

  final PhoneBridge phone;
  final ChatHistory chat;
  final GadgetService service;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final LiveModeController _controller;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = LiveModeController(
      phone: widget.phone,
      chat: widget.chat,
      service: widget.service,
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _controller.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The mic can't stay open off-screen; pause instead of crashing.
    if (state == AppLifecycleState.paused) {
      _controller.pause('App in background');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    _controller.stop();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live conversation'),
        automaticallyImplyLeading: false,
        actions: [
          ValueListenableBuilder<Duration>(
            valueListenable: _controller.elapsed,
            builder: (context, elapsed, _) => Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  _formatDuration(elapsed),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close live mode',
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => switch (_controller.phase) {
            LivePhase.ended => _buildEndCard(context),
            LivePhase.paused => _buildPausedCard(context),
            _ => _buildLiveView(context),
          },
        ),
      ),
    );
  }

  Widget _buildLiveView(BuildContext context) {
    final theme = Theme.of(context);
    final phase = _controller.phase;
    return Column(
      children: [
        const SizedBox(height: 8),
        Text(_phaseLabel(phase), style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _phaseHint(phase, _controller.pauseReason),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: _PhaseOrb(controller: _controller, pulse: _pulse),
          ),
        ),
        _TranscriptPanel(chat: widget.chat, controller: _controller),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onPressed: () => _controller.stop(),
              icon: const Icon(Icons.stop),
              label: const Text('STOP', style: TextStyle(fontSize: 18)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPausedCard(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.pause_circle_outline,
              size: 72,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('Paused', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            if (_controller.pauseReason != null)
              Text(
                _controller.pauseReason!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _controller.resume(),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _controller.stop(),
                child: const Text('Stop live mode'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEndCard(BuildContext context) {
    final theme = Theme.of(context);
    final turns = _controller.turns;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('Live mode ended', style: theme.textTheme.headlineSmall),
            if (_controller.endMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _controller.endMessage!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            const SizedBox(height: 8),
            ValueListenableBuilder<Duration>(
              valueListenable: _controller.elapsed,
              builder: (context, elapsed, _) => Text(
                '$turns ${turns == 1 ? 'exchange' : 'exchanges'}'
                ' · ${_formatDuration(elapsed)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Big mic indicator: breathes while listening, swells with the live mic
/// amplitude, and changes color/icon with the session phase.
class _PhaseOrb extends StatelessWidget {
  const _PhaseOrb({required this.controller, required this.pulse});

  final LiveModeController controller;
  final AnimationController pulse;

  @override
  Widget build(BuildContext context) {
    final color = _phaseColor(controller.phase);
    return ValueListenableBuilder<double>(
      valueListenable: controller.amplitude,
      builder: (context, amp, _) => AnimatedBuilder(
        animation: pulse,
        builder: (context, _) {
          final breathing = controller.phase == LivePhase.listening
              ? 0.5 + 0.5 * math.sin(pulse.value * 2 * math.pi)
              : 0.0;
          final size = 170.0 * (1.0 + amp * 0.45 + breathing * 0.06);
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.16 + amp * 0.35),
              border: Border.all(color: color, width: 3),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 24 + amp * 30,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: _orbIcon(controller.phase, color),
          );
        },
      ),
    );
  }

  Widget _orbIcon(LivePhase phase, Color color) {
    switch (phase) {
      case LivePhase.thinking:
      case LivePhase.finalizing:
      case LivePhase.starting:
        return Center(
          child: SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(color: color, strokeWidth: 5),
          ),
        );
      case LivePhase.speaking:
        return Icon(Icons.volume_up, size: 64, color: color);
      case LivePhase.paused:
      case LivePhase.ended:
      case LivePhase.idle:
        return Icon(Icons.mic_off, size: 64, color: color);
      case LivePhase.listening:
        return Icon(Icons.mic, size: 64, color: color);
    }
  }
}

/// The live transcript: what the Muse heard you say, and the reply text
/// as it streams in. Reads the session's own messages so earlier chat
/// history never leaks into the cards.
class _TranscriptPanel extends StatelessWidget {
  const _TranscriptPanel({required this.chat, required this.controller});

  final ChatHistory chat;
  final LiveModeController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<void>(
      stream: chat.stream,
      builder: (context, _) {
        final messages = controller.sessionMessages();
        final heard = _lastText(messages, ChatRole.user);
        final reply = _lastText(messages, ChatRole.assistant);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _bubble(
                theme,
                label: 'You',
                text: heard == null || heard == 'Voice note' ? '…' : heard,
                alignRight: true,
              ),
              const SizedBox(height: 8),
              _bubble(
                theme,
                label: 'Juno',
                text: reply == null || reply.isEmpty ? '…' : reply,
                alignRight: false,
              ),
            ],
          ),
        );
      },
    );
  }

  String? _lastText(List<ChatMessage> messages, ChatRole role) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == role) return messages[i].text;
    }
    return null;
  }

  Widget _bubble(
    ThemeData theme, {
    required String label,
    required String text,
    required bool alignRight,
  }) {
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: alignRight
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            text,
            style: theme.textTheme.bodyMedium,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    return Row(
      children: [
        if (alignRight) const Spacer(),
        Flexible(child: bubble),
        if (!alignRight) const Spacer(),
      ],
    );
  }
}

String _phaseLabel(LivePhase phase) => switch (phase) {
  LivePhase.idle => 'Ready',
  LivePhase.starting => 'Starting…',
  LivePhase.listening => 'Listening',
  LivePhase.finalizing => 'Sending…',
  LivePhase.thinking => 'Thinking…',
  LivePhase.speaking => 'Speaking…',
  LivePhase.paused => 'Paused',
  LivePhase.ended => 'Ended',
};

String _phaseHint(LivePhase phase, String? pauseReason) => switch (phase) {
  LivePhase.listening => 'Speak — pause 2 seconds to send',
  LivePhase.finalizing => 'Sending your voice note…',
  LivePhase.thinking => 'Juno is thinking…',
  LivePhase.speaking => 'Listening resumes when Juno finishes',
  LivePhase.starting => 'Opening the microphone…',
  LivePhase.paused => pauseReason ?? 'Paused',
  LivePhase.ended => 'Session over',
  LivePhase.idle => '',
};

Color _phaseColor(LivePhase phase) => switch (phase) {
  LivePhase.listening => Colors.green,
  LivePhase.finalizing => Colors.orange,
  LivePhase.thinking => Colors.orange,
  LivePhase.speaking => Colors.blue,
  _ => Colors.grey,
};

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}'
      ':${seconds.toString().padLeft(2, '0')}';
}
