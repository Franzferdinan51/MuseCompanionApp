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
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app/avatar_motion.dart';
import '../app/captions.dart';
import '../app/model.dart';
import '../src/gadget/chat_events.dart';
import '../src/gadget/phone_actions.dart';
import '../src/gadget/service.dart';
import 'chat_screen.dart';
import 'dashboard_screen.dart';
import 'pairing_screen.dart';
import 'scope.dart';
import 'settings_screen.dart';

/// Shared observer so the companion screen knows when it is covered.
final RouteObserver<ModalRoute<dynamic>> routeObserver =
    RouteObserver<ModalRoute<dynamic>>();

class CompanionScreen extends StatefulWidget {
  const CompanionScreen({super.key});

  @override
  State<CompanionScreen> createState() => _CompanionScreenState();
}

class _CompanionScreenState extends State<CompanionScreen> with RouteAware {
  StreamSubscription<ConnectionState>? _connectionSub;
  StreamSubscription<void>? _presentationSub;
  bool _routeVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // (Re)bind once per scope: dependOnInheritedWidget cannot run in
    // initState, and the subscription must be released on dispose.
    _connectionSub?.cancel();
    _presentationSub?.cancel();
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
    _presentationSub = scope.presentation.stream.listen((_) {
      if (mounted) _applyWakelock();
    });
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
      _routeVisible = route.isCurrent;
    }
    _applyWakelock();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _connectionSub?.cancel();
    _presentationSub?.cancel();
    // Never leave the display pinned on after the screen goes away.
    WakelockPlus.toggle(enable: false).catchError((_) => false);
    super.dispose();
  }

  @override
  void didPush() => _onVisibility(true);

  @override
  void didPopNext() => _onVisibility(true);

  @override
  void didPushNext() => _onVisibility(false);

  @override
  void didPop() => _onVisibility(false);

  void _onVisibility(bool visible) {
    _routeVisible = visible;
    _applyWakelock();
  }

  Future<void> _applyWakelock() async {
    final scope = AppScope.of(context);
    final enable =
        _routeVisible && scope.presentation.settings.keepScreenOn;
    try {
      await WakelockPlus.toggle(enable: enable);
    } on MissingPluginException {
      // Tests and platforms without the plugin: nothing to pin.
    } on PlatformException {
      // Best-effort display hint; never break the screen over it.
    }
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
            Expanded(
              child: Column(
                children: [
                  Expanded(child: _Character(presentation: presentation)),
                  Text(
                    'Hold the character to talk',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
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
          IconButton(
            tooltip: 'Dashboard',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DashboardScreen(),
              ),
            ),
            icon: Icon(Icons.monitor_heart_outlined,
                color: theme.colorScheme.primary, size: 22),
          ),
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

class _Character extends StatefulWidget {
  const _Character({required this.presentation})
      : super(key: const ValueKey('companion_character'));

  final PresentationState presentation;

  @override
  State<_Character> createState() => _CharacterState();
}

class _CharacterState extends State<_Character>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (mounted) setState(() => _elapsed = elapsed);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _holdStart() async {
    if (_holding) return;
    final scope = AppScope.of(context);
    if (!scope.service.isRegistered) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Connect to your Muse before talking.')),
      );
      return;
    }
    _holding = true;
    scope.presentation.applyPose(AvatarPose.listening);
    scope.presentation.applyStatus('Listening…');
    try {
      await scope.phone.startRecording();
    } on PhoneActionException catch (e) {
      _holding = false;
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _holdEnd() async {
    if (!_holding) return;
    _holding = false;
    final scope = AppScope.of(context);
    scope.presentation.applyPose(AvatarPose.thinking);
    scope.presentation.applyStatus('Thinking…');
    try {
      final wav = await scope.phone.stopRecording();
      if (!mounted) return;
      final id = scope.chat.addSending('Voice note');
      final result = await scope.service.sendChat('', null, [
        ChatAttachment(
          mimeType: 'audio/wav',
          filename: 'voice_note.wav',
          bytes: wav,
        ),
      ]);
      if (!mounted) return;
      if (result['ok'] == true) {
        scope.chat.markSent(id);
      } else {
        final error = result['error'];
        scope.chat.markFailed(
            id,
            error is String && error.isNotEmpty ? error : 'send failed');
        scope.presentation.applyPose(AvatarPose.idle);
      }
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = widget.presentation;
    final bytes = presentation.character;
    final motion = avatarMotion(
      presentation.pose,
      _elapsed.inMicroseconds / 1000000,
    );
    // A square canvas sized to the available space: phones vary, so the
    // character fills whatever the layout offers rather than a fixed
    // 480x480 box. The portrait itself moves; the rings sit behind it.
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          var side = constraints.maxWidth;
          if (constraints.maxHeight < side) side = constraints.maxHeight;
          if (side <= 0 || side == double.infinity) side = 320;
          final portrait = ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: bytes == null
                  ? _Placeholder(
                      connected: presentation.connection ==
                          ConnectionState.connected)
                  : _CharacterImage(bytes: bytes),
            ),
          );
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _holdStart(),
            onPointerUp: (_) => _holdEnd(),
            onPointerCancel: (_) => _holdEnd(),
            child: SizedBox(
              width: side,
              height: side,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (motion.rings ||
                      presentation.pose == AvatarPose.thinking)
                    CustomPaint(
                      size: Size.square(side),
                      painter: _RingPainter(
                        phase: presentation.pose == AvatarPose.thinking
                            ? (_elapsed.inMicroseconds / 1000000 * 0.7) % 1
                            : motion.ringPhase,
                        color: theme.colorScheme.primary,
                        arc: presentation.pose == AvatarPose.thinking,
                      ),
                    ),
                  Transform.translate(
                    offset: Offset(motion.lean * 8, motion.bob * 8),
                    child: Transform.scale(
                      scale: motion.scale,
                      child: SizedBox(
                        width: side,
                        height: side,
                        child: portrait,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.phase,
    required this.color,
    required this.arc,
  });

  final double phase;
  final Color color;
  final bool arc;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * 0.46;
    if (arc) {
      // Thinking on the Waveshare screen is a ring that travels as a segment.
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.8);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * 0.92),
        phase * 6.283185307179586,
        1.15,
        false,
        paint,
      );
      return;
    }
    // Listening and speaking: dotted rings that expand and fade.
    for (var i = 0; i < 2; i++) {
      final t = (phase + i * 0.5) % 1;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: (1 - t) * 0.55);
      final ring = radius * (0.72 + t * 0.28);
      const dots = 18;
      for (var d = 0; d < dots; d++) {
        final angle = (d / dots) * 6.283185307179586;
        canvas.drawCircle(
          Offset(center.dx + ring * math.cos(angle),
              center.dy + ring * math.sin(angle)),
          2.2,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.color != color ||
      oldDelegate.arc != arc;
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.connected});

  final bool connected;

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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              connected
                  ? 'Asking your Muse for a character…'
                  : 'Waiting for character',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _CharacterImage extends StatefulWidget {
  const _CharacterImage({required this.bytes}) : super();

  final Uint8List bytes;

  @override
  State<_CharacterImage> createState() => _CharacterImageState();
}

class _CharacterImageState extends State<_CharacterImage> {
  /// Staging future for the GLB branch; null when showing a 2D image.
  Future<String>? _modelPath;

  @override
  void initState() {
    super.initState();
    _maybeStageModel();
  }

  @override
  void didUpdateWidget(_CharacterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.bytes, oldWidget.bytes)) {
      _maybeStageModel();
    }
  }

  void _maybeStageModel() {
    _modelPath =
        isGlbModel(widget.bytes) ? _stageModel(widget.bytes) : null;
  }

  @override
  Widget build(BuildContext context) {
    final modelPath = _modelPath;
    // The 2D path is byte-for-byte the historical behavior.
    if (modelPath == null) {
      return Image.memory(
        widget.bytes,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
      );
    }
    return FutureBuilder<String>(
      future: modelPath,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ModelViewer(
          src: 'file://${snapshot.data}',
          autoRotate: true,
          disableZoom: true,
          backgroundColor: Colors.transparent,
        );
      },
    );
  }
}

