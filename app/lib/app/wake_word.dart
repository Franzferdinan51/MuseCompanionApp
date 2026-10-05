// Wake word detection via openWakeWord (https://github.com/dscripka/openWakeWord).
//
// Fully open-source (Apache 2.0), fully on-device, zero accounts, zero API
// keys, zero cloud. Three tiny TFLite models run the inference pipeline:
//
//   1. melspectrogram.tflite — raw 16kHz PCM -> mel-scale spectrogram frames
//   2. embedding_model.tflite — 76-frame spectrogram windows -> 96-dim speech
//      embeddings (shared backbone, frozen)
//   3. hey_jarvis_v0.1.tflite — last 16 embeddings -> wake-word score 0..1
//
// The pipeline mirrors openWakeWord's Python streaming implementation:
// audio accumulates in 1280-sample (80ms) chunks; each chunk flows through
// melspec -> embedding -> classifier; scores above threshold fire detection.
//
// Bundled model: "hey_jarvis" (closest openWakeWord pre-trained model to a
// "hey X" pattern; openWakeWord has NO "hey muse" model as of 2026-10-04).
// Duckets wants "Hey Muse" — the UI labels this honestly as a stand-in until
// a custom model is trained. To train a true "hey muse" model, see
// https://github.com/dscripka/openWakeWord#training-new-models — it's all
// local Python, no account needed.
//
// Battery: three small TFLite interpreters on 16kHz mono PCM, ~12 inference
// passes/sec, no cloud, no streaming, no full speech recognition. Detection
// pauses when the app is backgrounded, the screen sleeps, or a voice note
// records (mic can't be shared) — so drain is bounded by active
// companion-screen time.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Display label for the bundled keyword. Honest: this is what the model
/// actually listens for.
/// Display label. Honest: the bundled model listens for "Hey Jarvis";
/// a true "Hey Muse" model needs training (see README). Duckets' call.
const wakeWordLabel = 'Hey Jarvis';

/// Full UI label with the pending-model note.
const wakeWordUiLabel = 'Hey Jarvis (Hey Muse model pending)';

/// Asset paths for the three openWakeWord TFLite models.
const _melspecAsset = 'assets/wake_word/melspectrogram.tflite';
const _embeddingAsset = 'assets/wake_word/embedding_model.tflite';
const _classifierAsset = 'assets/wake_word/hey_jarvis_v0.1.tflite';

/// openWakeWord constants.
const _frameSamples = 1280; // 80ms at 16kHz
const _melspecOverlap = 480; // extra samples for streaming continuity
const _melspecBins = 32;
const _embeddingWindow = 76; // spectrogram frames per embedding
const _embeddingStep = 8; // frame step between embedding windows
const _embeddingDim = 96;
const _featureHistory = 120; // embeddings kept (~10s)
const _classifierFrames = 16; // embeddings fed to the classifier
const _warmupFrames = 5; // first N scores are zeroed (buffer warmup)

/// Why detection isn't running, for the Settings status line.
enum WakeWordStatus {
  off,
  noPermission,
  loading,
  error,
  listening,
  paused,
}

/// openWakeWord streaming inference engine.
///
/// Runs the three-model pipeline (melspec -> embedding -> classifier) on
/// 16kHz int16 PCM, maintaining the rolling buffers exactly like the
/// Python reference implementation.
class OpenWakeWordEngine {
  Interpreter? _melspec;
  Interpreter? _embedding;
  Interpreter? _classifier;

  // Rolling buffers.
  final List<int> _rawBuffer = <int>[]; // int16 samples
  final List<List<double>> _melspecBuffer = <List<double>>[]; // frames x 32
  final List<List<double>> _featureBuffer = <List<double>>[]; // embeddings
  final List<int> _remainder = <int>[];
  int _framesProcessed = 0;

  bool get isLoaded =>
      _melspec != null && _embedding != null && _classifier != null;

  Future<void> load() async {
    if (isLoaded) return;
    _melspec = await Interpreter.fromAsset(_melspecAsset);
    _embedding = await Interpreter.fromAsset(_embeddingAsset);
    _classifier = await Interpreter.fromAsset(_classifierAsset);
    // Melspec takes variable-length input; fix it to our chunk size once.
    _melspec!.resizeInputTensor(0, [1, _frameSamples + _melspecOverlap]);
    _melspec!.allocateTensors();
  }

  void reset() {
    _rawBuffer.clear();
    _melspecBuffer.clear();
    _featureBuffer.clear();
    _remainder.clear();
    _framesProcessed = 0;
  }

  void close() {
    _melspec?.close();
    _embedding?.close();
    _classifier?.close();
    _melspec = null;
    _embedding = null;
    _classifier = null;
    reset();
  }

