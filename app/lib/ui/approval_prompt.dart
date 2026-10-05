// Approval popup UI: shows the agent's yes/no questions as dialogs.
//
// An [ApprovalPromptListener] sits high in the widget tree (wrapping the
// home screen) and shows one dialog per [ApprovalRequest] from
// [ApprovalService]. Both buttons stay disabled for 600 ms after the popup
// appears, so a tap meant for something else can't accidentally answer it
// (same debounce as the hermes-gadget-sdk reference firmware, which ignores
// all presses in the first 0.6 s).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:muse_companion/app/approval_service.dart';

/// How long after the popup appears before either button becomes tappable.
const Duration _answerDebounce = Duration(milliseconds: 600);

/// Listens for approval requests and shows each as a modal dialog.
/// Place above the home screen so prompts work from any flow.
class ApprovalPromptListener extends StatefulWidget {
  const ApprovalPromptListener({super.key, required this.child});

  final Widget child;

  @override
  State<ApprovalPromptListener> createState() => _ApprovalPromptListenerState();
}

class _ApprovalPromptListenerState extends State<ApprovalPromptListener> {
  StreamSubscription<ApprovalRequest>? _sub;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _sub = ApprovalService.instance.requests.listen(_showPrompt);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _showPrompt(ApprovalRequest request) async {
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;
    try {
      final approved = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => _ApprovalDialog(request: request),
          ) ??
          false;
      ApprovalService.instance.answerRequest(request.id, approved);
    } finally {
      _dialogOpen = false;
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
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _debounce = Timer(_answerDebounce, () {
      if (mounted) setState(() => _canAnswer = true);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.request.title)),
        ],
      ),
      content: SingleChildScrollView(child: Text(widget.request.body)),
      actions: [
        TextButton(
          onPressed:
              _canAnswer ? () => Navigator.of(context).pop(false) : null,
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed:
              _canAnswer ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Approve'),
        ),
      ],
    );
  }
}
