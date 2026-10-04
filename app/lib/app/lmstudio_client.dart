// LM Studio client: lets a local model control the phone through the
// same command path as the Muse gadget protocol, bypassing the broken
// device.invoke channel.
// Flow: instruction -> POST /v1/chat/completions with tools ->
//   execute tool calls via PhoneBridge -> feed results back ->
//   repeat until the model answers (max 10 rounds).
//
// Endpoint compatibility: this client speaks plain OpenAI-compatible
// /v1/chat/completions, so it works against raw LM Studio AND a LiteLLM
// proxy in front of it (e.g. ANTHROPIC_BASE_URL=http://localhost:4000
// forwarding to local Ollama, per the NanoClaw pattern). A LiteLLM proxy
// additionally buys Anthropic-style tool calling, prompt caching, and
// model routing for free — just point the Server URL at the proxy.
// Tool-call response parsing follows the standard OpenAI shape, which
// both servers return.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'approval_service.dart';
import 'lmstudio_tools.dart';
import 'systemone_client.dart';
import 'systemone_toolmap.dart';
import '../src/gadget/phone_actions.dart';

/// Per-request timeout for LM Studio chat completions.
const Duration _requestTimeout = Duration(seconds: 60);

/// Max tool-call rounds before giving up.
const int _maxRounds = 10;

/// SharedPreferences key for the cached GET /v1/models id list.
/// Shared with the settings UI's model selector so task-time resolution
/// can fall back to the last known list when the server is unreachable.
const String lmStudioModelListCacheKey = 'lm_studio_model_list_cache';

/// SharedPreferences keys for the last auto-resolved model per role.
/// Kept separate from the user's explicit selection so an explicit pick
/// always wins and a derived default can be re-resolved when the loaded
/// models change.
const String _resolvedAgentKey = 'lm_studio_agent_model_resolved';
const String _resolvedChatKey = 'lm_studio_chat_model_resolved';

/// Result of a local-AI task run.
class LocalAiResult {
  const LocalAiResult({required this.text, this.toolCalls = 0, this.error = ''});

  /// The model's final answer, or '' when [error] is set.
  final String text;

  /// How many tool calls were executed.
  final int toolCalls;

  /// Empty on success.
  final String error;

  bool get ok => error.isEmpty;
}

/// Runs tasks against an LM Studio server, executing tool calls on the
/// phone. Create one per task; it holds no mutable state.
class LocalAiService {
  LocalAiService({
    required this.baseUrl,
    required this.model,
    required this.phone,
    required this.usbStorageEnabled,
    required this.usbSerialEnabled,
    this.cameraFacing = 'back',
    this.systemOneEnabled = false,
    this.systemOneUrl = 'http://100.68.208.113:8765',
    this.modelRole = 'agent',
    this.approver,
  });

  /// Decides whether a flagged tool call may run. Defaults to the
  /// [ApprovalService] popup; tests inject a fake.
  final Future<bool> Function(String title, String body)? approver;

  /// e.g. http://100.68.208.113:1234 (no trailing slash).
  final String baseUrl;

  /// Model id, or '' to use the server default.
  final String model;

  /// Which role this task runs as: 'agent' (decision/tool-calling) or
  /// 'chat' (conversational). Only used when [model] is empty and a
  /// deterministic default must be picked.
  final String modelRole;
  final PhoneActions phone;
  final bool usbStorageEnabled;
  final bool usbSerialEnabled;
  final String cameraFacing;

  /// When true, ask SystemOne to narrow the tool list per task.
  final bool systemOneEnabled;

  /// SystemOne router base URL, e.g. http://100.68.208.113:8765.
  final String systemOneUrl;

  Uri get _completions =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/chat/completions');

  Uri get _models =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/models');