  /// Feed 16kHz int16 PCM samples. Returns the wake-word score (0..1) when a
  /// full 80ms frame was processed, or null when still accumulating.
  double? process(List<int> samples) {
    if (!isLoaded) return null;
    // Append, keeping any remainder from last time.
    final input = <int>[..._remainder, ...samples];
    _remainder.clear();

    double? lastScore;
    var offset = 0;
    while (offset + _frameSamples <= input.length) {
      final chunk = input.sublist(offset, offset + _frameSamples);
      offset += _frameSamples;
      lastScore = _processChunk(chunk);
    }
    // Stash the leftover partial frame.
    if (offset < input.length) {
      _remainder.addAll(input.sublist(offset));
    }
    return lastScore;
  }

  /// Process one 1280-sample chunk through the full pipeline.
  double _processChunk(List<int> chunk) {
    _rawBuffer.addAll(chunk);

    // 1. Melspectrogram on the new audio (+ overlap for continuity).
    final windowStart =
        (_rawBuffer.length - _frameSamples - _melspecOverlap).clamp(0, _rawBuffer.length);
    final window = _rawBuffer.sublist(windowStart);
    // Pad to fixed size if we're still warming up.
    final padded = List<double>.filled(
        _frameSamples + _melspecOverlap, 0.0);
    for (var i = 0; i < window.length && i < padded.length; i++) {
      padded[i] = window[i].toDouble();
    }
    final melspecOut = _runMelspec(padded);
    // Transform to match Google's speech_embedding expectations.
    for (final frame in melspecOut) {
      for (var i = 0; i < frame.length; i++) {
        frame[i] = frame[i] / 10.0 + 2.0;
      }
      _melspecBuffer.add(frame);
    }
    // Bound the melspec buffer (~10s of frames: 97 frames/sec).
    while (_melspecBuffer.length > 970) {
      _melspecBuffer.removeAt(0);
    }

    // 2. Embeddings: 76-frame windows, step 8, from the newest frames.
    // Each 80ms chunk adds ~8 new melspec frames; take windows ending at
    // the newest frame, stepping back.
    final newFrames = melspecOut.length;
    for (var s = 0; s < newFrames; s += _embeddingStep) {
      final end = _melspecBuffer.length - s;
      final start = end - _embeddingWindow;
      if (start < 0) continue;
      final win = _melspecBuffer.sublist(start, end);
      final emb = _runEmbedding(win);
      _featureBuffer.add(emb);
    }
    while (_featureBuffer.length > _featureHistory) {
      _featureBuffer.removeAt(0);
    }

    // 3. Classifier on the last 16 embeddings.
    _framesProcessed++;
    if (_framesProcessed <= _warmupFrames) return 0.0;
    if (_featureBuffer.length < _classifierFrames) return 0.0;
    final feats =
        _featureBuffer.sublist(_featureBuffer.length - _classifierFrames);
    return _runClassifier(feats);
  }

  /// Melspec: [1, 1760] float32 -> [frames, 32] float32.
  List<List<double>> _runMelspec(List<double> samples) {
    final input = [samples]; // [1, 1760]
    final outTensor = _melspec!.getOutputTensor(0);
    final frames = outTensor.shape[1]; // e.g. 8 for 1760 samples
    final out = List.generate(
        1, (_) => List.generate(frames, (_) => List<double>.filled(_melspecBins, 0.0)));
    _melspec!.run(input, out);
    return out[0];
  }

  /// Embedding: [1, 76, 32, 1] float32 -> 96-dim vector.
  List<double> _runEmbedding(List<List<double>> window) {
    // Build [1, 76, 32, 1].
    final input = [
      [
        for (final frame in window)
          [for (final v in frame) [v]]
      ]
    ];
    final out = List.generate(1, (_) => List<double>.filled(_embeddingDim, 0.0));
    _embedding!.run(input, out);
    return out[0];
  }

  /// Classifier: [1, 16, 96] float32 -> score 0..1.
  double _runClassifier(List<List<double>> features) {
    final input = [features]; // [1, 16, 96]
    final out = [
      [0.0]
    ];
    _classifier!.run(input, out);
    return out[0][0].clamp(0.0, 1.0);
  }
}

/// Wake word service: audio capture + openWakeWord inference + lifecycle.
///
/// Audio comes from the native side over an EventChannel (16kHz int16 PCM,
/// 1280-sample frames). Inference runs in Dart via tflite_flutter. The
/// service exposes: [sync], [pause], [resume], [stop], [dispose], [status].
class WakeWordService {
  WakeWordService({required this.onDetected});

