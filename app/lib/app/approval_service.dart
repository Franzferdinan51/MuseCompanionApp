// User approval prompts for agent actions.
//
// Pattern (after the hermes-gadget-sdk `prompt` protocol): when the agent
// wants to do something consequential, the app asks the user a yes/no
// question first. The request carries a title and body; the UI shows them
// in a popup; the answer completes the returned future exactly once.
//
// Properties borrowed from the reference:
// - One question at a time (requests queue).
// - Each request has a TTL; expiry auto-denies.
// - A request can be withdrawn with [closeRequest] (also denies).
// - Answers are debounced by the UI (see approval_prompt.dart).

import 'dart:async';

/// A single pending approval question.
class ApprovalRequest {
  ApprovalRequest({
    required this.id,
    required this.title,
    required this.body,
    required this.timeout,
  });

  /// Unique id, e.g. "appr-3".
  final String id;

  /// Short question, e.g. 'Allow "set_alarm"?'.
  final String title;

  /// Human-readable detail: what the action does + its arguments.
  final String body;

  /// How long the UI has to answer before this auto-denies.
  final Duration timeout;

  final Completer<bool> _completer = Completer<bool>();

  /// The future the requester awaits. Completes exactly once.
  Future<bool> get future => _completer.future;

  bool get isCompleted => _completer.isCompleted;

  void _complete(bool approved) {
    if (!_completer.isCompleted) _completer.complete(approved);
  }
}

/// Coordinates approval popups between agent code (no UI context) and the
/// Flutter UI. Agent code calls [requestApproval] and awaits the bool; a
/// listener widget (see ui/approval_prompt.dart) shows the popup.
class ApprovalService {
  ApprovalService();

  /// App-wide instance used by production code.
  static final ApprovalService instance = ApprovalService();

  final StreamController<ApprovalRequest> _requests =
      StreamController<ApprovalRequest>.broadcast();

  /// Stream of questions for the UI listener. One at a time: the next
  /// request is only emitted after the current one completes.
  Stream<ApprovalRequest> get requests => _requests.stream;

  final List<ApprovalRequest> _queue = <ApprovalRequest>[];
  ApprovalRequest? _active;
  int _nextId = 1;

  bool get hasPending => _active != null || _queue.isNotEmpty;

  /// Ask the user a yes/no question. Returns true when approved, false
  /// when denied, withdrawn, or timed out.
  Future<bool> requestApproval({
    required String title,
    required String body,
    Duration timeout = const Duration(seconds: 60),
  }) {
    final request = ApprovalRequest(
      id: 'appr-${_nextId++}',
      title: title,
      body: body,
      timeout: timeout,
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
    if (_active?.id == id) {
      _active!._complete(false);
      _advance();
      return;
    }
    final index = _queue.indexWhere((r) => r.id == id);
    if (index >= 0) {
      _queue.removeAt(index)._complete(false);
    }
  }

  /// Record the user's answer. Completes the request exactly once and
  /// emits the next queued question, if any.
  void answerRequest(String id, bool approved) {
    if (_active?.id == id) {
      _active!._complete(true == approved);
      _advance();
    }
  }

  void _activate(ApprovalRequest request) {
    _active = request;
    _requests.add(request);
    // TTL expiry auto-denies, like the reference protocol.
    Future.delayed(request.timeout, () {
      if (!request.isCompleted) {
        request._complete(false);
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