  /// Fetch available model ids from GET {baseUrl}/v1/models.
  /// Returns the ids, or an empty list on any failure.
  static Future<List<String>> fetchModelIds(String baseUrl) async {
    try {
      final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/models');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body);
      if (body is! Map || body['data'] is! List) return const [];
      final ids = (body['data'] as List)
          .whereType<Map>()
          .map((m) => m['id'])
          .whereType<String>()
          .where((id) => id.trim().isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      return ids;
    } catch (_) {
      return const [];
    }
  }

  /// Pick a deterministic default model id from [ids] for [role].
  ///
  /// - 'agent': prefer a decision/tool-calling model (id contains 'clef'),
  ///   else the first loaded model.
  /// - 'chat': prefer a conversational model (first id NOT containing
  ///   'clef'), else the first loaded model.
  ///
  /// [ids] is expected sorted (as [fetchModelIds] returns), so the pick is
  /// stable for the same server state. Returns '' when [ids] is empty.
  static String pickForRole(List<String> ids, String role) {
    if (ids.isEmpty) return '';
    final lower = ids.map((id) => id.toLowerCase()).toList();
    if (role == 'chat') {
      for (var i = 0; i < ids.length; i++) {
        if (!lower[i].contains('clef')) return ids[i];
      }
      return ids.first;
    }
    // 'agent' and any unknown role: prefer a clef decision model.
    for (var i = 0; i < ids.length; i++) {
      if (lower[i].contains('clef')) return ids[i];
    }
    return ids.first;
  }

  /// Resolve the effective model id for a task.
  ///
  /// Priority: explicit user selection > smart default > server default.
  ///
  /// 1. [explicit] non-empty: the user picked it, use it as-is.
  /// 2. Otherwise query GET {baseUrl}/v1/models and pick deterministically
  ///    via [pickForRole]; the pick is persisted per role so it stays
  ///    stable across tasks.
  /// 3. If the server is unreachable, fall back to the cached model list
  ///    (shared with the settings UI) and pick from that.
  /// 4. If there is no list at all, reuse the last persisted pick.
  /// 5. Last resort: return '' so the request omits the model field and
  ///    the server picks — never send an ambiguous request when a
  ///    deterministic choice exists.
  static Future<String> resolveModel({
    required String baseUrl,
    required String explicit,
    required String role,
  }) async {
    if (explicit.trim().isNotEmpty) return explicit.trim();
    final resolvedKey = role == 'chat' ? _resolvedChatKey : _resolvedAgentKey;

    List<String> ids = await fetchModelIds(baseUrl);
    if (ids.isEmpty) {
      ids = await _cachedModelIds();
    }
    if (ids.isNotEmpty) {
      final pick = pickForRole(ids, role);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(resolvedKey, pick);
      } catch (_) {
        // Persisting the pick is best-effort; the pick itself stands.
      }
      debugPrint('LocalAiService: auto-resolved $role model -> $pick');
      return pick;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(resolvedKey) ?? '';
      if (last.trim().isNotEmpty) {
        debugPrint('LocalAiService: reusing last resolved $role model -> $last');
        return last.trim();
      }
    } catch (_) {
      // Best-effort.
    }
    debugPrint('LocalAiService: no model list available, using server default');
    return '';
  }

