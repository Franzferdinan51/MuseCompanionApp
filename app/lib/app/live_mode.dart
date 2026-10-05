// Live (hands-free) conversation mode: the closest thing to Jarvis.
//
// The loop is a small state machine:
//
//   LISTEN (mic open) -> 2s of silence -> FINALIZE (mic stopped, voice
//   note sent) -> THINK (agent working) -> SPEAK (TTS reply, mic provably
//   closed) -> LISTEN ...
//
// The mic is never open while the agent thinks or speaks, so the session
// can never hear itself. The session auto-ends after 5 minutes without
// speech; the STOP button is always visible.
//
// Loop design adapted from hermes-mobile-app
// (https://github.com/omarqaterge/hermes-mobile-app, MIT, Copyright 2026
// Omar Qaterge): their `web/src/live.ts` runs listen -> pause -> send ->
// wait -> speak -> listen with the mic muted while thinking/speaking and a
// 5-minute idle auto-end; their `android/.../Voice.java` holds the native
// half. This port keeps the loop shape but reuses this app's existing
// pieces instead of reimplementing them: the mic via
// PhoneBridge.start/stopRecording, speech recognition via the normal
// voice-note send path (the Muse transcribes the WAV and reports what it
// heard), and speech via PhoneBridge.speak with its master killswitch.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/gadget/chat_events.dart';
import '../src/gadget/phone_actions.dart';
import '../src/gadget/service.dart';
import 'activity_log.dart';
import 'approval_service.dart';
import 'captions.dart';
import 'chat.dart';
import 'phone_bridge.dart';

/// Phases of one live session. Mirrors the hermes-mobile-app live.ts
/// phases (off/listening/thinking/speaking) plus the states this port
/// needs: [starting] (mic permission), [finalizing] (stop + send in
/// flight), [paused] (interrupted, resumable) and [ended] (terminal).
enum LivePhase {
  /// Never started, or reset.
  idle,

  /// Opening the mic (the permission prompt may be showing).
  starting,

  /// Mic open, watching the amplitude for speech.
  listening,

  /// Silence detected: the mic is being stopped and the note sent.
  finalizing,

  /// Voice note sent; waiting for the agent's reply.
  thinking,

  /// TTS is playing the reply. The mic is provably closed.
  speaking,

  /// Interrupted (app backgrounded, approval arrived, send failed).
  /// Mic and TTS are stopped; the user can resume.
  paused,

  /// Terminal: stopped by the user, timed out, or failed.
  ended,
}

/// Orchestrates one hands-free live conversation.
///
/// Reuses the app's existing voice pieces — [PhoneBridge] for the mic and
/// TTS, the normal voice-note send path ([ChatHistory.addSending] +
/// [GadgetService.sendChat]) for transcription, and the agent's reply
/// callbacks — instead of reimplementing any of them. Only one session
/// may run at a time; see [active].
class LiveModeController extends ChangeNotifier {
  LiveModeController({
    required this.phone,
    required this.chat,
    required this.service,
  });

  final PhoneBridge phone;
  final ChatHistory chat;
  final GadgetService service;

  /// The currently running live session, if any. `main.dart` routes
  /// `chat.onAssistantDone` here so a live turn's reply is spoken by the
  /// session (then the mic re-opens) instead of going through the normal
  /// reply path, which would double-speak.
  static LiveModeController? active;

  /// Seconds of silence after the last detected speech before the
  /// utterance is finalized and sent. (live.ts: 2s.)
  static const pauseSilence = Duration(seconds: 2);

  /// Give up waiting for a reply after this long and listen again.
  /// (live.ts: 10 minutes.)
  static const thinkTimeout = Duration(minutes: 10);

  /// End the session after this long in LISTEN with no speech at all.
  /// (live.ts: 5 minutes.)
  static const idleTimeout = Duration(minutes: 5);

  /// Cap a single utterance; a very long monologue is sent as-is.
  static const maxUtterance = Duration(seconds: 60);

