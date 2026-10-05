// User approval prompts for agent actions.
//
// Pattern (after the hermes-gadget-sdk `prompt` protocol): when the agent
// wants to do something consequential, the app asks the user a yes/no
// question first. The request carries a title and body; the UI shows them
// in a popup; the answer completes the returned future exactly once.
//
// Four-way choices ported from hermes-mobile-app (MIT, Omar Qaterge)
// (their RequestSheet.tsx CHOICE_LABEL: once / session / always / deny):
//   - Allow once: approves this single request.
//   - Allow this session: also allowlists the tool for the rest of this
//     app session (process lifetime); later requests for the same tool
//     auto-approve without prompting.
//   - Always allow: like session, plus persisted across restarts via an
//     [AlwaysAllowStore] (SharedPreferences).
//   - Deny: rejects the request.
//
// Properties borrowed from the reference:
// - One question at a time (requests queue).
// - Each request has a TTL; expiry auto-denies.
// - A request can be withdrawn with [closeRequest] (also denies).
// - Answers are debounced by the UI (see approval_prompt.dart).
// - Backgrounded app: requests also fire Android notifications with
//   inline actions (see approval_notifications.dart); answering from a
//   notification completes the same future.

import 'dart:async';
import 'event_bus.dart';

/// How the user answered an approval request.
enum ApprovalChoice {
  /// Reject this request.
  deny,

  /// Approve this request only.
  allowOnce,

  /// Approve this request and auto-approve this tool for the rest of the
  /// app session.
  allowSession,

  /// Approve this request and persist the decision: the tool auto-approves
  /// across restarts until revoked.
  alwaysAllow,
}

/// Human labels for the four choices (matches the reference wording).
extension ApprovalChoiceLabel on ApprovalChoice {
  String get label => switch (this) {
        ApprovalChoice.deny => 'Deny',
        ApprovalChoice.allowOnce => 'Allow once',
        ApprovalChoice.allowSession => 'Allow this session',
        ApprovalChoice.alwaysAllow => 'Always allow',
      };

  /// The bool the legacy yes/no API surface exposes.
  bool get approved => this != ApprovalChoice.deny;
}

/// A single pending approval question.
class ApprovalRequest {
  ApprovalRequest({
    required this.id,
    required this.title,
    required this.body,
    required this.timeout,
    this.toolName,
  });

  /// Unique id, e.g. "appr-3".
  final String id;

  /// Short question, e.g. 'Allow "set_alarm"?'.
  final String title;

  /// Human-readable detail: what the action does + its arguments.
  final String body;

  /// How long the UI has to answer before this auto-denies.
  final Duration timeout;

  /// The tool this request is about, e.g. "take_photo". Used for the
  /// session / always allowlists. Null for non-tool prompts (server
  /// `prompt` messages), which never auto-approve.
  final String? toolName;

  final Completer<ApprovalChoice> _completer = Completer<ApprovalChoice>();

  /// The future the requester awaits. Completes exactly once. True when the
  /// request was approved (any of the allow choices), false on deny,
  /// withdrawal, or timeout. Kept bool-typed so existing callers
  /// (phone tool approver, gadget link client) keep working unchanged.
  Future<bool> get future => _completer.future.then((c) => c.approved);

  bool get isCompleted => _completer.isCompleted;

  /// The recorded answer, if answered.
  ApprovalChoice? _answer;
  ApprovalChoice? get answer => _answer;

  void _complete(ApprovalChoice choice) {
    if (!_completer.isCompleted) {
      _answer = choice;
      _completer.complete(choice);
    }
  }
}

/// Sink for approval lifecycle events. Implemented by the notification
/// fallback (see app/approval_notifications.dart). Null by default: the
/// in-app dialog path works without it, so the approval flow is unchanged
/// when no sink is wired.
abstract class ApprovalNotificationSink {
  /// A request became the active question (after allowlist bypass checks).
  void onApprovalActivated(ApprovalRequest request);

  /// A request settled (answered, withdrawn, or timed out).
  void onApprovalSettled(ApprovalRequest request);
}

