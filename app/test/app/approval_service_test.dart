// Tests for ApprovalService: approve, deny, timeout, close, and queueing.
// Mirrors the hermes-gadget-sdk prompt semantics: one question at a time,
// TTL auto-deny, withdrawal denies, exactly-once answers.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/approval_service.dart';
import 'package:muse_companion/app/lmstudio_tools.dart';

void main() {
  group('ApprovalService', () {
    test('approve returns true', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(title: 'T', body: 'B');
      final req = svc.activeForTest!;
      svc.answerRequest(req.id, true);
      expect(await future, isTrue);
    });

    test('deny returns false', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(title: 'T', body: 'B');
      final req = svc.activeForTest!;
      svc.answerRequest(req.id, false);
      expect(await future, isFalse);
    });

    test('timeout auto-denies', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(
        title: 'T',
        body: 'B',
        timeout: const Duration(milliseconds: 50),
      );
      expect(await future, isFalse);
    });

    test('closeRequest withdraws and denies', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(title: 'T', body: 'B');
      final req = svc.activeForTest!;
      svc.closeRequest(req.id);
      expect(await future, isFalse);
      expect(svc.hasPending, isFalse);
    });

    test('answer is exactly once; late answers ignored', () async {
      final svc = ApprovalService();
      final future = svc.requestApproval(title: 'T', body: 'B');
      final req = svc.activeForTest!;
      svc.answerRequest(req.id, true);
      svc.answerRequest(req.id, false); // late answer: no-op
      expect(await future, isTrue);
    });

    test('requests queue: second emitted only after first answered',
        () async {
      final svc = ApprovalService();
      final seen = <String>[];
      final sub = svc.requests.listen((r) => seen.add(r.id));
      final f1 = svc.requestApproval(title: 'first', body: 'B');
      final f2 = svc.requestApproval(title: 'second', body: 'B');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen, hasLength(1));
      svc.answerRequest(svc.activeForTest!.id, true);
      expect(await f1, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen, hasLength(2));
      svc.answerRequest(svc.activeForTest!.id, false);
      expect(await f2, isFalse);
      await sub.cancel();
    });
  });

  group('tool approval flags', () {
    test('mutating and privacy-sensitive tools require approval', () {
      const flagged = [
        'take_photo',
        'get_location',
        'list_notifications',
        'set_alarm',
        'set_timer',
        'show_notification',
        'open_url',
        'launch_app',
        'get_clipboard',
        'set_clipboard',
      ];
      for (final name in flagged) {
        final tool = lmToolNamed(name);
        expect(tool, isNotNull, reason: 'tool $name missing');
        expect(tool!.requiresApproval, isTrue,
            reason: '$name should require approval');
      }
    });

    test('harmless tools do not require approval', () {
      const unflagged = [
        'speak_text',
        'get_device_health',
        'vibrate',
        'toggle_flashlight',
        'usb_list_devices',
        'usb_list_volumes',
        'usb_list_files',
        'usb_serial_list',
      ];
      for (final name in unflagged) {
        final tool = lmToolNamed(name);
        expect(tool, isNotNull, reason: 'tool $name missing');
        expect(tool!.requiresApproval, isFalse,
            reason: '$name should not require approval');
      }
    });
  });
}