  /// RMS mic amplitude (0..1) at or above this counts as speech. The
  /// native side reports RMS over a ~400ms window. Tune on a real device:
  /// too low hears room noise, too high clips quiet speech.
  static const speechThreshold = 0.06;

  /// How often the mic amplitude is sampled while listening.
  static const _ampPollInterval = Duration(milliseconds: 100);

  /// Utterances shorter than ~0.5s of 16kHz 16-bit PCM are blips, not
  /// speech; they are dropped instead of burning a turn.
  static const _minUtteranceBytes = 44 + 16000;

  LivePhase _phase = LivePhase.idle;
  LivePhase get phase => _phase;

  /// Latest RMS mic amplitude (0..1) while listening; 0 otherwise.
  /// Drives the live screen's mic indicator.
  final ValueNotifier<double> amplitude = ValueNotifier<double>(0);

  /// Time since the session started. Ticks once a second.
  final ValueNotifier<Duration> elapsed =
      ValueNotifier<Duration>(Duration.zero);

  /// Completed listen -> reply exchanges this session.
  int turns = 0;

  /// Why the session paused; shown on the paused card.
  String? pauseReason;

  /// Why the session ended; shown on the end card.
  String? endMessage;

  Timer? _ampTimer;
  Timer? _thinkTimer;
  Timer? _elapsedTimer;
  StreamSubscription<ApprovalRequest>? _approvalSub;
  DateTime? _startedAt;
  int _firstMessageIndex = 0;
  DateTime _listenStartedAt = DateTime.now();
  DateTime _silenceSince = DateTime.now();
  DateTime _lastSpeechAt = DateTime.now();
  bool _utteranceHadSpeech = false;
  bool _tickBusy = false;
  bool _disposed = false;

  bool get _isOurs => active == this && !_disposed;

  bool get _isLivePhase =>
      _phase == LivePhase.listening ||
      _phase == LivePhase.finalizing ||
      _phase == LivePhase.thinking ||
      _phase == LivePhase.speaking;

  /// Messages added since the session started: the live transcript.
  List<ChatMessage> sessionMessages() {
    final messages = chat.messages;
    final start = _firstMessageIndex.clamp(0, messages.length);
    return messages.sublist(start);
  }

