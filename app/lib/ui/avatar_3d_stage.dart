// Real-time 3D avatar stage, preferred over the video-clip stage.
//
// Uses flutter_3d_controller to render a rigged GLB duck with named
// animation clips mapped from AvatarPose. Falls back to
// [AvatarVideoStage] (which itself falls back to [PixelStage]) silently
// if the model fails to load or the platform lacks a 3D webview
// (widget tests, desktop).
//
// Model swap: the GLB path is the [avatarModelAsset] constant below.
// Replace app/assets/avatar/duck.glb and update the constant (or keep
// the filename) — no other code changes needed. See
// app/assets/avatar/README.md.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';

import '../app/avatar_motion.dart';
import '../app/phone_bridge.dart';
import 'avatar_video_stage.dart';

/// Asset path for the 3D avatar model. One-line swap point for the
/// real noir-duck model when it's ready.
const String avatarModelAsset = 'assets/avatar/duck.glb';

/// Pose -> animation clip name mapping for the bundled duck model.
String _poseAnimation(AvatarPose pose) {
  switch (pose) {
    case AvatarPose.idle:
    case AvatarPose.boot:
    case AvatarPose.off:
      return 'idle';
    case AvatarPose.listening:
      return 'idle';
    case AvatarPose.thinking:
      return 'walk';
    case AvatarPose.speaking:
      // Beak flap is driven by _flapTimer alternating idle/attack.
      return 'idle';
    case AvatarPose.error:
      return 'dead';
  }
}

/// Drop-in replacement for [PixelStage] with the same constructor contract.
class Avatar3DStage extends StatefulWidget {
  const Avatar3DStage({
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
  State<Avatar3DStage> createState() => _Avatar3DStageState();
}

class _Avatar3DStageState extends State<Avatar3DStage>
    with WidgetsBindingObserver {
  final Flutter3DController _controller = Flutter3DController();
  bool _loadFailed = false;
  bool _modelReady = false;
  String _currentClip = '';
  Timer? _flapTimer;
  bool _flapOpen = false;
  bool _paused = false;

  /// True when the 3D webview platform is available (real Android/iOS).
  /// Falls back to pixel rendering in widget tests and on desktop/web.
  bool get _canRender3D =>
      !_loadFailed && !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PhoneBridge.speaking.addListener(_onSpeakingChanged);
    _applyPose(widget.pose);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PhoneBridge.speaking.removeListener(_onSpeakingChanged);
    _flapTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Battery: pause 3D rendering when the app is backgrounded or the
    // screen is off. Removing the viewer from the tree stops its render loop.
    final shouldPause = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive;
    if (shouldPause != _paused) {
      setState(() => _paused = shouldPause);
    }
  }

  @override
  void didUpdateWidget(Avatar3DStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pose != widget.pose) {
      _applyPose(widget.pose);
    }
  }

  void _onSpeakingChanged() {
    // Keep the 3D stage in sync with the single source of truth.
    if (!mounted || !_canRender3D) return;
    _applyPose(widget.pose);
  }

  void _applyPose(AvatarPose pose) {
    if (!_modelReady || !_canRender3D) return;
    _flapTimer?.cancel();
    _flapTimer = null;
    _flapOpen = false;

    if (pose == AvatarPose.speaking) {
      // 80/20 lip-sync: alternate idle (beak closed) and attack
      // (beak open) at speech cadence while TTS is active.
      _playClip('idle');
      var tick = 0;
      _flapTimer = Timer.periodic(const Duration(milliseconds: 170), (_) {
        if (!mounted) return;
        if (!PhoneBridge.speaking.value) {
          _flapTimer?.cancel();
          _flapTimer = null;
          _playClip(_poseAnimation(widget.pose));
          return;
        }
        tick++;
        // Slightly irregular cadence reads as speech, not a metronome.
        final open = (tick + (tick ~/ 3)) % 2 == 0;
        if (open != _flapOpen) {
          _flapOpen = open;
          _playClip(open ? 'attack' : 'idle');
        }
      });
    } else {
      _playClip(_poseAnimation(pose));
    }
  }

  void _playClip(String clip) {
    if (clip == _currentClip) return;
    _currentClip = clip;
    // loopCount 0 = infinite loop in flutter_3d_controller.
    _controller.playAnimation(animationName: clip, loopCount: 0);
  }

  /// Silent fallback to the video stage (which falls back to the pixel
  /// stage). Never crash on a bad model or missing 3D platform.
  Widget _videoFallback() {
    return AvatarVideoStage(
      pose: widget.pose,
      bytes: widget.bytes,
      bounceGeneration: widget.bounceGeneration,
      petGeneration: widget.petGeneration,
      listenStarted: widget.listenStarted,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_canRender3D) {
      return _videoFallback();
    }

    // While paused (backgrounded), render nothing — the webview's render
    // loop stops when it's off the tree, saving battery.
    if (_paused) {
      return const SizedBox.expand();
    }

    return ClipOval(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Flutter3DViewer(
            src: avatarModelAsset,
            controller: _controller,
            // Parent Listener owns all gestures (hold-to-talk, tap).
            // Touch inside the viewer would swallow them.
            enableTouch: false,
            activeGestureInterceptor: false,
            progressBarColor: Colors.transparent,
            onLoad: (_) {
              if (!mounted) return;
              setState(() => _modelReady = true);
              _currentClip = '';
              _applyPose(widget.pose);
            },
            onError: (_) {
              if (!mounted) return;
              setState(() => _loadFailed = true);
            },
          ),
          // Listening glow overlay, kept from the pixel stage language.
          if (widget.pose == AvatarPose.listening) const _ListenGlow(),
        ],
      ),
    );
  }
}

/// Soft pulsing glow behind the duck while listening.
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
              color: const Color(0xFF9a6bff).withValues(
                alpha: 0.25 + 0.2 * _ac.value,
              ),
              blurRadius: 40 + 20 * _ac.value,
              spreadRadius: 4,
            ),
          ],
        ),
      ),
    );
  }
}