  /// Read the cached /v1/models id list (written by the settings UI and
  /// by [resolveModel]'s fresh fetches). Empty list when absent/corrupt.
  static Future<List<String>> _cachedModelIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(lmStudioModelListCacheKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final ids = decoded.whereType<String>().toList()..sort();
      return ids;
    } catch (_) {
      return const [];
    }
  }

  /// Quick connectivity check. Returns empty string on success, else an error.
  Future<String> testConnection() async {    try {
      final res = await http.get(_models).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        return 'HTTP ${res.statusCode}: ${res.body.trim()}'.trim();
      }
      final body = jsonDecode(res.body);
      if (body is Map && body['data'] is List) {
        final ids = (body['data'] as List)
            .whereType<Map>()
            .map((m) => m['id'])
            .whereType<String>()
            .toList();
        return ids.isEmpty
            ? 'Connected, but the server reports no loaded models.'
            : '';
      }
      return '';
    } catch (e) {
      return _friendlyError(e);
    }
  }

  /// Run [instruction] through the local model with phone tools.
  /// Returns the model's final text.
  ///
  /// The effective model is resolved deterministically: an explicit
  /// selection wins, otherwise the app picks the best loaded model
  /// itself (see [resolveModel]) — no configuration required.
  Future<LocalAiResult> runTask(String instruction) async {
    final effectiveModel = await resolveModel(
      baseUrl: baseUrl,
      explicit: model,
      role: modelRole,
    );
    var tools = lmToolsFor(
      usbStorageEnabled: usbStorageEnabled,
      usbSerialEnabled: usbSerialEnabled,
    );
    if (systemOneEnabled) {
      tools = await _filterToolsViaSystemOne(instruction, tools);
    }
    final messages = <Map<String, Object?>>[
      {
        'role': 'system',
        'content':
            'You are a helpful assistant running on the user\'s phone. '
            'You can control the phone by calling the provided functions. '
            'Call functions when the user asks you to do something on the '
            'phone; otherwise just answer. Keep spoken-style answers short.\n'
            '${_capabilityGuide()}',
      },
      {'role': 'user', 'content': instruction},
    ];

    var toolCalls = 0;
    try {
      for (var round = 0; round < _maxRounds; round++) {
        final reply = await _chat(messages, tools, effectiveModel);
        final message = reply['message'];
        if (message is! Map) {
          return const LocalAiResult(
            text: '',
            error: 'Bad response from LM Studio (no message).',
          );
        }
        final calls = message['tool_calls'];
        if (calls is! List || calls.isEmpty) {
          final text = message['content'];
          return LocalAiResult(
            text: text is String ? text.trim() : '',
            toolCalls: toolCalls,
          );
        }
        messages.add({
          'role': 'assistant',
          'content': message['content'],
          'tool_calls': calls,
        });
        for (final call in calls.whereType<Map>()) {
          toolCalls++;
          final result = await _executeToolCall(call);
          messages.add({
            'role': 'tool',
            'tool_call_id': call['id']?.toString() ?? '',
            'content': result,
          });
        }
      }
      return LocalAiResult(
        text: '',
        toolCalls: toolCalls,
        error: 'Stopped after $_maxRounds tool rounds without a final answer.',
      );
    } catch (e) {
      return LocalAiResult(
        text: '',
        toolCalls: toolCalls,
        error: _friendlyError(e),
      );
    }
  }

  Future<Map<String, Object?>> _chat(
    List<Map<String, Object?>> messages,
    List<Map<String, Object?>> tools,
    String effectiveModel,
  ) async {
    final body = <String, Object?>{
      'messages': messages,
      'tools': tools,
      'tool_choice': 'auto',
    };
    if (effectiveModel.trim().isNotEmpty) body['model'] = effectiveModel.trim();
    final res = await http
        .post(
          _completions,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_requestTimeout);
    if (res.statusCode != 200) {
      throw StateError(
        'LM Studio HTTP ${res.statusCode}: ${res.body.trim()}'.trim(),
      );
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) throw StateError('Bad JSON from LM Studio.');
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw StateError('LM Studio returned no choices.');
    }
    final first = choices.first;
    if (first is! Map) throw StateError('Bad choice shape from LM Studio.');
    return first.map((k, v) => MapEntry(k.toString(), v as Object?));
  }

  /// Execute one tool call via the registry handler, return the string
  /// to feed back to the model.
  Future<String> _executeToolCall(Map call) async {
    final fn = call['function'];
    if (fn is! Map) return 'error: malformed tool call';
    final name = fn['name']?.toString() ?? '';
    final tool = lmToolNamed(name);
    if (tool == null) return 'error: unknown tool "$name"';
    Map<String, Object?> args;
    try {
      final rawArgs = fn['arguments'];
      if (rawArgs is String && rawArgs.trim().isNotEmpty) {
        final decoded = jsonDecode(rawArgs);
        args = decoded is Map
            ? decoded.map((k, v) => MapEntry(k.toString(), v))
            : <String, Object?>{};
      } else if (rawArgs is Map) {
        args = rawArgs.map((k, v) => MapEntry(k.toString(), v));
      } else {
        args = <String, Object?>{};
      }
    } catch (_) {
      return 'error: could not parse arguments for "$name"';
    }

    if (tool.requiresApproval) {
      final approve = approver ?? ApprovalService.instance.requestApproval;
      final approved = await approve(
        'Allow "${tool.name}"?',
        _describeToolCall(tool, args),
      );
      if (!approved) {
        return 'denied: the user did not approve the "${tool.name}" action';
      }
    }
    try {
      final ctx = LmToolContext(phone: phone, cameraFacing: cameraFacing);
      return await tool.handler(args, ctx);
    } catch (e) {
      return 'error: ${_friendlyError(e)}';
    }
  }

  /// One-line human summary of a tool call for the approval popup:
  /// the tool's description plus its key arguments.
  String _describeToolCall(LmTool tool, Map<String, Object?> args) {
    final desc = tool.description.trim();
    if (args.isEmpty) return desc;
    final parts = args.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(', ');
    return '$desc\n\nArguments: $parts';
  }

  /// Ask SystemOne which tools matter for [instruction] and narrow
  /// [allTools] down. Fail-open: any problem returns [allTools] unchanged.
  Future<List<Map<String, Object?>>> _filterToolsViaSystemOne(
    String instruction,
    List<Map<String, Object?>> allTools,
  ) async {
    final names = <String>[];
    for (final t in allTools) {
      final fn = t['function'];
      if (fn is Map) {
        final name = fn['name']?.toString() ?? '';
        if (name.isNotEmpty) names.add(name);
      }
    }
    if (names.isEmpty) return allTools;
    final ranked =
        await SystemOneClient(baseUrl: systemOneUrl).rankTools(instruction);
    final picked = filterToolsByRanking(names, ranked).toSet();
    debugPrint(
      'SystemOne tool routing: ${picked.length}/${names.length} tools '
      'selected: ${picked.join(', ')}',
    );
    if (picked.length >= names.length) return allTools;
    return [
      for (final t in allTools)
        if (picked.contains((t['function'] as Map)['name']?.toString())) t,
    ];
  }

  /// Natural-language capability summary, appended to the system prompt
  /// so smaller local models know what they can do even if they are weak
  /// at reading raw tool schemas.
  String _capabilityGuide() {
    final caps = <String>[
      'take a photo with take_photo',
      'speak text aloud with speak_text',
      'check battery and device info with get_device_health',
      'get the phone location with get_location',
      'list notifications with list_notifications',
      'set alarms and timers with set_alarm and set_timer',
      'show a notification with show_notification',
      'open URLs and apps with open_url and launch_app',
      'vibrate, read/set the clipboard, toggle the flashlight',
    ];
    if (usbStorageEnabled) {
      caps.add(
        'list USB devices and browse USB storage with usb_list_devices, '
        'usb_list_volumes and usb_list_files',
      );
    }
    if (usbSerialEnabled) {
      caps.add('list USB serial ports with usb_serial_list');
    }
    return 'Your phone capabilities: ${caps.join('; ')}.';
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('Connection refused') || s.contains('Connection timed out')) {
      return 'Cannot reach LM Studio at $baseUrl. '
          'Check the server URL in Settings and that LM Studio is running.';
    }
    if (s.contains('TimeoutException')) {
      return 'LM Studio timed out after ${_requestTimeout.inSeconds}s. '
          'The model may be loading or overloaded.';
    }
    return s.replaceFirst(RegExp(r'^[^:]+Exception: '), '');
  }
}