  /// Called (not awaited) on the UI thread when the keyword is heard.
  final Future<void> Function() onDetected;

  static const _audioChannel =
      EventChannel('dev.musecompanion.muse_companion/wake_word_audio');

  final OpenWakeWordEngine _engine = OpenWakeWordEngine();
  StreamSubscription<Uint8List>? _audioSub;

  WakeWordStatus _status = WakeWordStatus.off;
  String _statusDetail = '';
  bool _wanted = false;
  double _threshold = 0.5;
  DateTime? _lastDetection;
  bool _engineReady = false;

  WakeWordStatus get status => _status;
  String get statusDetail => _statusDetail;
  bool get isListening => _status == WakeWordStatus.listening;

  /// Called whenever [status] changes so UI can refresh.
  void Function()? onStatusChanged;

  /// Sensitivity 0..1 -> detection threshold. openWakeWord's default is
  /// 0.5; we map the slider so 50% == 0.5, higher sensitivity == lower
  /// threshold (catches more, false-alarms more).
  static double thresholdFor(double sensitivity) {
    final s = sensitivity.clamp(0.0, 1.0);
    return (0.8 - s * 0.6).clamp(0.1, 0.9);
  }

  /// Reconcile with the current settings. Idempotent.
  Future<void> sync({
    required bool enabled,
    required double sensitivity,
  }) async {
    _wanted = enabled;
    _threshold = thresholdFor(sensitivity);
    if (!enabled) {
      await stop();
      _set(WakeWordStatus.off, '');
      return;
    }
    if (!await Permission.microphone.isGranted) {
      await stop();
      _set(WakeWordStatus.noPermission,
          'Microphone permission is required for wake word detection.');
      return;
    }
    if (_status == WakeWordStatus.paused) {
      await resume();
      return;
    }
    if (_status == WakeWordStatus.listening) return;
    await _start();
  }

  Future<void> _start() async {
    _set(WakeWordStatus.loading, 'Loading wake word models…');
    try {
      if (!_engineReady) {
        await _engine.load();
        _engineReady = true;
      }
      _engine.reset();
      await _audioSub?.cancel();
      _audioSub = _audioChannel
          .receiveBroadcastStream()
          .cast<Uint8List>()
          .listen(_onAudio, onError: (_) {
        _set(WakeWordStatus.error, 'Audio stream error.');
      });
      _set(WakeWordStatus.listening, '');
    } catch (e) {
      _set(WakeWordStatus.error, 'Could not start wake word: $e');
    }
  }

  void _onAudio(Uint8List bytes) {
    if (_status != WakeWordStatus.listening) return;
    // Bytes are little-endian int16.
    final n = bytes.length ~/ 2;
    final samples = List<int>.filled(n, 0);
    final bd = bytes.buffer.asByteData(bytes.offsetInBytes);
    for (var i = 0; i < n; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little);
    }
    final score = _engine.process(samples);
    if (score == null) return;
    if (score >= _threshold) {
      // Debounce: ignore repeat detections within 2s.
      final now = DateTime.now();
      if (_lastDetection != null &&
          now.difference(_lastDetection!) < const Duration(seconds: 2)) {
        return;
      }
      _lastDetection = now;
      unawaited(onDetected());
    }
  }

  /// Pause capture — the mic can't be shared with voice-note recording,
  /// and there's no point burning battery when the app isn't visible.
  /// Keeps the engine loaded so [resume] is cheap.
  Future<void> pause() async {
    if (_status != WakeWordStatus.listening) return;
    await _audioSub?.cancel();
    _audioSub = null;
    _set(WakeWordStatus.paused, 'Paused (app hidden or recording).');
  }

  /// Resume capture after [pause].
  Future<void> resume() async {
    if (!_wanted) return;
    if (_status != WakeWordStatus.paused) return;
    _engine.reset(); // fresh buffers; stale audio would false-trigger
    _audioSub = _audioChannel
        .receiveBroadcastStream()
        .cast<Uint8List>()
        .listen(_onAudio, onError: (_) {
      _set(WakeWordStatus.error, 'Audio stream error.');
    });
    _set(WakeWordStatus.listening, '');
  }

  /// Full teardown.
  Future<void> stop() async {
    await _audioSub?.cancel();
    _audioSub = null;
    _wanted = false;
  }

  Future<void> dispose() async {
    await stop();
    onStatusChanged = null;
    _engine.close();
    _engineReady = false;
    _set(WakeWordStatus.off, '');
  }

  void _set(WakeWordStatus s, String detail) {
    _status = s;
    _statusDetail = detail;
    onStatusChanged?.call();
  }
}
