// The round pixel stage the companion screen and the dashboard share.
//
// A downloaded portrait is drawn from the picture itself, filtered, so a
// photo stays sharp. A 64x64 cover-crop is only used to find the body and
// the backdrop. Pose motion, rings, thought dots, and the listening meter
// still follow the Waveshare UI. Animated GIF and WebP frames are kept,
// capped, and stepped on their own durations. A GLB still uses the 3D
// viewer inside the same circle.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../app/avatar_life.dart';
import '../app/avatar_motion.dart';
import '../app/model.dart';
import '../app/pixel_avatar.dart';

/// Longest edge kept for a portrait. The stage is a few hundred pixels, so
/// this stays sharp without holding a multi-megabyte animation in memory.
const int portraitMaxEdge = 640;

class PixelStage extends StatefulWidget {
  const PixelStage({
    super.key,
    required this.pose,
    required this.bytes,
    this.bounceGeneration = 0,
    this.petGeneration = 0,
    this.listenStarted,
  });

  final AvatarPose pose;
  final Uint8List? bytes;

  /// Increment to play a tap bounce. Hold-to-talk owns the pointer.
  final int bounceGeneration;

  /// Increment to play the happy pet reaction. Ignored while in error.
  final int petGeneration;

  /// When the current push-to-talk hold began. The fixed bezel fills over
  /// [listenRingSeconds]. Null leaves the listen arc empty. Speaking does
  /// not use this; the board only fills the ring while recording.
  final DateTime? listenStarted;

  @override
  State<PixelStage> createState() => _PixelStageState();
}

class _PixelFrames {
  _PixelFrames(this.images, this.durationsMs, this.bodies);

  final List<ui.Image> images;
  final List<int> durationsMs;
  final List<CharacterFrame> bodies;

  int indexAt(Duration elapsed) {
    if (images.length <= 1) return 0;
    var total = 0;
    for (final duration in durationsMs) {
      total += duration <= 0 ? 100 : duration;
    }
    if (total <= 0) return 0;
    var t = elapsed.inMilliseconds % total;
    for (var i = 0; i < images.length; i++) {
      final duration = durationsMs[i] <= 0 ? 100 : durationsMs[i];
      if (t < duration) return i;
      t -= duration;
    }
    return 0;
  }

  void dispose() {
    for (final image in images) {
      image.dispose();
    }
  }
}

class _StageClock extends ChangeNotifier {
  double seconds = 0;
  double shut = 0;
  ui.Image? image;
  CharacterFrame body = const CharacterFrame.full();
  AvatarPose pose = AvatarPose.idle;
  AvatarPose from = AvatarPose.idle;
  double blend = 1;
  double flourish = 0;
  double nudge = 0;
  double modeT = 0;
  double happy = 0;
  double listenProgress = 0;
  int hot = 0xf4e8ff;
  int mid = 0x9a6bff;
  int deep = 0x5b3fd9;
  int blendedAccent = 0xa77dff;
  AvatarLife life = avatarLife(
    pose: AvatarPose.idle,
    seconds: 0,
    modeT: 0,
    level: 0,
    happy: 0,
    blinkShut: 0,
    gazeX: 0,
    gazeY: 0,
  );

  void tick({
    required double seconds,
    required double shut,
    required ui.Image? image,
    required CharacterFrame body,
    required AvatarPose pose,
    required AvatarPose from,
    required double blend,
    required double flourish,
    required double nudge,
    required double modeT,
    required double happy,
    required double listenProgress,
    required AvatarLife life,
    required int hot,
    required int mid,
    required int deep,
    required int blendedAccent,
  }) {
    this.seconds = seconds;
    this.shut = shut;
    this.image = image;
    this.body = body;
    this.pose = pose;
    this.from = from;
    this.blend = blend;
    this.flourish = flourish;
    this.nudge = nudge;
    this.modeT = modeT;
    this.happy = happy;
    this.listenProgress = listenProgress;
    this.life = life;
    this.hot = hot;
    this.mid = mid;
    this.deep = deep;
    this.blendedAccent = blendedAccent;
    notifyListeners();
  }
}

