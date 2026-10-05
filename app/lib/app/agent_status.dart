// Agent status heartbeat: a human-readable "what is the agent doing"
// line, consumed by the chat screen status indicator (and anything else
// that wants it).
//
// Ported concept from hermes-mobile-app (MIT, Omar Qaterge): their
// `_tool_label()` / `_tool_short()` mapper logic, `STATUS_MIN_INTERVAL`
// throttling, and expiry-to-Ready after inactivity. Adapted from their
// Hermes-plugin tool names to our langchain_dart phone tool registry.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'event_bus.dart';

/// What the agent is doing right now, for the status line.
class AgentStatus {
  const AgentStatus({
    required this.text,
    required this.working,
    required this.at,
  });

  /// Idle state shown when nothing is running.
  static AgentStatus ready() =>
      AgentStatus(text: 'Ready', working: false, at: DateTime.now());

  final String text;
  final bool working;
  final DateTime at;
}

/// Process-wide agent status. Agent code calls [working] / [ready];
/// the UI listens on [status] (a [ValueNotifier]) or on the event bus.
class AgentStatusBus {
  AgentStatusBus._();

  static final AgentStatusBus instance = AgentStatusBus._();

  /// Min interval between accepted status updates (the reference used
  /// STATUS_MIN_INTERVAL = 1.0s).
  static const Duration throttleInterval = Duration(seconds: 1);

  /// Status expires back to "Ready" after this long with no activity.
  static const Duration expiryAfter = Duration(seconds: 5);

  final ValueNotifier<AgentStatus> status =
      ValueNotifier<AgentStatus>(AgentStatus.ready());

  DateTime _lastAccepted = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _throttleTimer;
  Timer? _expiryTimer;
  String? _pendingText;

  /// Publish a working status. Throttled to [throttleInterval]: rapid
  /// updates collapse, the latest one wins.
  void working(String text) {
    _armExpiry();
    final now = DateTime.now();
    if (now.difference(_lastAccepted) >= throttleInterval) {
      _accept(text);
      return;
    }
    // Inside the throttle window: hold the latest, flush it when the
    // window closes.
    _pendingText = text;
    _throttleTimer ??= Timer(
      throttleInterval - now.difference(_lastAccepted),
      () {
        _throttleTimer = null;
        final pending = _pendingText;
        _pendingText = null;
        if (pending != null) _accept(pending);
      },
    );
  }

  /// Publish "Ready" (agent finished / idle). Cancels pending updates.
  void ready() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _pendingText = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    status.value = AgentStatus.ready();
    EventBus.instance.emit(
      AppEventKind.status,
      payload: {'text': 'Ready', 'working': false},
    );
  }

  void _accept(String text) {
    _lastAccepted = DateTime.now();
    status.value = AgentStatus(text: text, working: true, at: _lastAccepted);
    EventBus.instance.emit(
      AppEventKind.status,
      payload: {'text': text, 'working': true},
    );
  }

  void _armExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = Timer(expiryAfter, () {
      if (status.value.working) ready();
    });
  }
}

/// Collapse a value to a single line, capped at [n] chars.
/// (Port of their `_short`.)
String _short(Object? v, [int n = 60]) {
  final words = v?.toString().split(RegExp(r'\s+')) ?? const <String>[];
  final s = words.join(' ');
  return s.length <= n ? s : '${s.substring(0, n - 1)}…';
}

/// Human-readable label for a tool call, e.g. "Running `ls /sdcard`".
/// Phone tool names with a dedicated friendly label in [toolLabel].
/// Used to recognize tool activity codes reported by the server.
const Set<String> labeledToolNames = {
  'take_photo',
  'speak_text',
  'get_device_health',
  'get_location',
  'list_notifications',
  'set_alarm',
  'set_timer',
  'show_notification',
  'open_url',
  'launch_app',
  'vibrate',
  'get_clipboard',
  'set_clipboard',
  'toggle_flashlight',
  'usb_list_devices',
  'usb_list_volumes',
  'usb_list_files',
  'usb_serial_list',
};

/// Whether [toolName] has a dedicated friendly label.
bool hasToolLabel(String toolName) => labeledToolNames.contains(toolName);

/// Ported mapper logic from their `_tool_label`, adapted to our phone
/// tool registry (see lmstudio_tools.dart).
String toolLabel(String toolName, Map<String, Object?> args) {
  final first = args['command'] ??
      args['path'] ??
      args['query'] ??
      args['text'] ??
      args['url'] ??
      args['package'] ??
      args['name'] ??
      args['instruction'] ??
      '';
  switch (toolName) {
    case 'take_photo':
      final facing = args['facing']?.toString();
      return facing == 'front'
          ? 'Taking a selfie…'
          : 'Taking a photo…';
    case 'speak_text':
      return 'Speaking…';
    case 'get_device_health':
      return 'Checking device health…';
    case 'get_location':
      return 'Getting location…';
    case 'list_notifications':
      return 'Listing notifications…';
    case 'set_alarm':
      return 'Setting an alarm…';
    case 'set_timer':
      return 'Setting a timer…';
    case 'show_notification':
      return 'Showing a notification…';
    case 'open_url':
      return 'Opening ${_short(first, 40)}…';
    case 'launch_app':
      return 'Opening ${_short(first, 40)}…';
    case 'vibrate':
      return 'Vibrating…';
    case 'get_clipboard':
      return 'Reading the clipboard…';
    case 'set_clipboard':
      return 'Copying to the clipboard…';
    case 'toggle_flashlight':
      return 'Toggling the flashlight…';
    case 'usb_list_devices':
      return 'Listing USB devices…';
    case 'usb_list_volumes':
      return 'Browsing USB storage…';
    case 'usb_list_files':
      return 'Browsing ${_short(first, 40)}…';
    case 'usb_serial_list':
      return 'Listing serial ports…';
    default:
      if (first.toString().isNotEmpty) {
        return '$toolName: ${_short(first)}';
      }
      return 'Using $toolName…';
  }
}

/// One-word category for a tool, for compact UI surfaces.
/// (Port of their `_tool_short`.)
String toolShort(String toolName) {
  switch (toolName) {
    case 'take_photo':
      return 'Camera';
    case 'speak_text':
      return 'Voice';
    case 'get_device_health':
      return 'Device';
    case 'get_location':
      return 'Location';
    case 'list_notifications':
    case 'show_notification':
      return 'Notify';
    case 'set_alarm':
    case 'set_timer':
      return 'Clock';
    case 'open_url':
    case 'launch_app':
      return 'Open';
    case 'get_clipboard':
    case 'set_clipboard':
      return 'Paste';
    case 'usb_list_devices':
    case 'usb_list_volumes':
    case 'usb_list_files':
    case 'usb_serial_list':
      return 'USB';
    default:
      return toolName.length <= 8
          ? '${toolName[0].toUpperCase()}${toolName.substring(1)}'
          : '${toolName[0].toUpperCase()}${toolName.substring(1, 8)}';
  }
}
