// Tests for the four-way approval choices: once / session / always / deny.
// Verifies the session and always allowlists auto-approve later requests
// for the same tool, that the legacy yes/no API still maps to allow-once,
// and that queued requests bypass the popup once their tool is allowed.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/approval_service.dart';

class _MemoryAllowStore implements AlwaysAllowStore {
  final Set<String> allowed = <String>{};

  @override
  Set<String> loadAllowed() => Set<String>.of(allowed);

  @override
  Future<void> setAllowed(String toolName, bool allowed) async {
    if (allowed) {
      this.allowed.add(toolName);
    } else {
      this.allowed.remove(toolName);
    }
  }
}

void main() {
  group('ApprovalChoice', () {
    test('allowOnce approves only the answered request', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(title: 'Allow "take_photo"?', body: 'B');
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.allowOnce);
      expect(await future, isTrue);
      // Next request for the same tool still prompts.
      final future2 = svc.requestApproval(title: 'Allow "take_photo"?', body: 'B');
      expect(svc.hasPending, isTrue);
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.deny);
      expect(await future2, isFalse);
    });

    test('allowSession auto-approves later requests for the tool', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(title: 'Allow "take_photo"?', body: 'B');
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.allowSession);
      expect(await future, isTrue);
      // Auto-approved: no popup, no queue entry.
      expect(svc.hasPending, isFalse);
      expect(
        await svc.requestApproval(title: 'Allow "take_photo"?', body: 'B'),
        isTrue,
      );
      expect(svc.hasPending, isFalse);
      // A different tool still prompts.
      final other = svc.requestApproval(title: 'Allow "set_alarm"?', body: 'B');
      expect(svc.hasPending, isTrue);
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.deny);
      expect(await other, isFalse);
    });

    test('explicit toolName parameter is honored', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(
        title: 'Custom question?',
        body: 'B',
        toolName: 'get_location',
      );
      expect(svc.activeForTest!.toolName, 'get_location');
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.allowSession);
      expect(await future, isTrue);
      expect(
        await svc.requestApproval(title: 'Anything', body: 'B', toolName: 'get_location'),
        isTrue,
      );
    });

    test('queued request auto-approves once its tool is session-allowed',
        () async {
      final svc = ApprovalService();
      final f1 = svc.requestApproval(title: 'Allow "take_photo"?', body: 'B');
      final f2 = svc.requestApproval(title: 'Allow "take_photo"?', body: 'B');
      expect(svc.hasPending, isTrue);
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.allowSession);
      expect(await f1, isTrue);
      // The queued second request bypassed the popup entirely.
      expect(await f2, isTrue);
      expect(svc.hasPending, isFalse);
    });

    test('alwaysAllow persists through the store', () async {
      final store = _MemoryAllowStore();
      final svc = ApprovalService()..allowanceStore = store;
      final future = svc.requestApproval(title: 'Allow "set_alarm"?', body: 'B');
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.alwaysAllow);
      expect(await future, isTrue);
      expect(store.allowed, contains('set_alarm'));
      // A fresh service with the same store auto-approves (simulates
      // an app restart).
      final svc2 = ApprovalService()..allowanceStore = store;
      expect(
        await svc2.requestApproval(title: 'Allow "set_alarm"?', body: 'B'),
        isTrue,
      );
      expect(svc2.hasPending, isFalse);
    });

    test('revokeAlwaysAllow clears the persisted decision', () async {
      final store = _MemoryAllowStore();
      final svc = ApprovalService()..allowanceStore = store;
      final future = svc.requestApproval(title: 'Allow "set_alarm"?', body: 'B');
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.alwaysAllow);
      expect(await future, isTrue);
      await svc.revokeAlwaysAllow('set_alarm');
      expect(store.allowed, isNot(contains('set_alarm')));
      final next = svc.requestApproval(title: 'Allow "set_alarm"?', body: 'B');
      expect(svc.hasPending, isTrue);
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.deny);
      expect(await next, isFalse);
    });

    test('legacy answerRequest maps true to allow-once', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(title: 'Allow "take_photo"?', body: 'B');
      final req = svc.activeForTest!;
      svc.answerRequest(req.id, true);
      expect(await future, isTrue);
      expect(req.answer, ApprovalChoice.allowOnce);
      // Still prompts next time: allow-once does not allowlist.
      final future2 = svc.requestApproval(title: 'Allow "take_photo"?', body: 'B');
      expect(svc.hasPending, isTrue);
      svc.answerRequest(svc.activeForTest!.id, false);
      expect(await future2, isFalse);
      expect(svc.activeForTest, isNull);
    });

    test('deny records the choice on the request', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(title: 'T', body: 'B');
      final req = svc.activeForTest!;
      svc.answerWithChoice(req.id, ApprovalChoice.deny);
      expect(await future, isFalse);
      expect(req.answer, ApprovalChoice.deny);
    });

    test('non-tool prompts never auto-approve', () async {
      final svc = ApprovalService();
      // Server-driven prompt: no tool name in title, none passed.
      final future = svc.requestApproval(title: 'Confirm?', body: 'B');
      expect(svc.hasPending, isTrue);
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.allowSession);
      expect(await future, isTrue);
      // Nothing was allowlisted: next prompt still shows.
      final future2 = svc.requestApproval(title: 'Confirm?', body: 'B');
      expect(svc.hasPending, isTrue);
      svc.answerWithChoice(svc.activeForTest!.id, ApprovalChoice.deny);
      expect(await future2, isFalse);
    });
  });
}
