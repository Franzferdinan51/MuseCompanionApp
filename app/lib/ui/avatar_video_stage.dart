// Video-clip avatar stage: AI-generated Juno animations per pose.
//
// Three bundled clips (app/assets/avatar/):
//   juno_orb.mp4     — Juno standing, holding a glowing orb (calm)
//   juno_typing.mp4  — Juno with headphones, typing on a laptop (active)
//   juno_talking.mp4 — Juno in suit, head turning, beak moving (talking)
//
// Pose mapping:
//   idle/listening -> orb clip
//   thinking -> typing clip
//   speaking -> talking clip (beak moves while talking)
//   error/boot/off -> orb clip
//
// Falls back to [PixelStage] silently if video fails to load or the
// platform lacks video support (widget tests). Pauses playback when
// the app is backgrounded to save battery.
//
// A dedicated listening clip would complete the set (idle, listening,
// thinking, speaking); extend [_clipFor] + the controller set below.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app/avatar_motion.dart';
import 'pixel_stage.dart';

/// Asset paths for the avatar video clips.
const String _orbClip = 'assets/avatar/juno_orb.mp4';
const String _typingClip = 'assets/avatar/juno_typing.mp4';
const String _talkingClip = 'assets/avatar/juno_talking.mp4';

/// The avatar video clip to show.
enum _AvatarClip { orb, typing, talking }

/// Which clip to play for a pose.
_AvatarClip _clipFor(AvatarPose pose) {
  switch (pose) {
    case AvatarPose.thinking:
      return _AvatarClip.typing;
    case AvatarPose.speaking:
      return _AvatarClip.talking;
    case AvatarPose.idle:
    case AvatarPose.listening:
    case AvatarPose.error:
    case AvatarPose.boot:
    case AvatarPose.off:
      return _AvatarClip.orb;
  }
}

/// Drop-in replacement for [PixelStage] with the same constructor contract.
class AvatarVideoStage extends StatefulWidget {
  const AvatarVideoStage({
    super.key,
    required this.pose,
    required this.bytes,
    this.bounceGeneration = 0,
    this.petGeneration = 0,
    this.listenStarted,
  });

  final AvatarPose pose;
  final Uint8List? bytes;
  final int bounceGeneration;
  final int petGeneration;
  final DateTime? listenStarted;

  @override
  State<AvatarVideoStage> createState() => _AvatarVideoStageState();
}

class _AvatarVideoStageState extends State<AvatarVideoStage>
    with WidgetsBindingObserver {
  VideoPlayerController? _orb;
  VideoPlayerController? _typing;
  VideoPlayerController? _talking;
  bool _failed = false;
  bool _paused = false;
  _AvatarClip _activeClip = _AvatarClip.orb;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _orb?.dispose();
    _typing?.dispose();
    _talking?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Battery: pause video when backgrounded or screen off.
    final shouldPause =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive;
    if (shouldPause == _paused) return;
    _paused = shouldPause;
    if (_paused) {
      _orb?.pause();
      _typing?.pause();
      _talking?.pause();
    } else {
      _applyPose(widget.pose);
    }
  }

  @override
  void didUpdateWidget(AvatarVideoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pose != widget.pose) {
      _applyPose(widget.pose);
    }
  }

  Future<void> _init() async {
    try {
      final orb = VideoPlayerController.asset(_orbClip);
      final typing = VideoPlayerController.asset(_typingClip);
      final talking = VideoPlayerController.asset(_talkingClip);
      await Future.wait([
        orb.initialize(),
        typing.initialize(),
        talking.initialize(),
      ]);
      await Future.wait([
        orb.setLooping(true),
        typing.setLooping(true),
        talking.setLooping(true),
      ]);
      // Mute: these are silent animation loops.
      await Future.wait([
        orb.setVolume(0),
        typing.setVolume(0),
        talking.setVolume(0),
      ]);
      if (!mounted) {
        orb.dispose();
        typing.dispose();
        talking.dispose();
        return;
      }
      setState(() {
        _orb = orb;
        _typing = typing;
        _talking = talking;
      });
      _applyPose(widget.pose);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  VideoPlayerController? _controllerFor(_AvatarClip clip) {
    switch (clip) {
      case _AvatarClip.orb:
        return _orb;
      case _AvatarClip.typing:
        return _typing;
      case _AvatarClip.talking:
        return _talking;
    }
  }

  void _applyPose(AvatarPose pose) {
    if (_failed ||
        _paused ||
        _orb == null ||
        _typing == null ||
        _talking == null) {
      return;
    }
    final want = _clipFor(pose);
    if (want == _activeClip) {
      // Already on the right clip; ensure it is playing.
      _controllerFor(want)?.play();
      return;
    }
    setState(() => _activeClip = want);
    _orb?.pause();
    _typing?.pause();
    _talking?.pause();
    _controllerFor(want)?.play();
  }

  Widget _pixelFallback() {
    return PixelStage(
      pose: widget.pose,
      bytes: widget.bytes,
      bounceGeneration: widget.bounceGeneration,
      petGeneration: widget.petGeneration,
      listenStarted: widget.listenStarted,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || _orb == null || _typing == null || _talking == null) {
      return _pixelFallback();
    }

    // Force a square of min(width, height), centered -- matching the old
    // PixelStage painter geometry (circle inscribed in the smaller
    // dimension). Without this, ClipOval on a non-square box stretches
    // the 1:1 video into an ellipse.
    return Center(
      child: AspectRatio(
        aspectRatio: 1.0,
        child: ClipOval(
          child: Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            children: [
              // Crossfade between clips on pose change.
              AnimatedOpacity(
                opacity: _activeClip == _AvatarClip.orb ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: VideoPlayer(_orb!),
              ),
              AnimatedOpacity(
                opacity: _activeClip == _AvatarClip.typing ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: VideoPlayer(_typing!),
              ),
              AnimatedOpacity(
                opacity: _activeClip == _AvatarClip.talking ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: VideoPlayer(_talking!),
              ),
              // Listening glow, matching the stage language.
              if (widget.pose == AvatarPose.listening) const _ListenGlow(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Soft pulsing glow while listening.
class _ListenGlow extends StatefulWidget {
  const _ListenGlow();

  @override
  State<_ListenGlow> createState() => _ListenGlowState();
}

class _ListenGlowState extends State<_ListenGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (ctx, child) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(
                0xFF9a6bff,
              ).withValues(alpha: 0.25 + 0.2 * _ac.value),
              blurRadius: 40 + 20 * _ac.value,
              spreadRadius: 4,
            ),
          ],
        ),
      ),
    );
  }
}