/// Persistent backing for "always allow" decisions. Implemented by
/// [SharedPrefsAlwaysAllowStore] in storage.dart; the interface keeps the
/// service unit-testable without plugins.
abstract class AlwaysAllowStore {
  /// Tool names the user chose "always allow" for.
  Set<String> loadAllowed();

  /// Record or revoke an "always allow" decision.
  Future<void> setAllowed(String toolName, bool allowed);
}

/// Matches titles of the form `Allow "<tool>"?` produced by the phone tool
/// adapter, so the tool name is known even when callers don't pass it
/// explicitly.
final RegExp _allowTitlePattern = RegExp(r'^Allow "([^"]+)"\?$');

/// Coordinates approval popups between agent code (no UI context) and the
/// Flutter UI. Agent code calls [requestApproval] and awaits the bool; a
/// listener widget (see ui/approval_prompt.dart) shows the popup, and the
/// notification fallback (see app/approval_notifications.dart) covers the
/// backgrounded case.
class ApprovalService {
  ApprovalService();

  /// App-wide instance used by production code.
  static final ApprovalService instance = ApprovalService();

  final StreamController<ApprovalRequest> _requests =
      StreamController<ApprovalRequest>.broadcast();

  /// Stream of questions for the UI listener. One at a time: the next
  /// request is only emitted after the current one completes. Requests
  /// auto-approved by the session/always allowlists are NOT emitted.
  Stream<ApprovalRequest> get requests => _requests.stream;

  final List<ApprovalRequest> _queue = <ApprovalRequest>[];
  ApprovalRequest? _active;
  int _nextId = 1;

  /// Session-scoped allowlist: tool names approved with "allow this
  /// session". Lives as long as the service (app process lifetime).
  final Set<String> _sessionAllowed = <String>{};

  /// Persisted "always allow" tool names, mirrored in memory.
  final Set<String> _alwaysAllowed = <String>{};
  AlwaysAllowStore? _allowanceStore;

  /// Optional notification fallback, wired at app startup.
  ApprovalNotificationSink? notificationSink;

  bool get hasPending => _active != null || _queue.isNotEmpty;

  /// The currently active request, if it hasn't been answered yet. Lets
  /// the UI show the in-app dialog when the app returns to the foreground
  /// while a notification-posted request is still pending.
  ApprovalRequest? get pendingRequest {
    final active = _active;
    return (active != null && !active.isCompleted) ? active : null;
  }

  /// ID of the most recently created request (active or queued).
  /// Lets link code map a server `prompt` id to our internal request id.
  String? get lastRequestId {
    if (_queue.isNotEmpty) return _queue.last.id;
    return _active?.id;
  }

  /// Wire the persistent "always allow" store. Preloads its contents into
  /// the in-memory allowlist so checks stay synchronous.
  set allowanceStore(AlwaysAllowStore? store) {
    _allowanceStore = store;
    final loaded = store?.loadAllowed();
    if (loaded != null) _alwaysAllowed.addAll(loaded);
  }

  /// True when [toolName] is covered by the session or always allowlist.
  bool isToolAllowed(String toolName) =>
      _sessionAllowed.contains(toolName) || _alwaysAllowed.contains(toolName);

  /// Tool names with a persisted "always allow" decision.
  Set<String> get alwaysAllowedTools => Set.unmodifiable(_alwaysAllowed);

  /// Drop all session-scoped allowances (e.g. on explicit user reset).
  void clearSessionAllowances() => _sessionAllowed.clear();

  /// Revoke a persisted "always allow" decision.
  Future<void> revokeAlwaysAllow(String toolName) async {
    _alwaysAllowed.remove(toolName);
    _sessionAllowed.remove(toolName);
    await _allowanceStore?.setAllowed(toolName, false);
  }

  /// Ask the user a question. Returns true when approved, false when
  /// denied, withdrawn, or timed out. When [toolName] (or the tool parsed
  /// from a matching title) is covered by the session/always allowlist,
  /// the future completes true immediately with no popup and no
  /// notification.
  Future<bool> requestApproval({
    required String title,
    required String body,
    Duration timeout = const Duration(seconds: 60),
    String? toolName,
  }) {
    final request = ApprovalRequest(
      id: 'appr-${_nextId++}',
      title: title,
      body: body,
      timeout: timeout,
      toolName: toolName ?? _allowTitlePattern.firstMatch(title)?.group(1),
    );
    if (_active == null) {
      _activate(request);
    } else {
      _queue.add(request);
    }
    return request.future;
  }