/// Write GLB [bytes] to a temp file for the embedded 3D viewer.
///
/// A fixed name is fine: one avatar is shown at a time, and overwriting
/// keeps the temp directory from filling with stale models.
Future<String> _stageModel(Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/muse_avatar.glb');
  await file.writeAsBytes(bytes);
  return file.path;
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state == ConnectionState.unpaired)
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => const PairingScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.bluetooth, size: 18),
                  label: const Text('Pair'),
                ),
              IconButton(
                tooltip: 'Say it again',
                onPressed: () => _repeatLast(context),
                icon: const Icon(Icons.replay),
              ),
              IconButton(
                tooltip: 'Message',
                icon: const Icon(Icons.chat_bubble_outline),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ChatScreen(),
                  ),
                ),
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
        ],
      ),
    );
  }

  Future<void> _repeatLast(BuildContext context) async {
    final scope = AppScope.of(context);
    final reply = scope.chat.lastReply;
    final source = (reply != null && reply.trim().isNotEmpty)
        ? reply
        : scope.presentation.statusText;
    final spoken = speakableReply(source);
    if (spoken.isEmpty || spoken == 'Listening…') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to say yet.')),
      );
      return;
    }
    try {
      await scope.phone.run('phone.volume', {
        'level': scope.presentation.settings.speechVolume,
      });
      await scope.phone.speak(spoken);
    } on PhoneActionException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
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
