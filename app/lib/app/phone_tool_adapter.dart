// Adapter: exposes the phone's LmTool registry as LangChain.dart Tools so
// the on-device agent runs on the pre-built langchain_dart agent
// framework (ToolsAgent + AgentExecutor) instead of a homegrown loop.
//
// Approval-gated tools ask the user's approver before each execution; a
// denial (or timeout) is returned to the model as plain text so it can
// respond gracefully instead of the run failing.

import 'package:langchain/langchain.dart';

import 'agent_status.dart';
import 'event_bus.dart';
import 'lmstudio_tools.dart';

/// Signature of the user-approval callback: shows a popup and completes
/// with true when the user approves.
typedef ToolApprover = Future<bool> Function(String title, String body);

/// One-line human summary of a tool call for the approval popup.
String describePhoneToolCall(LmTool tool, Map<String, Object?> args) {
  final desc = tool.description.trim();
  if (args.isEmpty) return desc;
  final parts = args.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  return '$desc\n\nArguments: $parts';
}

/// Compute the status label without ever throwing: a bad arg map must
/// not break the tool path.
String _safeLabel(String toolName, Map<String, Object?> args) {
  try {
    return toolLabel(toolName, args);
  } catch (_) {
    return 'Using $toolName...';
  }
}

/// One-line arg summary for the Activity log. Never throws.
String _safeArgsLine(Map<String, Object?> args) {
  try {
    if (args.isEmpty) return '';
    final parts = args.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(', ')
        .trim();
    return parts.length <= 120 ? parts : '${parts.substring(0, 119)}...';
  } catch (_) {
    return '';
  }
}

/// Convert phone [LmTool]s into LangChain [Tool]s backed by the same
/// handlers and the same [ctx]. When [approver] is null, approval-gated
/// tools run without prompting (tests / headless use).
List<Tool> phoneToolsToLangChain({
  required List<LmTool> tools,
  required LmToolContext ctx,
  required ToolApprover? approver,
  void Function()? onToolCall,
}) {
  return [
    for (final t in tools)
      Tool.fromFunction<Map<String, dynamic>, String>(
        name: t.name,
        description: t.description,
        inputJsonSchema: Map<String, dynamic>.from(t.parameters),
        getInputFromJson: (json) => Map<String, dynamic>.from(json),
        func: (input) async {
          onToolCall?.call();
          final args = input.map((k, v) => MapEntry(k, v as Object?));
          // Status + event bus wiring: additive and fire-and-forget.
          // A failure here must never break tool execution.
          final label = _safeLabel(t.name, args);
          final argsLine = _safeArgsLine(args);
          EventBus.instance.emit(
            AppEventKind.toolCall,
            payload: {'tool': t.name, 'label': label, 'args': argsLine},
          );
          AgentStatusBus.instance.working(label);
          if (t.requiresApproval && approver != null) {
            final approved = await approver(
              'Allow "${t.name}"?',
              describePhoneToolCall(t, args),
            );
            if (!approved) {
              EventBus.instance.emit(
                AppEventKind.toolResult,
                payload: {'tool': t.name, 'label': label, 'ok': false,
                    'detail': 'denied by user'},
              );
              return 'denied: the user did not approve the "${t.name}" action';
            }
          }
          try {
            final out = await t.handler(args, ctx);
            EventBus.instance.emit(
              AppEventKind.toolResult,
              payload: {'tool': t.name, 'label': label, 'ok': true},
            );
            // Keep the status fresh so a long tool chain does not
            // expire to "Ready" mid-run; the next tool call updates
            // the label.
            AgentStatusBus.instance.working(label);
            return out;
          } catch (e) {
            EventBus.instance.emit(
              AppEventKind.toolResult,
              payload: {'tool': t.name, 'label': label, 'ok': false,
                  'detail': e.toString()},
            );
            return 'error: $e';
          }
        },
      ),
  ];
}
