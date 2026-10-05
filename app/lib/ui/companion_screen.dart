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
// The primary companion surface: name + battery header, the pixel avatar
// inside a fixed round stage, captions below it, and a bottom bar showing
// connection state. The stage follows the full-UI boards: a portrait that
// moves inside the disc, a state word, blinks, gaze, boot, shutdown, a
// short-tap pet, a thinking spinner, and a listen ring on the bezel.

import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app/avatar_motion.dart';
import '../app/model.dart';
import '../app/pixel_avatar.dart';
import '../app/wake_word.dart';
import '../src/gadget/chat_events.dart';
import '../src/gadget/phone_actions.dart';
import '../src/gadget/service.dart';
import '../main.dart';
import 'dashboard_screen.dart';
import 'pairing_screen.dart';
import 'muse_theme.dart';
import 'avatar_video_stage.dart';
import 'scope.dart';

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
  bool _bootArmed = false;
  bool _asleep = false;
  Timer? _bootTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // (Re)bind once per scope: dependOnInheritedWidget cannot run in
    // initState, and the subscription must be released on dispose.
    _connectionSub?.cancel();
    _presentationSub?.cancel();
    final scope = AppScope.of(context);
    scope.presentation.applyConnection(
      scope.service.connectionState,
      detail: scope.service.statusDetail,
    );
    scope.presentation.applyName(scope.service.agentName);
    _armBoot(scope);
    _connectionSub = scope.service.onStateChanged.listen((state) {
      if (!mounted) return;
      scope.presentation.applyConnection(
        state,
        detail: scope.service.statusDetail,
      );
      scope.presentation.applyName(scope.service.agentName);
      _applyLinkPose(scope, state);
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

  /// One boot squash when the screen first shows an idle portrait.
  /// The link starts in `stopped` before the loop runs, so that initial
  /// state is not a shutdown.
  void _armBoot(AppScope scope) {
    if (_bootArmed) return;
    _bootArmed = true;
    if (scope.presentation.pose != AvatarPose.idle) return;
    scope.presentation.applyPose(AvatarPose.boot);
    _bootTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      if (scope.presentation.pose == AvatarPose.boot) {
        scope.presentation.applyPose(AvatarPose.idle);
      }
    });
  }

  /// `stopped` is the link being shut down. Unpaired stays idle.
  void _applyLinkPose(AppScope scope, ConnectionState state) {
    final pose = scope.presentation.pose;
    if (state == ConnectionState.stopped) {
      if (pose != AvatarPose.error && pose != AvatarPose.off) {
        scope.presentation.applyPose(AvatarPose.off);
      }
    } else if (pose == AvatarPose.off) {
      scope.presentation.applyPose(AvatarPose.idle);
    }
  }

  @override
  void dispose() {
    _bootTimer?.cancel();
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

  /// Local screen sleep, like the board's dark overlay. It does not set
  /// the link pose to off, and a stopped link is not treated as sleep.
  void _toggleSleep() {
    setState(() => _asleep = !_asleep);
    _applyWakelock();
  }

  Future<void> _applyWakelock() async {
    final scope = AppScope.of(context);
    final enable =
        _routeVisible && !_asleep && scope.presentation.settings.keepScreenOn;
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
      builder: (context, _) =>
          _Surface(scope: scope, asleep: _asleep, onSleep: _toggleSleep),
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({
    required this.scope,
    required this.asleep,
    required this.onSleep,
  }) : super(key: const ValueKey('companion_surface'));

  final AppScope scope;
  final bool asleep;
  final VoidCallback onSleep;

  @override
  Widget build(BuildContext context) {
    final presentation = scope.presentation;
    final theme = Theme.of(context);
    // Landscape gets a two-column layout (see _LandscapeBody) so the
    // width is used instead of stacking everything into one crowded
    // center strip. Portrait keeps the classic stacked look.
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      backgroundColor: museInk,
      body: DecoratedBox(
        decoration: museBackdrop(),
        child: SafeArea(
          child: Column(
            children: [
              _Header(
                name: presentation.name ?? 'Muse',
                battery: presentation.battery,
                asleep: asleep,
                onSleep: onSleep,
              ),
              Expanded(
                child: Stack(
                  children: [
                    Column(
                      children: [
                        Expanded(
                          child: landscape
                              ? _LandscapeBody(
                                  presentation: presentation,
                                  asleep: asleep,
                                  theme: theme,
                                )
                              : _PortraitBody(
                                  presentation: presentation,
                                  asleep: asleep,
                                  theme: theme,
                                ),
                        ),
                      ],
                    ),
                    if (asleep)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onSleep,
                          child: ColoredBox(
                            color: museInk.withValues(alpha: 0.94),
                            child: Center(
                              child: Text(
                                'Tap to wake',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: museMist,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Portrait Home tab: the classic vertically stacked layout.
class _PortraitBody extends StatelessWidget {
  const _PortraitBody({
    required this.presentation,
    required this.asleep,
    required this.theme,
  });

  final PresentationState presentation;
  final bool asleep;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('companion_portrait'),
      children: [
        Expanded(
          child: _Character(presentation: presentation, asleep: asleep),
        ),
        const SizedBox(height: 8),
        Text(
          'Tap to pet, hold to talk',
          style: theme.textTheme.bodySmall?.copyWith(
            color: museMist.withValues(alpha: 0.82),
          ),
        ),
        const SizedBox(height: 8),
        // Right padding keeps the pills clear of the floating side dock;
        // long status text ("Taking a photo…") ellipsizes instead of
        // growing into it.
        Padding(
          padding: const EdgeInsets.only(right: kSideDockClearance),
          child: _StatusLines(lines: presentation.lines),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(right: kSideDockClearance),
          child: _ConnectionStatus(
            key: const ValueKey('connection_status'),
            state: presentation.connection ?? ConnectionState.unpaired,
            detail: presentation.statusDetail,
          ),
        ),
      ],
    );
  }
}

/// Landscape Home tab: two columns so the width gets used instead of
/// stacking everything into a crowded center strip. Avatar (shrunk a
/// touch for breathing room) + caption on the left, status pills
/// stacked compactly and vertically centered on the right.
class _LandscapeBody extends StatelessWidget {
  const _LandscapeBody({
    required this.presentation,
    required this.asleep,
    required this.theme,
  });

  final PresentationState presentation;
  final bool asleep;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('companion_landscape'),
      children: [
        // Left: avatar + caption.
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Expanded(
                  child: _Character(
                    presentation: presentation,
                    asleep: asleep,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap to pet, hold to talk',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: museMist.withValues(alpha: 0.82),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Right: status pills stacked compactly, clear of the side dock.
        // The scroll view guards against overflow on very short
        // landscape heights.
        Expanded(
          flex: 5,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(right: kSideDockClearance),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusLines(lines: presentation.lines),
                  const SizedBox(height: 12),
                  _ConnectionStatus(
                    key: const ValueKey('connection_status'),
                    state:
                        presentation.connection ?? ConnectionState.unpaired,
                    detail: presentation.statusDetail,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.battery,
    required this.asleep,
    required this.onSleep,
  }) : super(key: const ValueKey('companion_header'));

  final String name;
  final int? battery;
  final bool asleep;
  final VoidCallback onSleep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: MuseBubble(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: MuseLogo(size: 36),
            ),
            IconButton(
              tooltip: 'Dashboard',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DashboardScreen(),
                ),
              ),
              icon: Icon(
                Icons.monitor_heart_outlined,
                color: theme.colorScheme.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: asleep ? 'Wake' : 'Sleep',
              onPressed: onSleep,
              icon: Icon(
                asleep ? Icons.wb_sunny_outlined : Icons.bedtime_outlined,
                color: theme.colorScheme.primary,
                size: 22,
              ),
            ),
            _BatteryIndicator(battery: battery),
            const SizedBox(width: 8),
          ],
        ),
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
          Text('$percent%', style: theme.textTheme.bodySmall),
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
  const _Character({required this.presentation, required this.asleep})
    : super(key: const ValueKey('companion_character'));

  final PresentationState presentation;
  final bool asleep;

  @override
  State<_Character> createState() => _CharacterState();
}

class _CharacterState extends State<_Character> with WidgetsBindingObserver {
  bool _holding = false;
  bool _pointerDown = false;
  int _bounce = 0;
  int _pets = 0;
  DateTime? _listenStarted;
  Timer? _arm;
  WakeWordService? _wakeWord;
  StreamSubscription<void>? _wakeWordSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounded / screen off: stop the mic, stop the battery drain.
    // Foreground companion screen is the only place detection runs.
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) {
      _syncWakeWord();
    } else {
      _wakeWord?.pause();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _wakeWordSub?.cancel();
    _wakeWordSub = scope.presentation.stream.listen((_) {
      if (mounted) _syncWakeWord();
    });
    _syncWakeWord();
  }

  @override
  void didUpdateWidget(_Character oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asleep != widget.asleep) _syncWakeWord();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wakeWordSub?.cancel();
    _wakeWord?.dispose();
    _arm?.cancel();
    super.dispose();
  }

  /// Keep openWakeWord in step with the wake-word settings. Idempotent.
  Future<void> _syncWakeWord() async {
    if (!mounted) return;
    final scope = AppScope.of(context);
    final settings = scope.presentation.settings;
    _wakeWord ??= WakeWordService(onDetected: _onWakeWord);
    await _wakeWord!.sync(
      enabled: settings.wakeWordEnabled && !widget.asleep,
      sensitivity: settings.wakeWordSensitivity,
    );
  }

  /// Wake word was heard: barge in on any speech, then record a timed
  /// voice note and post it — the same pipeline as voice.listen.
  Future<void> _onWakeWord() async {
    if (!mounted) return;
    final scope = AppScope.of(context);
    if (scope.presentation.pose == AvatarPose.speaking) {
      await stopSpeaking(scope.phone, scope.presentation);
      if (!mounted) return;
    }
    // The mic can't be shared: pause detection while we record.
    await _wakeWord?.pause();
    scope.presentation.applyPose(AvatarPose.listening);
    scope.presentation.applyStatus('Listening…');
    try {
      if (!scope.service.isRegistered) {
        _needMuse();
        return;
      }
      // 10s gives time for a full spoken command after the keyword.
      final wav = await scope.phone.recordWav(10);
      if (!mounted) return;
      final id = scope.chat.addSending('Voice note');
      final result = await scope.service.sendChat('🎤 Voice note', null, [
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
          error is String && error.isNotEmpty ? error : 'send failed',
        );
      }
    } on PhoneActionException catch (e) {
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (_) {
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
    } finally {
      if (mounted) scope.presentation.applyPose(AvatarPose.idle);
      await _wakeWord?.resume();
    }
  }

  void _needMuse() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Connect to your Muse before talking.')),
    );
  }

  /// A release before this fires is a pet. The hold itself is unchanged.
  static const _armDelay = Duration(milliseconds: 220);

  void _holdStart() {
    if (widget.asleep) return;
    final scope = AppScope.of(context);
    if (scope.presentation.pose == AvatarPose.speaking) {
      // The user is jumping in with more relevant info: stop the speech
      // first, then proceed with the normal hold-to-talk flow.
      unawaited(stopSpeaking(scope.phone, scope.presentation));
    }
    _pointerDown = true;
    setState(() => _bounce++);
    if (_holding || _arm != null) return;
    _arm = Timer(_armDelay, () {
      _arm = null;
      if (!mounted || !_pointerDown) return;
      unawaited(_beginRecording());
    });
  }

  void _pet() {
    if (!mounted) return;
    final scope = AppScope.of(context);
    if (scope.presentation.pose == AvatarPose.speaking) {
      // A tap while talking is barge-in, not a pet.
      unawaited(stopSpeaking(scope.phone, scope.presentation));
      return;
    }
    setState(() => _pets++);
    if (!scope.service.isRegistered) _needMuse();
  }

  Future<void> _beginRecording() async {
    if (_holding || !_pointerDown) return;
    final scope = AppScope.of(context);
    if (!scope.service.isRegistered) {
      if (!mounted) return;
      _needMuse();
      return;
    }
    _holding = true;
    scope.presentation.applyPose(AvatarPose.listening);
    scope.presentation.applyStatus('Listening…');
    try {
      await scope.phone.startRecording();
      _listenStarted = DateTime.now();
      if (mounted) setState(() {});
    } on PhoneActionException catch (e) {
      _holding = false;
      _listenStarted = null;
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _holdEnd() async {
    _pointerDown = false;
    final pending = _arm;
    if (pending != null) {
      pending.cancel();
      _arm = null;
      _pet();
      return;
    }
    if (!_holding) return;
    _holding = false;
    _listenStarted = null;
    final scope = AppScope.of(context);
    scope.presentation.applyPose(AvatarPose.thinking);
    scope.presentation.applyStatus('Thinking…');
    try {
      final wav = await scope.phone.stopRecording();
      if (!mounted) return;
      final id = scope.chat.addSending('Voice note');
      final result = await scope.service.sendChat('\U0001f3a4 Voice note', null, [
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
          error is String && error.isNotEmpty ? error : 'send failed',
        );
        scope.presentation.applyPose(AvatarPose.idle);
      }
    } on PhoneActionException catch (e) {
      _listenStarted = null;
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      _listenStarted = null;
      if (!mounted) return;
      scope.presentation.applyPose(AvatarPose.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = widget.presentation;
    final bytes = presentation.character;
    final connected = presentation.connection == ConnectionState.connected;
    final accent = Color(0xFF000000 | avatarAccent(presentation.pose));
    final link = presentation.connection;
    final face = avatarFaceWord(
      presentation.pose,
      connecting: link == ConnectionState.connecting,
      reconnecting: link == ConnectionState.waiting,
    );
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: widget.asleep ? null : (_) => _holdStart(),
      onPointerUp: widget.asleep ? null : (_) => _holdEnd(),
      onPointerCancel: widget.asleep ? null : (_) => _holdEnd(),
      child: Column(
        children: [
          TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: accent),
            duration: const Duration(milliseconds: 420),
            builder: (context, color, _) {
              final ink = color ?? accent;
              final live = presentation.pose == AvatarPose.listening;
              return FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.mic,
                      size: 18,
                      color: live ? ink : ink.withValues(alpha: 0.28),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      face,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: ink,
                        letterSpacing: 3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                AvatarVideoStage(
                  pose: presentation.pose,
                  bytes: bytes,
                  bounceGeneration: _bounce,
                  petGeneration: _pets,
                  listenStarted: _listenStarted,
                ),
                if (presentation.pose == AvatarPose.speaking)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: IconButton(
                      tooltip: 'Stop speaking',
                      icon: const Icon(Icons.stop_circle_outlined),
                      iconSize: 34,
                      color: accent,
                      onPressed: () {
                        final scope = AppScope.of(context);
                        unawaited(
                          stopSpeaking(scope.phone, scope.presentation),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (bytes == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(
                connected
                    ? 'Asking your Muse for a character…'
                    : 'Waiting for character',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: museMist.withValues(alpha: 0.88),
                ),
              ),
            ),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: MuseBubble(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final line in lines)
              Text(
                line,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFF000000 | avatarCaptionRgb),
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Slim connection status pill for the Home tab. The old _BottomBar
/// navigation buttons (chat, settings) moved to the tab bar and
/// "say it again" moved to the Chat tab app bar; this keeps only
/// the status bubble and the contextual Pair button.
class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({
    super.key,
    required this.state,
    required this.detail,
  });

  final ConnectionState state;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = detail.isEmpty ? connectionStatusLabel(state) : detail;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MuseBubble(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(state: state),
                const SizedBox(width: 8),
                Text(
                  status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (state == ConnectionState.unpaired)
            IconButton(
              tooltip: 'Pair',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<bool>(builder: (_) => const PairingScreen()),
              ),
              icon: const Icon(Icons.bluetooth, size: 20),
            ),
        ],
      ),
    );
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