class _PixelStageState extends State<PixelStage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final BlinkClock _blink = BlinkClock();
  final PaletteClock _palette = PaletteClock();
  final GazeClock _gaze = GazeClock();
  final _StageClock _clock = _StageClock();
  Duration _lastTick = Duration.zero;
  _PixelFrames? _frames;
  int _generation = 0;
  String? _modelPath;
  late AvatarPose _shown;
  late AvatarPose _from;
  double _blend = 1;
  double _flourish = 0;
  double _nudge = 0;
  double _modeT = 0;
  double _happy = 0;
  int _seenPets = 0;

  @override
  void initState() {
    super.initState();
    _shown = widget.pose;
    _from = widget.pose;
    _ticker = createTicker(_onTick)..start();
    _load(widget.bytes);
  }

  @override
  void didUpdateWidget(PixelStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bounceGeneration != oldWidget.bounceGeneration) {
      _nudge = 1;
    }
    if (widget.petGeneration != oldWidget.petGeneration &&
        widget.pose != AvatarPose.error) {
      _happy = 1;
      _seenPets = widget.petGeneration;
    }
    if (!identical(widget.bytes, oldWidget.bytes)) {
      _load(widget.bytes);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    final frames = _frames;
    _frames = null;
    // The painter listens to the clock. Unmount removes that listener;
    // disposing the clock first asserts in debug.
    super.dispose();
    frames?.dispose();
    _clock.dispose();
  }

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _lastTick).inMicroseconds / 1000000;
    if (_lastTick == Duration.zero) {
      dt = 0.04;
    } else if (dt < 0) {
      dt = 0;
    } else if (dt > 0.2) {
      dt = 0.2;
    }
    _lastTick = elapsed;
    if (widget.pose != _shown) {
      _from = _shown;
      _shown = widget.pose;
      _blend = 0;
      _flourish = 1;
      _modeT = 0;
    }
    _modeT += dt;
    if (widget.petGeneration != _seenPets) {
      _seenPets = widget.petGeneration;
      if (_shown != AvatarPose.error) _happy = 1;
    }
    if (_shown == AvatarPose.error) {
      _happy = 0;
    } else if (_happy > 0) {
      _happy = (_happy - dt / 1.6).clamp(0.0, 1.0);
    }
    _palette.step(dt, _shown);
    _gaze.step(dt, pose: _shown, modeT: _modeT);
    if (_blend < 1) _blend = (_blend + dt / 0.42).clamp(0.0, 1.0);
    if (_flourish > 0) _flourish = (_flourish - dt / 0.55).clamp(0.0, 1.0);
    if (_nudge > 0) _nudge = (_nudge - dt / 0.38).clamp(0.0, 1.0);
    final frames = _frames;
    ui.Image? image;
    var body = const CharacterFrame.full();
    if (frames != null && frames.images.isNotEmpty) {
      final index = frames.indexAt(elapsed);
      image = frames.images[index];
      if (index < frames.bodies.length) body = frames.bodies[index];
    }
    _publish(image, body, _blink.advance(dt), elapsed.inMicroseconds / 1000000);
  }

  /// Ring fill for the hold that is in progress. Wall time, not the
  /// animation clock, so a paused ticker cannot stretch the 15 seconds.
  double _listenProgress() {
    final started = widget.listenStarted;
    if (started == null) return 0;
    return listenRingProgress(DateTime.now().difference(started));
  }

  void _publish(
    ui.Image? image,
    CharacterFrame body,
    double shut,
    double seconds,
  ) {
    final level = avatarLevel(_shown, seconds);
    _clock.tick(
      seconds: seconds,
      shut: shut,
      image: image,
      body: image == null ? const CharacterFrame.full() : body,
      pose: _shown,
      from: _from,
      blend: _blend,
      flourish: _flourish,
      nudge: _nudge,
      modeT: _modeT,
      happy: _happy,
      listenProgress: _listenProgress(),
      life: avatarLife(
        pose: _shown,
        seconds: seconds,
        modeT: _modeT,
        level: level,
        happy: _happy,
        blinkShut: shut,
        gazeX: _gaze.x,
        gazeY: _gaze.y,
      ),
      hot: _palette.f0.hex,
      mid: _palette.f2.hex,
      deep: _palette.f3.hex,
      blendedAccent: _palette.accent.hex,
    );
  }

  Future<void> _load(Uint8List? bytes) async {
    final generation = ++_generation;
    final previous = _frames;
    _frames = null;
    _modelPath = null;
    // Drop the painted frame before its image is disposed.
    _publish(null, const CharacterFrame.full(), _clock.shut, _clock.seconds);
    previous?.dispose();
    // initState and didUpdateWidget both run before build, so clearing the
    // frames here is enough. setState in that window throws.
    if (bytes == null || bytes.isEmpty) return;
    if (isGlbModel(bytes)) {
      try {
        final path = await _stageModel(bytes);
        if (!mounted || generation != _generation) return;
        setState(() => _modelPath = path);
      } catch (_) {
        if (!mounted || generation != _generation) return;
        setState(() {});
      }
      return;
    }
    try {
      final frames = await _decode(bytes);
      if (!mounted || generation != _generation) {
        frames.dispose();
        return;
      }
      _clock.image = frames.images.isEmpty ? null : frames.images.first;
      setState(() => _frames = frames);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StagePainter(
        clock: _clock,
        pose: widget.pose,
        model: _modelPath != null,
      ),
      child: _modelPath == null
          ? const SizedBox.expand()
          : ClipOval(
              child: ModelViewer(
                src: 'file://$_modelPath',
                autoRotate: true,
                disableZoom: true,
                backgroundColor: Colors.black,
              ),
            ),
    );
  }
}

