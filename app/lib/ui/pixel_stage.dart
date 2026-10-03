// The round pixel stage the companion screen and the dashboard share.
//
// A downloaded portrait is cover-cropped to 64x64 and drawn with
// nearest-neighbour sampling, then the same pose motion, rings, thought
// dots, and listening meter the Waveshare UI draws around its avatar.
// Animated GIF and WebP frames are kept, capped, and stepped on their
// own durations. A GLB still uses the 3D viewer inside the same circle.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../app/avatar_motion.dart';
import '../app/model.dart';
import '../app/pixel_avatar.dart';

class PixelStage extends StatefulWidget {
  const PixelStage({
    super.key,
    required this.pose,
    required this.bytes,
    this.bounceGeneration = 0,
  });

  final AvatarPose pose;
  final Uint8List? bytes;

  /// Increment to play a tap bounce. Hold-to-talk owns the pointer.
  final int bounceGeneration;

  @override
  State<PixelStage> createState() => _PixelStageState();
}

class _PixelFrames {
  _PixelFrames(this.images, this.durationsMs);

  final List<ui.Image> images;
  final List<int> durationsMs;

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
  AvatarPose pose = AvatarPose.idle;
  AvatarPose from = AvatarPose.idle;
  double blend = 1;
  double flourish = 0;
  double nudge = 0;

  void tick({
    required double seconds,
    required double shut,
    required ui.Image? image,
    required AvatarPose pose,
    required AvatarPose from,
    required double blend,
    required double flourish,
    required double nudge,
  }) {
    this.seconds = seconds;
    this.shut = shut;
    this.image = image;
    this.pose = pose;
    this.from = from;
    this.blend = blend;
    this.flourish = flourish;
    this.nudge = nudge;
    notifyListeners();
  }
}

class _PixelStageState extends State<PixelStage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final BlinkClock _blink = BlinkClock();
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
    final dt = ((elapsed - _lastTick).inMicroseconds / 1000000).clamp(
      0.0,
      0.05,
    );
    _lastTick = elapsed;
    if (widget.pose != _shown) {
      _from = _shown;
      _shown = widget.pose;
      _blend = 0;
      _flourish = 1;
    }
    if (_blend < 1) _blend = (_blend + dt / 0.42).clamp(0.0, 1.0);
    if (_flourish > 0) _flourish = (_flourish - dt / 0.55).clamp(0.0, 1.0);
    if (_nudge > 0) _nudge = (_nudge - dt / 0.38).clamp(0.0, 1.0);
    final frames = _frames;
    final image = frames == null
        ? null
        : frames.images[frames.indexAt(elapsed)];
    _publish(image, _blink.advance(dt), elapsed.inMicroseconds / 1000000);
  }

  void _publish(ui.Image? image, double shut, double seconds) {
    _clock.tick(
      seconds: seconds,
      shut: shut,
      image: image,
      pose: _shown,
      from: _from,
      blend: _blend,
      flourish: _flourish,
      nudge: _nudge,
    );
  }

  Future<void> _load(Uint8List? bytes) async {
    final generation = ++_generation;
    final previous = _frames;
    _frames = null;
    _modelPath = null;
    // Drop the painted frame before its image is disposed.
    _publish(null, _clock.shut, _clock.seconds);
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
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 128);
  try {
    final count = codec.frameCount.clamp(1, 24);
    final images = <ui.Image>[];
    final durations = <int>[];
    for (var i = 0; i < count; i++) {
      final frame = await codec.getNextFrame();
      try {
        images.add(await _gridImage(frame.image));
        durations.add(frame.duration.inMilliseconds);
      } finally {
        frame.image.dispose();
      }
    }
    return _PixelFrames(images, durations);
  } finally {
    codec.dispose();
  }
}

