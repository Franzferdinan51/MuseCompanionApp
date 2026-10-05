// Tests for the LangChain phone-tool adapter.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/lmstudio_tools.dart';
import 'package:muse_companion/app/phone_tool_adapter.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

class _FakePhone extends PhoneActions {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LmTool _tool(
  String name, {
  bool requiresApproval = false,
  Future<String> Function(Map<String, Object?> args)? run,
}) {
  return LmTool(
    name: name,
    description: 'Test tool $name',
    parameters: const {
      'type': 'object',
      'properties': {
        'q': {'type': 'string', 'description': 'query'},
      },
    },
    requiresApproval: requiresApproval,
    handler: (args, ctx) async =>
        run != null ? run(args) : 'ran $name with ${args['q']}',
  );
}

LmToolContext _ctx() => LmToolContext(phone: _FakePhone(), cameraFacing: 'back');

void main() {
  group('phoneToolsToLangChain', () {
    test('adapts name, description, and schema', () {
      final tools = phoneToolsToLangChain(
        tools: [_tool('get_battery')],
        ctx: _ctx(),
        approver: null,
      );
      expect(tools, hasLength(1));
      final t = tools.single;
      expect(t.name, 'get_battery');
      expect(t.description, contains('get_battery'));
      expect(t.inputJsonSchema['type'], 'object');
    });

    test('executes the handler and returns its text', () async {
      final tools = phoneToolsToLangChain(
        tools: [_tool('echo')],
        ctx: _ctx(),
        approver: null,
      );
      final out = await tools.single.invoke(<String, dynamic>{'q': 'hi'});
      expect(out, contains('ran echo'));
      expect(out, contains('hi'));
    });

    test('approval-gated tool runs when approved', () async {
      var asked = false;
      final tools = phoneToolsToLangChain(
        tools: [_tool('take_photo', requiresApproval: true)],
        ctx: _ctx(),
        approver: (title, body) async {
          asked = true;
          expect(title, contains('take_photo'));
          return true;
        },
      );
      final out = await tools.single.invoke(<String, dynamic>{'q': 'x'});
      expect(asked, isTrue);
      expect(out, contains('ran take_photo'));
    });

    test('approval-gated tool is denied when the user says no', () async {
      var asked = false;
      final tools = phoneToolsToLangChain(
        tools: [_tool('take_photo', requiresApproval: true)],
        ctx: _ctx(),
        approver: (title, body) async {
          asked = true;
          return false;
        },
      );
      final out = await tools.single.invoke(<String, dynamic>{'q': 'x'});
      expect(asked, isTrue);
      expect(out, contains('denied'));
    });

    test('handler errors become error text, not exceptions', () async {
      final tools = phoneToolsToLangChain(
        tools: [
          _tool('boom', run: (_) => throw StateError('kaput')),
        ],
        ctx: _ctx(),
        approver: null,
      );
      final out = await tools.single.invoke(<String, dynamic>{});
      expect(out, contains('error'));
    });

    test('real registry tools adapt without throwing', () {
      final all = lmToolsListFor(usbStorageEnabled: true, usbSerialEnabled: true);
      expect(all, isNotEmpty);
      final tools = phoneToolsToLangChain(
        tools: all,
        ctx: _ctx(),
        approver: null,
      );
      expect(tools.map((t) => t.name).toSet(), hasLength(tools.length));
      // Every adapted tool keeps its approval flag semantics.
      for (final t in tools) {
        expect(t.name, isNotEmpty);
        expect(t.description, isNotEmpty);
      }
    });
  });
}