Future<_PixelFrames> _decode(Uint8List bytes) async {
  final target = await _portraitWidth(bytes);
  final codec = target == null
      ? await ui.instantiateImageCodec(bytes)
      : await ui.instantiateImageCodec(bytes, targetWidth: target);
  try {
    final count = codec.frameCount.clamp(1, 24);
    final images = <ui.Image>[];
    final durations = <int>[];
    final bodies = <CharacterFrame>[];
    for (var i = 0; i < count; i++) {
      final frame = await codec.getNextFrame();
      try {
        final sprite = await _portraitFrame(frame.image);
        images.add(sprite.image);
        bodies.add(sprite.body);
        durations.add(frame.duration.inMilliseconds);
      } catch (_) {
        frame.image.dispose();
        rethrow;
      }
    }
    return _PixelFrames(images, durations, bodies);
  } finally {
    codec.dispose();
  }
}

/// Width to decode at, or null to keep the file's own size.
Future<int?> _portraitWidth(Uint8List bytes) async {
  final probe = await ui.instantiateImageCodec(bytes);
  try {
    final first = await probe.getNextFrame();
    final width = first.image.width;
    first.image.dispose();
    if (width > portraitMaxEdge) return portraitMaxEdge;
    return null;
  } finally {
    probe.dispose();
  }
}

/// Keep [source] for drawing. The 64-grid is only the body and backdrop.
Future<({ui.Image image, CharacterFrame body})> _portraitFrame(
  ui.Image source,
) async {
  final data = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    return (image: source, body: const CharacterFrame.full());
  }
  final keyed = keyCharacter(
    coverCropGrid(data.buffer.asUint8List(), source.width, source.height),
  );
  return (image: source, body: keyed.frame);
}

