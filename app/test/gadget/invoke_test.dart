import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/invoke.dart';

void main() {
  test('link.invoke keeps a top-level command', () {
    final parsed = parseInvoke({
      'method': 'link.invoke',
      'id': 'inv-1',
      'command': 'companion.set_status',
      'params': {'text': 'hello'},
      'timeout_ms': 5000,
    });
    expect(parsed, isNotNull);
    expect(parsed!.id, 'inv-1');
    expect(parsed.command, 'companion.set_status');
    expect(parsed.params, {'text': 'hello'});
    expect(parsed.timeoutMs, 5000);
    expect(parsed.replyType, isNull);
  });

  test('device.invoke reads a nested command and a numeric id', () {
    final parsed = parseInvoke({
      'method': 'device.invoke',
      'id': 7,
      'type': 'req',
      'params': {
        'command': 'device.health',
        'params': {'verbose': true},
      },
    });
    expect(parsed, isNotNull);
    expect(parsed!.id, 7);
    expect(parsed.command, 'device.health');
    expect(parsed.params, {'verbose': true});
    expect(parsed.replyType, 'res');
  });

  test('a dotted method is the command itself', () {
    final parsed = parseInvoke({
      'method': 'device.health',
      'id': 'bare-1',
      'params': <String, Object?>{},
    });
    expect(parsed!.command, 'device.health');
    expect(parsed.id, 'bare-1');
  });

  test('register acks and heartbeats are not invokes', () {
    expect(parseInvoke({'id': 'r', 'ok': true}), isNull);
    expect(parseInvoke({'method': 'link.heartbeat', 'id': 'h'}), isNull);
    expect(parseInvoke({'method': 'device.invoke'}), isNull);
  });
}