Future<ui.Image> _gridImage(ui.Image source) async {
  final data = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError('image has no pixels');
  }
  final grid = coverCropGrid(
    data.buffer.asUint8List(),
    source.width,
    source.height,
  );
  final buffer = await ui.ImmutableBuffer.fromUint8List(grid);
  try {
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: pixelGrid,
      height: pixelGrid,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    try {
      final gridCodec = await descriptor.instantiateCodec();
      try {
        final frame = await gridCodec.getNextFrame();
        return frame.image;
      } finally {
        gridCodec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
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
    final accent =
        Color.lerp(
          Color(0xFF000000 | avatarAccent(clock.from)),
          Color(0xFF000000 | avatarAccent(pose)),
          smooth,
        ) ??
        Color(0xFF000000 | avatarAccent(pose));

    canvas.drawCircle(
      center,
      side / 2 + 8,
      Paint()
        ..color = const Color(0x551877F2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
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

    final thinking = _poseWeight(AvatarPose.thinking, smooth);
    if (thinking > 0.04) {
      final sweep = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = bezel.strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = accent.withValues(alpha: thinking);
      canvas.drawArc(
        bezelRect,
        (seconds * 0.7) % 1 * math.pi * 2,
        1.15,
        false,
        sweep,
      );
    }

    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: side / 2 - 1)),
    );
    canvas.translate(center.dx, center.dy);
    canvas.translate(motion.lean * cell, motion.bob * cell);
    final bounce = _bounceScale(clock.nudge);
    final blink = 1 - 0.045 * clock.shut.clamp(0.0, 1.0);
    final pop = 1 + 0.04 * math.sin(clock.flourish * math.pi);
    canvas.scale(
      motion.scale * bounce * pop,
      motion.scale * bounce * pop * blink,
    );
    canvas.translate(-side / 2, -side / 2);

    if (!model && image != null) {
      canvas.drawImageRect(
        image,
        const Rect.fromLTWH(0, 0, 64, 64),
        Rect.fromLTWH(0, 0, side, side),
        Paint()..filterQuality = FilterQuality.none,
      );
      if (side >= 3 * pixelGrid) {
        _grid(canvas, side, cell);
      }
    } else if (!model) {
      _mark(canvas, cell, accent);
    }

    final listening = _poseWeight(AvatarPose.listening, smooth);
    final speaking = _poseWeight(AvatarPose.speaking, smooth);
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

  double _poseWeight(AvatarPose target, double smooth) {
    final at = pose == target ? smooth : 0.0;
    final was = clock.from == target ? 1 - smooth : 0.0;
    return math.max(at, was);
  }

  void _grid(Canvas canvas, double side, double cell) {
    final paint = Paint()
      ..color = const Color(0x59000000)
      ..strokeWidth = 1;
    for (var i = 1; i < pixelGrid; i++) {
      final p = i * cell;
      canvas.drawLine(Offset(p, 0), Offset(p, side), paint);
      canvas.drawLine(Offset(0, p), Offset(side, p), paint);
    }
  }

  /// A plain tile used until Muse sends its own picture. Not the stock
  /// firmware character: a flat body, two eyes, and a mouth that follows
  /// the pose.
  void _mark(Canvas canvas, double cell, Color accent) {
    final body = Paint()..color = accent.withValues(alpha: 0.92);
    final face = Paint()..color = const Color(0xFF1A1430);
    const left = 22;
    const top = 16;
    const width = 20;
    const height = 30;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final corner = (x < 2 || x >= width - 2) && (y < 2 || y >= height - 2);
        if (corner) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (left + x) * cell,
            (top + y) * cell,
            cell + 0.2,
            cell + 0.2,
          ),
          body,
        );
      }
    }
    canvas.drawRect(
      Rect.fromLTWH(26 * cell, 22 * cell, 12 * cell, 14 * cell),
      face,
    );
    if (clock.shut < 0.65) {
      final eye = Paint()..color = const Color(0xFFF2EFFF);
      canvas.drawRect(
        Rect.fromLTWH(28 * cell, 26 * cell, 2 * cell, 2 * cell),
        eye,
      );
      canvas.drawRect(
        Rect.fromLTWH(34 * cell, 26 * cell, 2 * cell, 2 * cell),
        eye,
      );
    }
    final mouth = Paint()..color = const Color(0xFFF2EFFF);
    switch (pose) {
      case AvatarPose.listening:
        canvas.drawRect(
          Rect.fromLTWH(31 * cell, 33 * cell, 2 * cell, 2 * cell),
          mouth,
        );
      case AvatarPose.thinking:
        canvas.drawRect(
          Rect.fromLTWH(30 * cell, 34 * cell, 4 * cell, cell),
          mouth,
        );
      case AvatarPose.speaking:
        final open = 2 + (0.5 + 0.5 * math.sin(clock.seconds * 8));
        canvas.drawRect(
          Rect.fromLTWH(30 * cell, 33 * cell, 4 * cell, open * cell),
          mouth,
        );
      case AvatarPose.error:
        canvas.drawRect(
          Rect.fromLTWH(29 * cell, 34 * cell, 6 * cell, cell),
          mouth,
        );
      case AvatarPose.idle:
        canvas.drawRect(
          Rect.fromLTWH(30 * cell, 34 * cell, 4 * cell, cell),
          mouth,
        );
    }
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
      final fade = (1 - phase) * 0.75 * strength;
      final paint = Paint()
        ..color = color.withValues(alpha: fade.clamp(0.0, 0.9));
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
