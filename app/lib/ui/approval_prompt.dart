// Approval popup UI: shows the agent's questions as dialogs.
//
// An [ApprovalPromptListener] sits high in the widget tree (wrapping the
// home screen) and shows one dialog per [ApprovalRequest] from
// [ApprovalService]. All four choice buttons stay disabled for 600 ms
// after the popup appears, so a tap meant for something else can't
// accidentally answer it (same debounce as the hermes-gadget-sdk reference
// firmware, which ignores all presses in the first 0.6 s).
//
// The dialog is only shown while the app is foregrounded. When the app is
// backgrounded, approval requests are delivered as notifications with
// inline actions instead (see app/approval_notifications.dart); the dialog
// appears when the app returns to the foreground while a request is still
// pending. If a request is answered elsewhere (notification action,
// timeout), an open dialog dismisses itself.
//
// Choice set ported from hermes-mobile-app (MIT, Omar Qaterge)
// RequestSheet.tsx: Allow once / Allow this session / Always allow / Deny.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:muse_companion/app/approval_service.dart';

/// How long after the popup appears before the choice buttons become
/// tappable.
const Duration _answerDebounce = Duration(milliseconds: 600);

/// Listens for approval requests and shows each as a modal dialog.
/// Place above the home screen so prompts work from any flow.
class ApprovalPromptListener extends StatefulWidget {
  const ApprovalPromptListener({super.key, required this.child});

  final Widget child;

  @override
  State<ApprovalPromptListener> createState() => _ApprovalPromptListenerState();
}

class _ApprovalPromptListenerState extends State<ApprovalPromptListener>
    with WidgetsBindingObserver {
  StreamSubscription<ApprovalRequest>? _sub;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = ApprovalService.instance.requests.listen(_showPrompt);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Returning to the foreground with a request still pending (it was
    // posted as a notification while backgrounded): show the dialog now.
    final pending = ApprovalService.instance.pendingRequest;
    if (pending != null && !_dialogOpen) {
      unawaited(_showPrompt(pending));
    }
  }

  Future<void> _showPrompt(ApprovalRequest request) async {
    if (!mounted || _dialogOpen) return;
    // Backgrounded: the notification path owns this request; the dialog
    // appears on resume via didChangeAppLifecycleState.
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _dialogOpen = true;
    try {
      final choice = await showDialog<ApprovalChoice>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => _ApprovalDialog(request: request),
          ) ??
          ApprovalChoice.deny;
      ApprovalService.instance.answerWithChoice(request.id, choice);
    } finally {
      _dialogOpen = false;
      // A queued request may have activated while this dialog was open
      // (e.g. this one was answered from a notification, whose stream event
      // was skipped by the _dialogOpen guard). Show it now.
      final next = ApprovalService.instance.pendingRequest;
      if (next != null &&
          next.id != request.id &&
          !next.isCompleted &&
          mounted) {
        unawaited(_showPrompt(next));
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ApprovalDialog extends StatefulWidget {
  const _ApprovalDialog({required this.request});

  final ApprovalRequest request;

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  bool _canAnswer = false;
  bool _answered = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _debounce = Timer(_answerDebounce, () {
      if (mounted) setState(() => _canAnswer = true);
    });
    // Answered elsewhere (notification action, timeout, withdrawal):
    // dismiss the dialog; the service already recorded the answer and any
    // answerWithChoice from _showPrompt's continuation is a no-op.
    widget.request.future.then((_) {
      if (mounted && !_answered) {
        _answered = true;
        Navigator.of(context).pop(ApprovalChoice.deny);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _answer(ApprovalChoice choice) {
    if (_answered || !_canAnswer) return;
    _answered = true;
    Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final toolName = widget.request.toolName;
    // Session/always choices only make sense when the request is about a
    // known tool; server-driven prompts have no tool to allowlist.
    final hasTool = toolName != null && toolName.isNotEmpty;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.request.title)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(child: Text(widget.request.body)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed:
                      _canAnswer ? () => _answer(ApprovalChoice.allowOnce) : null,
                  child: const Text('Allow once'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _canAnswer && hasTool
                      ? () => _answer(ApprovalChoice.allowSession)
                      : null,
                  child: const Text('This session'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _canAnswer && hasTool
                      ? () => _answer(ApprovalChoice.alwaysAllow)
                      : null,
                  child: const Text('Always allow'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed:
                      _canAnswer ? () => _answer(ApprovalChoice.deny) : null,
                  child: const Text('Deny'),
                ),
              ),
            ],
          ),
          if (hasTool) ...[
            const SizedBox(height: 8),
            Text(
              'Session and always choices apply to "$toolName".',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