  /// Withdraw a pending request (denies it). Used when the question no
  /// longer applies, mirroring the reference's `prompt.close`.
  void closeRequest(String id) {
    final active = _active;
    if (active?.id == id) {
      active!._complete(ApprovalChoice.deny);
      notificationSink?.onApprovalSettled(active);
      EventBus.instance.emit(
        AppEventKind.approvalResponse,
        payload: {'id': id, 'approved': false, 'timedOut': false},
      );
      _advance();
      return;
    }
    final index = _queue.indexWhere((r) => r.id == id);
    if (index >= 0) {
      final removed = _queue.removeAt(index);
      removed._complete(ApprovalChoice.deny);
      notificationSink?.onApprovalSettled(removed);
      EventBus.instance.emit(
        AppEventKind.approvalResponse,
        payload: {'id': id, 'approved': false, 'timedOut': false},
      );
    }
  }

  /// Record the user's answer with a four-way choice. Completes the
  /// request exactly once and emits the next queued question, if any.
  /// "Allow this session" / "always allow" record the tool before the
  /// next request activates, so a queued request for the same tool
  /// auto-approves.
  void answerWithChoice(String id, ApprovalChoice choice) {
    final active = _active;
    if (active == null || active.id != id || active.isCompleted) return;
    _recordChoice(active, choice);
    active._complete(choice);
    notificationSink?.onApprovalSettled(active);
    EventBus.instance.emit(
      AppEventKind.approvalResponse,
      payload: {
        'id': id,
        'approved': choice != ApprovalChoice.deny,
        'choice': choice.name,
      },
    );
    _advance();
  }

  /// Legacy yes/no answer. Maps to allow-once / deny; kept so existing
  /// callers work unchanged.
  void answerRequest(String id, bool approved) {
    answerWithChoice(
      id,
      approved ? ApprovalChoice.allowOnce : ApprovalChoice.deny,
    );
  }

  void _recordChoice(ApprovalRequest request, ApprovalChoice choice) {
    final tool = request.toolName;
    switch (choice) {
      case ApprovalChoice.deny:
      case ApprovalChoice.allowOnce:
        break;
      case ApprovalChoice.allowSession:
        if (tool != null) _sessionAllowed.add(tool);
      case ApprovalChoice.alwaysAllow:
        if (tool != null) {
          _sessionAllowed.add(tool);
          _alwaysAllowed.add(tool);
          unawaited(_allowanceStore?.setAllowed(tool, true));
        }
    }
  }

  void _activate(ApprovalRequest request) {
    // Allowlist bypass: no popup, no notification, no stream emission.
    final tool = request.toolName;
    if (tool != null && isToolAllowed(tool)) {
      request._complete(ApprovalChoice.allowOnce);
      _advance();
      return;
    }
    _active = request;
    _requests.add(request);
    EventBus.instance.emit(
      AppEventKind.approvalRequest,
      payload: {'id': request.id, 'title': request.title},
    );
    notificationSink?.onApprovalActivated(request);
    // TTL expiry auto-denies, like the reference protocol.
    Future.delayed(request.timeout, () {
      if (!request.isCompleted) {
        request._complete(ApprovalChoice.deny);
        notificationSink?.onApprovalSettled(request);
        EventBus.instance.emit(
          AppEventKind.approvalResponse,
          payload: {'id': request.id, 'approved': false, 'timedOut': true},
        );
        if (_active?.id == request.id) _advance();
      }
    });
  }

  void _advance() {
    _active = null;
    if (_queue.isNotEmpty) {
      _activate(_queue.removeAt(0));
    }
  }

  /// Test helper: answer the currently active request.
  @pragma('vm:visible-for-testing')
  ApprovalRequest? get activeForTest => _active;
}