  /// Start the session. Opens the mic and enters the loop. A denied mic
  /// permission ends the session with a message instead of throwing.
  Future<void> start() async {
    if (active != null || _disposed) return;
    active = this;
    _startedAt = DateTime.now();
    _firstMessageIndex = chat.messages.length;
    elapsed.value = Duration.zero;
    _setPhase(LivePhase.starting);
    // An approval dialog would open *under* the live screen, invisible to
    // the user. End the session instead so the request can be answered.
    _approvalSub = ApprovalService.instance.requests.listen((_) {
      if (active == this && _isLivePhase) {
        _shutdown(
          message: 'Stopped: an approval needs your answer '
              '(it is waiting on the chat screen).',
        );
      }
    });
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || _startedAt == null) return;
      elapsed.value = DateTime.now().difference(_startedAt!);
    });
    try {
      await phone.startRecording();
    } on PhoneActionException catch (e) {
      await _shutdown(message: 'Microphone unavailable: ${e.message}');
      return;
    } catch (e) {
      await _shutdown(message: 'Microphone error: $e');
      return;
    }
    if (!_isOurs || _phase == LivePhase.paused) return;
    await _beginListen();
  }

  /// Re-open the mic and go back to listening.
  Future<void> _beginListen() async {
    if (!_isOurs) return;
    // Echo avoidance, belt and suspenders: never open the mic while TTS
    // still claims the speaker (e.g. a barge-in raced the loop).
    for (var i = 0; i < 20 && PhoneBridge.speaking.value; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!_isOurs || _phase == LivePhase.paused) return;
    if (PhoneBridge.speaking.value) {
      await _shutdown(message: 'The speaker stayed busy — live mode stopped.');
      return;
    }
    _utteranceHadSpeech = false;
    final now = DateTime.now();
    _listenStartedAt = now;
    _silenceSince = now;
    _lastSpeechAt = now;
    try {
      await phone.startRecording();
    } on PhoneActionException catch (e) {
      await _shutdown(message: 'Microphone error: ${e.message}');
      return;
    } catch (e) {
      await _shutdown(message: 'Microphone error: $e');
      return;
    }
    if (!_isOurs || _phase == LivePhase.paused) return;
    _ampTimer?.cancel();
    _ampTimer = Timer.periodic(_ampPollInterval, (_) => _onAmpTick());
    _setPhase(LivePhase.listening);
  }

  /// One amplitude sample while listening: update the indicator, track
  /// speech vs silence, and drive the pause/idle/utterance-cap timers.
  void _onAmpTick() async {
    if (!_isOurs || _phase != LivePhase.listening || _tickBusy) return;
    _tickBusy = true;
    try {
      // Defense in depth: never sample while TTS claims the speaker.
      if (PhoneBridge.speaking.value) return;
      final amp = await phone.recordingAmplitude();
      if (!_isOurs || _phase != LivePhase.listening) return;
      amplitude.value = amp;
      final now = DateTime.now();
      if (amp >= speechThreshold) {
        _utteranceHadSpeech = true;
        _lastSpeechAt = now;
        _silenceSince = now;
        return;
      }
      if (_utteranceHadSpeech &&
          now.difference(_silenceSince) >= pauseSilence) {
        await _finalizeUtterance();
        return;
      }
      if (now.difference(_listenStartedAt) >= maxUtterance) {
        await _finalizeUtterance();
        return;
      }
      if (now.difference(_lastSpeechAt) >= idleTimeout) {
        await _shutdown(message: 'No speech for 5 minutes — live mode ended.');
      }
    } finally {
      _tickBusy = false;
    }
  }

  /// 2s of silence (or the utterance cap): close the mic and send what
  /// was captured through the normal voice-note path. The Muse
  /// transcribes the WAV and its reply completes the turn.
  Future<void> _finalizeUtterance() async {
    if (!_isOurs || _phase != LivePhase.listening) return;
    _ampTimer?.cancel();
    _ampTimer = null;
    amplitude.value = 0;
    _setPhase(LivePhase.finalizing);
    final Uint8List wav;
    try {
      wav = await phone.stopRecording();
    } on PhoneActionException {
      // Nothing captured ("didn't catch that") — keep listening.
      if (_isOurs && _phase != LivePhase.paused) await _beginListen();
      return;
    } catch (_) {
      if (_isOurs && _phase != LivePhase.paused) await _beginListen();
      return;
    }
    if (!_isOurs || _phase == LivePhase.paused) return;
    if (!_utteranceHadSpeech || wav.length < _minUtteranceBytes) {
      await _beginListen(); // blip, not speech — don't waste a turn
      return;
    }
    await _sendVoiceNote(wav);
  }

  /// Post the utterance exactly like a hold-to-talk voice note, so
  /// transcription, streaming, and reply handling are identical.
  Future<void> _sendVoiceNote(Uint8List wav) async {
    final id = chat.addSending(
      'Voice note',
      attachmentBytes: wav,
      attachmentMime: 'audio/wav',
      attachmentName: 'voice_note.wav',
    );
    _setPhase(LivePhase.thinking);
    _thinkTimer?.cancel();
    _thinkTimer = Timer(thinkTimeout, () {
      // The reply never came (link died mid-turn?): listen again rather
      // than stall forever. Matches live.ts's think cap.
      if (_isOurs && _phase == LivePhase.thinking) {
        unawaited(_beginListen());
      }
    });
    try {
      final result = await service.sendChat('', null, <ChatAttachment>[
        ChatAttachment(
          mimeType: 'audio/wav',
          filename: 'voice_note.wav',
          bytes: wav,
        ),
      ]);
      if (result['ok'] == true) {
        chat.markSent(id);
        ActivityLog.instance.add(ActivityKind.voice, 'Live turn sent');
        return;
      }
      final error = result['error'];
      final msg = error is String && error.isNotEmpty ? error : 'send failed';
      chat.markFailed(id, msg);
      ActivityLog.instance.add(
        ActivityKind.voice,
        'Live turn failed',
        detail: msg,
        ok: false,
      );
    } catch (e) {
      chat.markFailed(id, '$e');
      ActivityLog.instance.add(
        ActivityKind.voice,
        'Live turn failed',
        detail: '$e',
        ok: false,
      );
    }
    // Don't auto-loop into a dead link: pause and let the user resume.
    if (_isOurs) pause('Send failed — check the link, then resume.');
  }

  /// Hand a finished agent reply to the session. Called from main.dart's
  /// `chat.onAssistantDone`. Returns true when the session consumed the
  /// reply (it was waiting for one); false when the normal reply path
  /// should handle it instead.
  bool deliverReply(String text) {
    if (!_isOurs || _phase != LivePhase.thinking) return false;
    _thinkTimer?.cancel();
    _thinkTimer = null;
    turns++;
    unawaited(_speakThenListen(text));
    return true;
  }

  /// Speak the reply (the mic was closed in [_finalizeUtterance] before
  /// the note was sent, so TTS can never feed back), then listen again.
  /// Honors the master TTS killswitch: with speech off, the reply shows
  /// as text and the loop continues silently.
  Future<void> _speakThenListen(String text) async {
    if (!_isOurs || _phase == LivePhase.paused) return;
    _setPhase(LivePhase.speaking);
    final spoken = speakableReply(text);
    if (PhoneBridge.speakEnabled && spoken.isNotEmpty) {
      try {
        await phone.speak(spoken);
      } catch (_) {
        // TTS failed; the reply text is already on screen. Keep going.
      }
    }
    if (!_isOurs || _phase == LivePhase.paused) return;
    await _beginListen();
  }

  /// Pause the session without ending it: the mic closes, TTS stops, and
  /// the screen offers Resume. Used for app backgrounding and send
  /// failures. Never throws.
  void pause(String reason) {
    if (!_isOurs) return;
    if (_phase != LivePhase.starting && !_isLivePhase) return;
    pauseReason = reason;
    _ampTimer?.cancel();
    _ampTimer = null;
    _thinkTimer?.cancel();
    _thinkTimer = null;
    if (!_disposed) amplitude.value = 0;
    unawaited(_quietMic());
    unawaited(_stopTtsQuiet());
    _setPhase(LivePhase.paused);
  }

  /// Resume a paused session: re-open the mic and listen again.
  Future<void> resume() async {
    if (!_isOurs || _phase != LivePhase.paused) return;
    pauseReason = null;
    await _beginListen();
  }

  /// End the session: stop timers, close the mic, stop TTS, release
  /// [active]. Never throws.
  Future<void> _shutdown({String? message}) async {
    if (active == this) active = null;
    endMessage = message;
    _cancelTimers();
    final sub = _approvalSub;
    _approvalSub = null;
    try {
      await sub?.cancel();
    } catch (_) {
      // Best effort only.
    }
    if (!_disposed) amplitude.value = 0;
    await _quietMic();
    await _stopTtsQuiet();
    if (!_disposed) _setPhase(LivePhase.ended);
  }

  /// Manual stop. The screen shows the end card; closing pops the route.
  Future<void> stop() => _shutdown();

  /// Close the mic if it is open. Never throws.
  Future<void> _quietMic() async {
    _ampTimer?.cancel();
    _ampTimer = null;
    if (!_disposed) amplitude.value = 0;
    try {
      await phone.stopRecording();
    } on PhoneActionException {
      // Already stopped, or nothing was captured.
    } catch (_) {
      // Best effort only.
    }
  }

  Future<void> _stopTtsQuiet() async {
    try {
      await phone.stopSpeak();
    } catch (_) {
      // Best effort only.
    }
  }

  void _cancelTimers() {
    _ampTimer?.cancel();
    _ampTimer = null;
    _thinkTimer?.cancel();
    _thinkTimer = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  void _setPhase(LivePhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_shutdown());
    super.dispose();
  }
}