Future<String> _stageModel(Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/muse_avatar.glb');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

class _StagePainter extends CustomPainter {
  _StagePainter({required this.clock, required this.pose, required this.model})
    : super(repaint: clock);

  final _StageClock clock;
  final AvatarPose pose;
  final bool model;

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = clock.seconds;
    final image = clock.image;
    final smooth = _smooth(clock.blend);
    final fromMotion = avatarMotion(clock.from, seconds);
    final toMotion = avatarMotion(pose, seconds);
    final motion = _mixMotion(fromMotion, toMotion, smooth);
    final side = math.min(size.width, size.height);
    if (side <= 0) return;
    final origin = Offset((size.width - side) / 2, (size.height - side) / 2);
    final center = origin + Offset(side / 2, side / 2);
    final cell = side / pixelGrid;
    final life = clock.life;
    final accent = Color(0xFF000000 | clock.blendedAccent);
    final level = avatarLevel(pose, seconds);

    canvas.drawCircle(
      center,
      side / 2 + 8,
      Paint()
        ..color = const Color(0x551877F2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    if (life.aura > 0.02) {
      final auraRadius = (29 + level * 4 + math.sin(seconds * 1.5)) * cell;
      final auraColor =
          Color.lerp(
            Color(0xFF000000 | clock.mid),
            Color(0xFF000000 | clock.deep),
            0.35,
          ) ??
          Color(0xFF000000 | clock.mid);
      canvas.drawCircle(
        center,
        auraRadius.clamp(cell * 8, side * 0.48),
        Paint()
          ..color = auraColor.withValues(alpha: life.aura.clamp(0.0, 0.85))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }
    canvas.drawCircle(
      center,
      side / 2,
      Paint()..color = const Color(0xFF000000),
    );

    final bezel = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(4, side * 0.02)
      ..color = const Color(0xFF1877F2);
    final bezelRect = Rect.fromCircle(
      center: center,
      radius: side / 2 - bezel.strokeWidth,
    );
    canvas.drawCircle(center, side / 2 - bezel.strokeWidth, bezel);
    canvas.drawArc(
      bezelRect,
      math.pi * 1.15,
      math.pi * 0.5,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, side * 0.008)
        ..strokeCap = StrokeCap.round
        ..color = const Color(0x99FFFFFF),
    );

    if (clock.flourish > 0.02) {
      canvas.drawCircle(
        center,
        side * (0.18 + 0.34 * (1 - clock.flourish)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2, side * 0.012)
          ..color = accent.withValues(alpha: clock.flourish.clamp(0.0, 0.9)),
      );
    }

    // Bezel chrome stays on the fixed disc. muse_ui.c draws a 60° spinner
    // at 300°/s while thinking, and a progress arc from the top while the
    // microphone is held. Speaking leaves the arc empty.
    final thinking = _poseWeight(AvatarPose.thinking, smooth);
    final listening = _poseWeight(AvatarPose.listening, smooth);
    final speaking = _poseWeight(AvatarPose.speaking, smooth);
    if (thinking > 0.04) {
      final arc = thinkingBezelArc(seconds);
      final sweep = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = bezel.strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = accent.withValues(alpha: thinking);
      canvas.drawArc(bezelRect, arc.start, arc.sweep, false, sweep);
      // Orbiting balls like Muse's thinking indicator.
      // Three glowing balls circle the avatar at different speeds/phases.
      for (var b = 0; b < 3; b++) {
        final orbitRadius = side * (0.38 + b * 0.04);
        final ballAngle = seconds * (2.2 + b * 0.4) + b * 2.1;
        final cx = side / 2 + math.cos(ballAngle) * orbitRadius;
        final cy = side / 2 + math.sin(ballAngle) * orbitRadius;
        // Trail
        for (var t = 1; t <= 3; t++) {
          final trailAngle = ballAngle - t * 0.15;
          final tx = side / 2 + math.cos(trailAngle) * orbitRadius;
          final ty = side / 2 + math.sin(trailAngle) * orbitRadius;
          final trailPaint = Paint()
            ..color = accent.withValues(alpha: thinking * (0.3 - t * 0.08));
          canvas.drawCircle(Offset(tx, ty), cell * (0.8 - t * 0.15), trailPaint);
        }
        // Glow
        final ballPaint = Paint()
          ..color = accent.withValues(alpha: thinking)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
        canvas.drawCircle(Offset(cx, cy), cell * 1.4, ballPaint);
        // Solid core
        final corePaint = Paint()
          ..color = Colors.white.withValues(alpha: thinking * 0.9);
        canvas.drawCircle(Offset(cx, cy), cell * 0.5, corePaint);
      }
    }
    // Idle: breathing pulse with glow and subtle ring.
    final idleW = _poseWeight(AvatarPose.idle, smooth);
    if (idleW > 0.04) {
      final breath = (math.sin(seconds * 1.8) + 1) / 2; // 0..1
      final glowAlpha = idleW * (0.2 + breath * 0.25);
      final glowPaint = Paint()
        ..color = accent.withValues(alpha: glowAlpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      final glowRadius = side * (0.32 + breath * 0.06);
      canvas.drawCircle(
          Offset(side / 2, side / 2), glowRadius, glowPaint);
      // Breathing ring
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = accent.withValues(alpha: idleW * (0.3 + breath * 0.3));
      canvas.drawCircle(
          Offset(side / 2, side / 2), side * (0.38 + breath * 0.02), ringPaint);
    }
    // Listening: expanding sound-wave rings with pulsing core.
    if (listening > 0.04) {
      // Pulsing core
      final pulse = (math.sin(seconds * 4) + 1) / 2;
      final coreGlow = Paint()
        ..color = accent.withValues(alpha: listening * (0.3 + pulse * 0.3))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(
          Offset(side / 2, side / 2), side * 0.28, coreGlow);
      // Expanding waves
      for (var i = 0; i < 4; i++) {
        final phase = (seconds * 1.0 + i / 4) % 1.0;
        final radius = side * (0.22 + phase * 0.3);
        final alpha = listening * (1 - phase) * 0.7;
        final wavePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 - phase * 1.5
          ..color = accent.withValues(alpha: alpha);
        canvas.drawCircle(Offset(side / 2, side / 2), radius, wavePaint);
      }
    }
    // Speaking: animated waveform bars with glow.
    if (speaking > 0.04) {
      const barCount = 9;
      final barWidth = side * 0.055;
      final baseY = side * 0.88;
      for (var i = 0; i < barCount; i++) {
        final t = seconds * 8 + i * 0.7;
        final t2 = seconds * 5 - i * 0.5;
        final height = ((math.sin(t) * 0.5 + 0.5) * 0.7 +
                (math.sin(t2) * 0.5 + 0.5) * 0.3) *
            side *
            0.12 +
            side * 0.015;
        final x = side / 2 + (i - barCount / 2 + 0.5) * barWidth * 1.4;
        // Glow behind bar
        final glowPaint = Paint()
          ..color = accent.withValues(alpha: speaking * 0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(x, baseY - height / 2),
                width: barWidth * 0.7,
                height: height),
            const Radius.circular(3),
          ),
          glowPaint,
        );
        // Solid bar
        final barPaint = Paint()
          ..color = accent.withValues(alpha: speaking * 0.95);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(x, baseY - height / 2),
                width: barWidth * 0.45,
                height: height),
            const Radius.circular(2),
          ),
          barPaint,
        );
      }
      // Speaking halo
      final haloPulse = (math.sin(seconds * 6) + 1) / 2;
      final haloPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent.withValues(alpha: speaking * (0.2 + haloPulse * 0.2));
      canvas.drawCircle(Offset(side / 2, side / 2),
          side * (0.36 + haloPulse * 0.02), haloPaint);
    } else if (listening > 0.04 && clock.listenProgress > 0.004) {
      final arc = listenBezelArc(clock.listenProgress);
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = bezel.strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = accent.withValues(alpha: listening);
      canvas.drawArc(bezelRect, arc.start, arc.sweep, false, ring);
    }

    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: side / 2 - 1)),
    );
    // Stage space. Rings, sparkles, and dots orbit this fixed disc.
    // A picture fills the circle. The body bobs, the feet stay inside.
    canvas.translate(origin.dx, origin.dy);
    final backdrop = clock.body.backdrop;
    if (!model && image != null && clock.body.keyed && backdrop != 0) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, side, side),
        Paint()
          ..color = Color(
            backdrop,
          ).withValues(alpha: life.fade.clamp(0.0, 1.0)),
      );
    }

    final sparks = sparkles(seconds, pose, life.boot);
    _sparks(canvas, side, cell, accent, sparks, behind: true, fade: life.fade);

    final ringStrength = math.max(listening, speaking);
    if (ringStrength > 0.04) {
      final speed = listening >= speaking ? 0.9 : 0.6;
      _rings(
        canvas,
        Offset(side / 2, side / 2),
        cell,
        speed,
        accent,
        ringStrength,
      );
    }
    if (thinking > 0.04) {
      _dots(canvas, Offset(side * 0.70, side * 0.34), cell, accent, thinking);
    }
    if (life.waves > 0) {
      _waves(canvas, side, cell, accent, life.waves, seconds, life.fade);
    }

    final fromLean = clock.from == AvatarPose.error ? 0.0 : fromMotion.lean;
    final toLean = pose == AvatarPose.error ? life.lean : toMotion.lean;
    final lean = fromLean + (toLean - fromLean) * smooth + life.step;
    if (!model && image != null) {
      // Rows above the feet pick up the bob, the way muse_pixel.c moves
      // the body and leaves the feet. The backdrop fill stays still.
      _drawPlanted(
        canvas,
        image,
        clock.body,
        cell,
        bob: motion.bob,
        lean: lean,
        hop: life.hop + clock.nudge * 2.2,
        gazeX: life.gazeX,
        gazeY: life.gazeY,
        scale: motion.scale * (1 + life.breathe) * life.squash,
        fade: life.fade,
      );
    } else if (!model) {
      canvas.save();
      canvas.translate(side / 2, side / 2);
      canvas.translate(lean * cell, (motion.bob - life.hop) * cell);
      canvas.rotate(life.sway);
      final bounce = _bounceScale(clock.nudge);
      final pop = 1 + 0.04 * math.sin(clock.flourish * math.pi);
      final breathe = 1 + life.breathe;
      final wide = pose == AvatarPose.boot ? 1 + (1 - life.squash) * 0.45 : 1.0;
      canvas.scale(
        motion.scale * bounce * pop * breathe * wide,
        motion.scale * bounce * pop * breathe * life.squash,
      );
      canvas.translate(-side / 2, -side / 2);
      _face(canvas, side, cell, accent, life);
      canvas.restore();
    }

    _sparks(canvas, side, cell, accent, sparks, behind: false, fade: life.fade);
    if (life.hearts) _hearts(canvas, side, cell, accent, seconds, clock.happy);
    if (life.alert) _alert(canvas, side, cell, accent);
    canvas.restore();

    // The meter is an overlay on the bezel, not part of the bobbing sprite.
    if (listening > 0.04) {
      canvas.save();
      canvas.translate(origin.dx, origin.dy);
      canvas.clipPath(Path()..addOval(Rect.fromLTWH(0, 0, side, side)));
      _meter(canvas, side, cell, accent, listening);
      canvas.restore();
    }
  }

  /// Draw [image] in grid order, feet on their own row.
  ///
  /// Each row above the feet takes more of [bob], [lean], and [scale].
  /// A keyed body is scaled so the head and the feet sit inside the ring.
  /// The backdrop itself is already painted and does not move. Source
  /// samples come from the picture, not from a 64-pixel nearest copy.
  void _drawPlanted(
    Canvas canvas,
    ui.Image image,
    CharacterFrame frame,
    double cell, {
    required double bob,
    required double lean,
    required double hop,
    required double gazeX,
    required double gazeY,
    required double scale,
    required double fade,
  }) {
    final srcW = frame.right - frame.left + 1;
    if (srcW <= 0 || frame.bottom < frame.top || cell <= 0) return;
    if (image.width <= 0 || image.height <= 0) return;
    final place = placePortrait(frame);
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..isAntiAlias = true
      ..color = Color.fromRGBO(255, 255, 255, fade.clamp(0.0, 1.0));
    final destW = srcW * place.scale * cell;
    final side = math.min(image.width, image.height).toDouble();
    final x0 = (image.width - side) / 2;
    final y0 = (image.height - side) / 2;
    final texel = side / pixelGrid;
    final srcLeft = x0 + frame.left * texel;
    final srcWidth = srcW * texel;
    var y = place.ground * cell;
    for (var row = frame.bottom; row >= frame.top; row--) {
      final lift = frame.lift(row.toDouble());
      final grow = 1 + (scale - 1) * lift;
      final height = place.scale * cell * grow;
      y -= height;
      final shift = bodyRowShift(
        lift: lift,
        bob: bob,
        lean: lean,
        hop: hop,
        gazeX: gazeX,
        gazeY: gazeY,
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(srcLeft, y0 + row * texel, srcWidth, texel),
        Rect.fromLTWH(
          place.left * cell + shift.dx * cell,
          y + shift.dy * cell,
          destW,
          height + 0.75,
        ),
        paint,
      );
    }
  }

  double _poseWeight(AvatarPose target, double smooth) {
    final at = pose == target ? smooth : 0.0;
    final was = clock.from == target ? 1 - smooth : 0.0;
    return math.max(at, was);
  }

  /// Round placeholder until Muse sends its own picture. Not the stock
  /// firmware character: no hood, no peach face, no stubby arms. Eyes and
  /// a mouth follow the mode. A photo never gets these drawn on top.
  void _face(
    Canvas canvas,
    double side,
    double cell,
    Color accent,
    AvatarLife life,
  ) {
    final cx = side / 2;
    final cy = side / 2;
    final head = Paint()
      ..color = const Color(0xFF14182A).withValues(alpha: life.fade);
    canvas.drawCircle(Offset(cx, cy), 16 * cell, head);
    canvas.drawCircle(
      Offset(cx, cy),
      16 * cell,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, cell * 0.6)
        ..color = accent.withValues(alpha: 0.9 * life.fade),
    );
    _mitts(canvas, cx, cy, cell, accent, life);
    final eyeY = cy - 2 * cell + life.gazeY * cell;
    final dx = 6 * cell;
    final gx = life.gazeX * cell;
    _eye(canvas, Offset(cx - dx + gx, eyeY), cell, life);
    _eye(canvas, Offset(cx + dx + gx, eyeY), cell, life);
    if (pose == AvatarPose.listening ||
        (pose == AvatarPose.thinking && life.eye != FaceEye.shut)) {
      _brow(canvas, Offset(cx - dx + gx, eyeY), cell, accent, life, left: true);
      _brow(
        canvas,
        Offset(cx + dx + gx, eyeY),
        cell,
        accent,
        life,
        left: false,
      );
    }
    final blush = Paint()
      ..color = accent.withValues(alpha: (0.35 * life.blush) * life.fade);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - 11 * cell, eyeY + 3 * cell),
        width: 4 * cell,
        height: 2.4 * cell,
      ),
      blush,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx + 11 * cell, eyeY + 3 * cell),
        width: 4 * cell,
        height: 2.4 * cell,
      ),
      blush,
    );
    _mouth(canvas, Offset(cx, eyeY + 7 * cell), cell, accent, life);
  }

  void _eye(Canvas canvas, Offset at, double cell, AvatarLife life) {
    final ink = Paint()
      ..color = const Color(0xFF0B0D14).withValues(alpha: life.fade);
    final shine = Paint()..color = Colors.white.withValues(alpha: life.fade);
    switch (life.eye) {
      case FaceEye.shut:
        canvas.drawLine(
          at + Offset(-2 * cell, 0),
          at + Offset(2 * cell, 0),
          ink..strokeWidth = math.max(1.2, cell * 0.4),
        );
      case FaceEye.cross:
        final a = Paint()
          ..color = const Color(0xFFFF5C5C).withValues(alpha: life.fade)
          ..strokeWidth = math.max(1.4, cell * 0.45)
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          at + Offset(-2 * cell, -2 * cell),
          at + Offset(2 * cell, 2 * cell),
          a,
        );
        canvas.drawLine(
          at + Offset(2 * cell, -2 * cell),
          at + Offset(-2 * cell, 2 * cell),
          a,
        );
      case FaceEye.happy:
        final a = Paint()
          ..color = ink.color
          ..strokeWidth = math.max(1.4, cell * 0.45)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(
          Rect.fromCenter(
            center: at + Offset(0, cell),
            width: 4 * cell,
            height: 3 * cell,
          ),
          math.pi * 1.15,
          math.pi * 0.7,
          false,
          a,
        );
      case FaceEye.wide:
      case FaceEye.glance:
      case FaceEye.bead:
        final tall = life.eye == FaceEye.wide ? 5.0 : 4.0;
        canvas.drawOval(
          Rect.fromCenter(center: at, width: 4 * cell, height: tall * cell),
          ink,
        );
        canvas.drawCircle(at + Offset(-cell, -cell), cell * 0.45, shine);
    }
  }

  void _brow(
    Canvas canvas,
    Offset eye,
    double cell,
    Color accent,
    AvatarLife life, {
    required bool left,
  }) {
    final lift = life.eye == FaceEye.wide ? 1.0 : (left ? 0.2 : 1.0);
    final paint = Paint()
      ..color = accent.withValues(alpha: 0.85 * life.fade)
      ..strokeWidth = math.max(1.2, cell * 0.35)
      ..strokeCap = StrokeCap.round;
    final y = eye.dy - (4 + lift) * cell;
    canvas.drawLine(
      Offset(eye.dx - 2 * cell, y),
      Offset(eye.dx + 2 * cell, y - (left ? 0 : cell * 0.4)),
      paint,
    );
  }

  void _mouth(
    Canvas canvas,
    Offset at,
    double cell,
    Color accent,
    AvatarLife life,
  ) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.92 * life.fade);
    switch (life.mouth) {
      case FaceMouth.smile:
        canvas.drawArc(
          Rect.fromCenter(center: at, width: 6 * cell, height: 3 * cell),
          0.2,
          math.pi - 0.4,
          false,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.2, cell * 0.4)
            ..strokeCap = StrokeCap.round,
        );
      case FaceMouth.oh:
        canvas.drawCircle(
          at,
          1.6 * cell,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = cell * 0.45,
        );
        canvas.drawCircle(
          at + Offset(0, 0.4 * cell),
          0.55 * cell,
          Paint()..color = accent.withValues(alpha: life.fade),
        );
      case FaceMouth.hmm:
        canvas.drawLine(
          at + Offset(-1.2 * cell, 0.4 * cell),
          at + Offset(1.6 * cell, -0.3 * cell),
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.3, cell * 0.4)
            ..strokeCap = StrokeCap.round,
        );
      case FaceMouth.flat:
        canvas.drawLine(
          at + Offset(-3 * cell, 0),
          at + Offset(3 * cell, 0),
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.4, cell * 0.45)
            ..strokeCap = StrokeCap.round,
        );
      case FaceMouth.grin:
        canvas.drawArc(
          Rect.fromCenter(center: at, width: 8 * cell, height: 5 * cell),
          0.15,
          math.pi - 0.3,
          false,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.4, cell * 0.45)
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawCircle(
          at + Offset(0, 1.4 * cell),
          0.7 * cell,
          Paint()..color = accent.withValues(alpha: life.fade),
        );
      case FaceMouth.talk:
        final h = mouthHeight(life.talk).toDouble();
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: at + Offset(0, h * cell * 0.3),
              width: (h >= 3 ? 4 : 3) * cell,
              height: h * cell,
            ),
            Radius.circular(cell),
          ),
          paint..style = PaintingStyle.fill,
        );
        if (h >= 3) {
          canvas.drawCircle(
            at + Offset(0, h * cell * 0.45),
            0.7 * cell,
            Paint()..color = accent.withValues(alpha: life.fade),
          );
        }
    }
  }

  void _mitts(
    Canvas canvas,
    double cx,
    double cy,
    double cell,
    Color accent,
    AvatarLife life,
  ) {
    final paint = Paint()..color = accent.withValues(alpha: 0.9 * life.fade);
    void mitt(Offset at) => canvas.drawCircle(at, 2.2 * cell, paint);
    switch (life.arm) {
      case ArmCue.rest:
        final sway = life.armAngle * 10 * cell;
        mitt(Offset(cx - 18 * cell, cy + 6 * cell + sway));
        mitt(Offset(cx + 18 * cell, cy + 6 * cell - sway));
      case ArmCue.cup:
        mitt(Offset(cx - 18 * cell, cy + 5 * cell));
        mitt(Offset(cx + 18 * cell, cy + 5 * cell));
      case ArmCue.chin:
        mitt(Offset(cx + 4 * cell, cy + 14 * cell));
        mitt(Offset(cx - 18 * cell, cy + 8 * cell));
      case ArmCue.talk:
        final w = life.armAngle * 14 * cell;
        mitt(Offset(cx - 16 * cell, cy + 4 * cell - w));
        mitt(Offset(cx + 16 * cell, cy + 4 * cell + w));
      case ArmCue.wave:
        final w = life.armAngle * 12 * cell;
        mitt(Offset(cx + 16 * cell, cy - 10 * cell + w));
        mitt(Offset(cx - 18 * cell, cy + 8 * cell));
      case ArmCue.up:
        final w = life.armAngle * 12 * cell;
        mitt(Offset(cx - 14 * cell + w, cy - 12 * cell));
        mitt(Offset(cx + 14 * cell - w, cy - 12 * cell));
    }
  }

  void _sparks(
    Canvas canvas,
    double side,
    double cell,
    Color accent,
    List<Sparkle> sparks, {
    required bool behind,
    required double fade,
  }) {
    final paint = Paint();
    for (final spark in sparks) {
      if (spark.behind != behind) continue;
      paint.color = accent.withValues(
        alpha: (0.25 + 0.75 * spark.twinkle).clamp(0.0, 1.0) * fade,
      );
      canvas.drawCircle(
        Offset(side / 2 + spark.x * cell, side / 2 + spark.y * cell),
        cell * (0.55 + spark.twinkle * 0.8),
        paint,
      );
    }
  }

  void _waves(
    Canvas canvas,
    double side,
    double cell,
    Color accent,
    int count,
    double seconds,
    double fade,
  ) {
    final cy = side * 0.42;
    for (var k = 0; k < count; k++) {
      final flicker = waveFlicker(seconds, k);
      final radius = (7 + k * 3.5) * cell;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(1.2, cell * 0.35)
        ..color = accent.withValues(alpha: (0.25 + 0.7 * flicker) * fade);
      canvas.drawArc(
        Rect.fromCircle(
          center: Offset(side / 2 - 14 * cell, cy),
          radius: radius,
        ),
        math.pi * 0.55,
        math.pi * 0.9,
        false,
        paint,
      );
      canvas.drawArc(
        Rect.fromCircle(
          center: Offset(side / 2 + 14 * cell, cy),
          radius: radius,
        ),
        -math.pi * 0.45,
        math.pi * 0.9,
        false,
        paint,
      );
    }
  }

  void _hearts(
    Canvas canvas,
    double side,
    double cell,
    Color accent,
    double seconds,
    double happy,
  ) {
    for (var i = 0; i < 2; i++) {
      final phase = heartPhase(seconds, i);
      if (phase >= happy) continue;
      final at = Offset(
        side * (0.30 + i * 0.40),
        side * 0.30 - phase * 10 * cell,
      );
      _heart(
        canvas,
        at,
        2.4 * cell,
        accent.withValues(alpha: (1 - phase) * happy),
      );
    }
  }

  void _heart(Canvas canvas, Offset at, double s, Color color) {
    final paint = Paint()..color = color;
    canvas.drawCircle(at + Offset(-s * 0.28, -s * 0.12), s * 0.34, paint);
    canvas.drawCircle(at + Offset(s * 0.28, -s * 0.12), s * 0.34, paint);
    final path = Path()
      ..moveTo(at.dx - s * 0.58, at.dy)
      ..lineTo(at.dx, at.dy + s * 0.72)
      ..lineTo(at.dx + s * 0.58, at.dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _alert(Canvas canvas, double side, double cell, Color accent) {
    final painter = TextPainter(
      text: TextSpan(
        text: '!',
        style: TextStyle(
          color: accent,
          fontSize: cell * 8,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(side * 0.72, side * 0.18));
  }

  void _rings(
    Canvas canvas,
    Offset at,
    double cell,
    double speed,
    Color color,
    double strength,
  ) {
    for (var k = 0; k < 2; k++) {
      final phase = (clock.seconds * speed + k * 0.5) % 1.0;
      final cells = 20 + phase * 11;
      final radius = cells * cell;
      final level = avatarLevel(clock.pose, clock.seconds);
      final fade = (1 - phase) * (0.35 + level) * strength;
      final dot =
          Color.lerp(Color(0xFF000000 | clock.hot), color, 1 - phase) ?? color;
      final paint = Paint()
        ..color = dot.withValues(alpha: fade.clamp(0.0, 0.9));
      // muse_pixel.c uses about 2.2 dots per cell of radius.
      final dots = math.max(12, (cells * 2.2).round());
      for (var i = 0; i < dots; i++) {
        final angle = i * math.pi * 2 / dots;
        canvas.drawCircle(
          Offset(
            at.dx + math.cos(angle) * radius,
            at.dy + math.sin(angle) * radius * 0.92,
          ),
          math.max(1.2, cell * 0.28),
          paint,
        );
      }
    }
  }

  void _dots(
    Canvas canvas,
    Offset at,
    double cell,
    Color accent,
    double strength,
  ) {
    for (final dot in thoughtDots(clock.seconds)) {
      final paint = Paint()
        ..color = accent.withValues(
          alpha: (dot.active ? 1.0 : 0.45) * strength,
        );
      canvas.drawRect(
        Rect.fromLTWH(
          at.dx + dot.dx * cell,
          at.dy + dot.dy * cell,
          cell * 2,
          cell * 2,
        ),
        paint,
      );
    }
  }

  void _meter(
    Canvas canvas,
    double side,
    double cell,
    Color accent,
    double strength,
  ) {
    // No mic amplitude tap. A slow pulse keeps the centred meter alive
    // while the pose is listening, which is when the board shows it.
    final level = (0.35 + 0.4 * math.sin(clock.seconds * 6)).clamp(0.0, 1.0);
    final span = side * 0.62;
    final seg = span / meterSegments;
    final y = side * 0.86;
    for (var i = 0; i < meterSegments; i++) {
      final on = meterSegmentOn(i, level);
      final paint = Paint()
        ..color = (on ? accent : const Color(0xFF1D1733)).withValues(
          alpha: on ? strength : 0.35 * strength,
        );
      canvas.drawRect(
        Rect.fromLTWH(side * 0.19 + i * seg, y, seg * 0.72, math.max(3, cell)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StagePainter oldDelegate) {
    return oldDelegate.pose != pose ||
        oldDelegate.model != model ||
        oldDelegate.clock != clock;
  }
}

double _smooth(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

AvatarMotion _mixMotion(AvatarMotion from, AvatarMotion to, double t) {
  return AvatarMotion(
    bob: from.bob + (to.bob - from.bob) * t,
    lean: from.lean + (to.lean - from.lean) * t,
    scale: from.scale + (to.scale - from.scale) * t,
    rings: t >= 0.5 ? to.rings : from.rings,
    ringPhase: to.ringPhase,
  );
}

/// Press scale: dip, then a small overshoot, then rest. [nudge] is 1 at
/// the press and falls to 0.
double _bounceScale(double nudge) {
  final t = (1 - nudge).clamp(0.0, 1.0);
  if (nudge <= 0) return 1;
  if (t < 0.35) return 1 - 0.07 * (t / 0.35);
  if (t < 0.7) return 0.93 + 0.1 * ((t - 0.35) / 0.35);
  return 1.03 - 0.03 * ((t - 0.7) / 0.3);
}
