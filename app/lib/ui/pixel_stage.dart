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

import '../app/avatar_life.dart';
import '../app/avatar_motion.dart';
import '../app/model.dart';
import '../app/pixel_avatar.dart';

class PixelStage extends StatefulWidget {
  const PixelStage({
    super.key,
    required this.pose,
    required this.bytes,
    this.bounceGeneration = 0,
    this.petGeneration = 0,
  });

  final AvatarPose pose;
  final Uint8List? bytes;

  /// Increment to play a tap bounce. Hold-to-talk owns the pointer.
  final int bounceGeneration;

  /// Increment to play the happy pet reaction. Ignored while in error.
  final int petGeneration;

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
  double modeT = 0;
  double happy = 0;
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
    required AvatarPose pose,
    required AvatarPose from,
    required double blend,
    required double flourish,
    required double nudge,
    required double modeT,
    required double happy,
    required AvatarLife life,
    required int hot,
    required int mid,
    required int deep,
    required int blendedAccent,
  }) {
    this.seconds = seconds;
    this.shut = shut;
    this.image = image;
    this.pose = pose;
    this.from = from;
    this.blend = blend;
    this.flourish = flourish;
    this.nudge = nudge;
    this.modeT = modeT;
    this.happy = happy;
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
    final image = frames == null
        ? null
        : frames.images[frames.indexAt(elapsed)];
    _publish(image, _blink.advance(dt), elapsed.inMicroseconds / 1000000);
  }

  void _publish(ui.Image? image, double shut, double seconds) {
    final level = avatarLevel(_shown, seconds);
    _clock.tick(
      seconds: seconds,
      shut: shut,
      image: image,
      pose: _shown,
      from: _from,
      blend: _blend,
      flourish: _flourish,
      nudge: _nudge,
      modeT: _modeT,
      happy: _happy,
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

/// Portrait sprite size in stage cells. The disc is 64 cells across and
/// stays still; this box is the body that bobs inside it.
const double _portraitCells = 46;

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

    final listening = _poseWeight(AvatarPose.listening, smooth);
    final speaking = _poseWeight(AvatarPose.speaking, smooth);

    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: side / 2 - 1)),
    );
    // Stage space. Rings, sparkles, and dots orbit this fixed disc.
    // Only the portrait below is translated, so the circle does not slide.
    canvas.translate(origin.dx, origin.dy);

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

    canvas.save();
    canvas.translate(side / 2, side / 2);
    final fromLean = clock.from == AvatarPose.error ? 0.0 : fromMotion.lean;
    final toLean = pose == AvatarPose.error ? life.lean : toMotion.lean;
    final lean = fromLean + (toLean - fromLean) * smooth + life.step;
    final gazeShift = image == null ? 0.0 : 1.0;
    canvas.translate(
      (lean + life.gazeX * gazeShift) * cell,
      (motion.bob - life.hop + life.gazeY * gazeShift) * cell,
    );
    canvas.rotate(life.sway);
    final bounce = _bounceScale(clock.nudge);
    final bodyBlink = image == null
        ? 1.0
        : 1 - 0.045 * clock.shut.clamp(0.0, 1.0);
    final pop = 1 + 0.04 * math.sin(clock.flourish * math.pi);
    final breathe = 1 + life.breathe;
    final wide = pose == AvatarPose.boot ? 1 + (1 - life.squash) * 0.45 : 1.0;
    canvas.scale(
      motion.scale * bounce * pop * breathe * wide,
      motion.scale * bounce * pop * breathe * life.squash * bodyBlink,
    );
    canvas.translate(-side / 2, -side / 2);

    if (!model && image != null) {
      final body = _portraitCells * cell;
      final rect = Rect.fromCenter(
        center: Offset(side / 2, side / 2),
        width: body,
        height: body,
      );
      canvas.drawImageRect(
        image,
        const Rect.fromLTWH(0, 0, 64, 64),
        rect,
        Paint()
          ..filterQuality = FilterQuality.none
          ..color = Color.fromRGBO(255, 255, 255, life.fade),
      );
      if (side >= 3 * pixelGrid) {
        _grid(canvas, rect, cell);
      }
    } else if (!model) {
      _face(canvas, side, cell, accent, life);
    }
    canvas.restore();

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

  double _poseWeight(AvatarPose target, double smooth) {
    final at = pose == target ? smooth : 0.0;
    final was = clock.from == target ? 1 - smooth : 0.0;
    return math.max(at, was);
  }

  void _grid(Canvas canvas, Rect rect, double cell) {
    final paint = Paint()
      ..color = const Color(0x59000000)
      ..strokeWidth = 1;
    for (var x = rect.left + cell; x < rect.right; x += cell) {
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
    }
    for (var y = rect.top + cell; y < rect.bottom; y += cell) {
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
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
