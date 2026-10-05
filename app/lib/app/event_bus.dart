// Ported concept from hermes-mobile-app (MIT, Omar Qaterge):
// their plugin's `_send()` event kinds (status, reply, approval, error,
// ...) decoupling the agent from the UI. Our port is an in-process Dart
// Stream-based event bus: agent internals emit, the Activity tab,
// notification system, and status line subscribe instead of being
// tightly coupled.
//
// Emission is fire-and-forget: never let a broken listener break the
// agent execution path.

import 'dart:async';

import 'activity_log.dart';

/// Kinds of agent events, mirroring the reference plugin's `_send()` kinds.
enum AppEventKind {
  /// Agent working-state changed (text is human-readable, see payload).
  status,

  /// The agent produced a reply for the user.
  reply,

  /// An approval request was raised to the user.
  approvalRequest,

  /// An approval request was answered (or timed out).
  approvalResponse,

  /// A tool call started.
  toolCall,

  /// A tool call finished.
  toolResult,

  /// Something failed (agent error, tool error, etc.).
  error,

  /// The agent wrote to long-term memory.
  memoryWrite,
}

/// One event on the bus.
class AppEvent {
  const AppEvent({
    required this.kind,
    required this.at,
    this.payload = const {},
  });

  final AppEventKind kind;
  final DateTime at;

  /// Free-form payload. Conventions per kind:
  /// - status: {'text': String, 'working': bool}
  /// - reply: {'text': String}
  /// - approvalRequest: {'id': String, 'title': String}
  /// - approvalResponse: {'id': String, 'approved': bool, 'timedOut': bool}
  /// - toolCall: {'tool': String, 'label': String, 'args': String}
  /// - toolResult: {'tool': String, 'label': String, 'ok': bool}
  /// - error: {'message': String}
  /// - memoryWrite: {'summary': String}
  final Map<String, Object?> payload;
}

/// Process-wide typed event bus. Subscribe via [stream]; emit via [emit].
class EventBus {
  EventBus._() {
    // Feed agent events into the existing Activity tab log, decoupled:
    // the log subscribes here instead of agent code calling it directly.
    stream.listen(_bridgeToActivityLog);
  }

  static final EventBus instance = EventBus._();

  final StreamController<AppEvent> _controller =
      StreamController<AppEvent>.broadcast();

  /// Subscribe to all events. Broadcast: any number of listeners.
  Stream<AppEvent> get stream => _controller.stream;

  /// Fire-and-forget emit. Never throws, never blocks the agent path.
  void emit(AppEventKind kind, {Map<String, Object?> payload = const {}}) {
    try {
      if (!_controller.isClosed) {
        _controller.add(
          AppEvent(kind: kind, at: DateTime.now(), payload: payload),
        );
      }
    } catch (_) {
      // A dead listener must never break the agent.
    }
  }

  /// Bridge: mirror agent-relevant events into the Activity tab log.
  /// Status events are intentionally NOT mirrored (they update at ~1Hz
  /// and would flood the bounded log); the status line subscribes to
  /// them separately via [AgentStatusBus].
  void _bridgeToActivityLog(AppEvent e) {
    try {
      switch (e.kind) {
        case AppEventKind.toolCall:
          ActivityLog.instance.add(
            ActivityKind.invoke,
            (e.payload['label'] ?? 'Tool call').toString(),
            detail: (e.payload['args'] ?? '').toString(),
          );
        case AppEventKind.toolResult:
          final ok = e.payload['ok'] != false;
          if (!ok) {
            ActivityLog.instance.add(
              ActivityKind.invoke,
              'Failed: ${(e.payload['label'] ?? 'tool').toString()}',
              detail: (e.payload['detail'] ?? '').toString(),
              ok: false,
            );
          }
        case AppEventKind.error:
          ActivityLog.instance.add(
            ActivityKind.system,
            'Agent error',
            detail: (e.payload['message'] ?? '').toString(),
            ok: false,
          );
        case AppEventKind.reply:
          ActivityLog.instance.add(
            ActivityKind.chat,
            'Local AI replied',
            detail: (e.payload['text'] ?? '').toString(),
          );
        case AppEventKind.approvalRequest:
          ActivityLog.instance.add(
            ActivityKind.system,
            'Approval requested: ${(e.payload['title'] ?? '').toString()}',
          );
        case AppEventKind.approvalResponse:
          final approved = e.payload['approved'] == true;
          ActivityLog.instance.add(
            ActivityKind.system,
            approved ? 'Approval granted' : 'Approval denied',
            ok: approved,
          );
        case AppEventKind.status:
        case AppEventKind.memoryWrite:
          break;
      }
    } catch (_) {
      // Logging must never break the agent path.
    }
  }
}
