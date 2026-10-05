// LM Studio client: lets a local model control the phone through the
// same command path as the Muse gadget protocol, bypassing the broken
// device.invoke channel.
//
// The on-device agent runs on the pre-built langchain_dart framework
// (ToolsAgent + AgentExecutor), backed by LM Studio's OpenAI-compatible
// API via ChatOpenAI with a custom baseUrl. Everything is baked into the
// APK: no separate installs, no side-loaded components.

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

import 'package:langchain/langchain.dart';
import 'package:langchain_openai/langchain_openai.dart';

<<<<<<< HEAD
import 'agent_status.dart';
=======
import 'agent_memory.dart';
>>>>>>> dev/hp-memory
import 'approval_service.dart';
import 'event_bus.dart';
import 'lmstudio_tools.dart';
import 'phone_tool_adapter.dart';
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
    this.speakAllowed = true,
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

  /// False when the user turned off "Speak replies": the speak_text tool
  /// will not produce audio. (2026-10-04: voice doomloop fix)
  final bool speakAllowed;

  /// When true, ask SystemOne to narrow the tool list per task.
  final bool systemOneEnabled;

  /// SystemOne router base URL, e.g. http://100.68.208.113:8765.
  final String systemOneUrl;

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
  /// Run [instruction] through the local model with phone tools.
  /// Returns the model's final text.
  ///
  /// The effective model is resolved deterministically: an explicit
  /// selection wins, otherwise the app picks the best loaded model
  /// itself (see [resolveModel]) -- no configuration required.
  ///
  /// The agent loop itself is the pre-built langchain_dart ToolsAgent +
  /// AgentExecutor; the phone's tool registry is adapted to LangChain
  /// tools (see [phoneToolsToLangChain]). Approval-gated tools pop the
  /// user's approval dialog before each execution.
  Future<LocalAiResult> runTask(String instruction) async {
    final effectiveModel = await resolveModel(
      baseUrl: baseUrl,
      explicit: model,
      role: modelRole,
    );
    var tools = lmToolsListFor(
      usbStorageEnabled: usbStorageEnabled,
      usbSerialEnabled: usbSerialEnabled,
    );
    // On-device long-term memory: additive and fail-open. The agent works
    // fine with empty memory. Memory contents never leave the phone: they
    // are only injected into this local system prompt and exposed through
    // the memory_remember / memory_recall tools below.
    final memory = AgentMemory.instance;
    await memory.init();
    tools = [...tools, ...memoryLmTools(memory)];
    if (systemOneEnabled) {
      tools = await _filterLmToolsViaSystemOne(instruction, tools);
    }

    var toolCalls = 0;
    final ctx = LmToolContext(
      phone: phone,
      cameraFacing: cameraFacing,
      speakAllowed: speakAllowed,
    );
    final lcTools = phoneToolsToLangChain(
      tools: tools,
      ctx: ctx,
      approver: approver ??
          ((title, body) => ApprovalService.instance
              .requestApproval(title: title, body: body)),
      onToolCall: () => toolCalls++,
    );

    // ChatOpenAI speaks plain OpenAI-compatible /v1/chat/completions, so
    // it works against raw LM Studio AND a LiteLLM proxy in front of it
    // (e.g. ANTHROPIC_BASE_URL=http://localhost:4000 forwarding to local
    // Ollama, per the NanoClaw pattern). A LiteLLM proxy additionally
    // buys Anthropic-style tool calling, prompt caching, and model
    // routing for free -- just point the Server URL at the proxy.
    final llm = ChatOpenAI(
      apiKey: 'not-needed',
      baseUrl: '$baseUrl/v1',
      defaultOptions: ChatOpenAIOptions(model: effectiveModel),
    );
    final agent = ToolsAgent.fromLLMAndTools(
      llm: llm,
      tools: lcTools,
      systemChatMessage: SystemChatMessagePromptTemplate(
        prompt: PromptTemplate(
          inputVariables: {},
          template:
              "You are a helpful assistant running on the user's phone. "
              'You can control the phone by calling the provided functions. '
              'Call functions when the user asks you to do something on the '
              'phone; otherwise just answer. Keep spoken-style answers short.\n'
              '${_capabilityGuide()}${memory.promptContext()}',
        ),
      ),
    );
    final executor = AgentExecutor(agent: agent, maxIterations: _maxRounds);
    // Status + event bus: additive, fire-and-forget. The agent path must
    // not depend on this.
    AgentStatusBus.instance.working('Thinking...');
    EventBus.instance.emit(
      AppEventKind.status,
      payload: {'text': 'Thinking...', 'working': true},
    );
    try {
      final text = (await executor.run(instruction)).trim();
      AgentStatusBus.instance.ready();
      EventBus.instance.emit(
        AppEventKind.reply,
        payload: {'text': text.length <= 200 ? text : '${text.substring(0, 197)}...'},
      );
      EventBus.instance.emit(
        AppEventKind.status,
        payload: {'text': 'Ready', 'working': false},
      );
      return LocalAiResult(text: text, toolCalls: toolCalls);
    } catch (e) {
      AgentStatusBus.instance.ready();
      EventBus.instance.emit(
        AppEventKind.error,
        payload: {'message': _friendlyError(e)},
      );
      return LocalAiResult(
        text: '',
        toolCalls: toolCalls,
        error: _friendlyError(e),
      );
    }
  }

  /// Ask SystemOne which tools matter for [instruction] and narrow
  /// [allTools] down. Fail-open: any problem returns [allTools] unchanged.
  Future<List<LmTool>> _filterLmToolsViaSystemOne(
    String instruction,
    List<LmTool> allTools,
  ) async {
    final names = [for (final t in allTools) t.name];
    if (names.isEmpty) return allTools;
    final ranked =
        await SystemOneClient(baseUrl: systemOneUrl).rankTools(instruction);
    final picked = filterToolsByRanking(names, ranked).toSet();
    debugPrint(
      'SystemOne tool routing: ${picked.length}/${names.length} tools '
      'selected: ${picked.join(', ')}',
    );
    if (picked.length >= names.length) return allTools;
    // Never filter out approval-gated tools: the user must see the popup
    // when the agent tries them, even if SystemOne ranks them low.
    // (2026-10-04: approval popup never appeared because SystemOne
    // filtered out take_photo for "take a photo")
    final gated = {for (final t in allTools) if (t.requiresApproval) t.name};
    picked.addAll(gated);
    // Never filter out the memory tools either: long-term memory is
    // session infrastructure, not a task-specific capability. Dropping
    // memory_recall would blind the agent to everything it remembered.
    picked.addAll(
      [for (final t in allTools) if (t.name.startsWith('memory_')) t.name],
    );
    return [for (final t in allTools) if (picked.contains(t.name)) t];
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
      'remember lasting facts across sessions with memory_remember and '
          'look them up with memory_recall',
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
