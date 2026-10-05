// Maps our phone tool names to SystemOne-ish concept keywords, so
// SystemOne's ranked_tools (its own vocabulary, e.g. "apple-events") can
// be fuzzy-matched down to the phone tools relevant for a task.
//
// Matching is case-insensitive: a hit when the SystemOne tool ID contains
// a keyword or a keyword contains the ID (covers "alarm" vs "alarms").

import 'systemone_client.dart';

/// Concept keywords per phone tool name.
const Map<String, List<String>> _toolConcepts = {
  'take_photo': ['camera', 'photo', 'vision', 'image', 'picture'],
  'speak_text': ['tts', 'speak', 'speaker', 'audio', 'voice'],
  'get_device_health': ['device', 'battery', 'health', 'status', 'system'],
  'get_location': ['location', 'gps', 'position', 'geolocation'],
  'list_notifications': ['notification'],
  'set_alarm': ['alarm', 'clock'],
  'set_timer': ['timer', 'clock'],
  'show_notification': ['notification', 'notify', 'alert'],
  'open_url': ['browser', 'url', 'web', 'link'],
  'launch_app': ['app', 'launch', 'intent', 'open'],
  'vibrate': ['vibrate', 'haptic', 'vibration'],
  'get_clipboard': ['clipboard'],
  'set_clipboard': ['clipboard'],
  'toggle_flashlight': ['flashlight', 'torch', 'light', 'lamp'],
  'usb_list_devices': ['usb'],
  'usb_list_volumes': ['usb', 'storage', 'drive'],
  'usb_list_files': ['usb', 'storage', 'file', 'drive'],
  'usb_serial_list': ['usb', 'serial'],
  'canvas_create': ['document', 'canvas', 'note', 'write', 'page', 'report'],
  'canvas_update': ['document', 'canvas', 'note', 'edit', 'page', 'report'],
  'canvas_list': ['document', 'canvas', 'note', 'list', 'page'],
};

/// Minimum relevance for a tool to be included on its own merit.
const double _relevanceThreshold = 0.3;

/// Max tools to send to the model (protects small-model context).
const int _maxTools = 8;

/// Universal fallback tools: the model can always speak a response and
/// check device state. Used only when ranking yields almost nothing.
const List<String> _fallbackTools = ['speak_text', 'get_device_health'];

/// Filter [allTools] (phone tool names, already gated by the USB
/// settings) down to the subset relevant for [ranked] SystemOne results.
///
/// Strategy: include tools scoring >= threshold, union top 5 by
/// relevance (whichever gives more), cap at 8, ordered by score.
/// Guarantees at least 2 tools so the model is never tool-less.
List<String> filterToolsByRanking(
  List<String> allTools,
  List<RankedTool> ranked,
) {
  // Score per tool = best relevance among matching SystemOne entries.
  final scores = <String, double>{};
  for (final tool in allTools) {
    final concepts = _toolConcepts[tool] ?? const <String>[];
    var best = 0.0;
    for (final r in ranked) {
      final id = r.id.toLowerCase();
      for (final concept in concepts) {
        final kw = concept.toLowerCase();
        if (id.contains(kw) || kw.contains(id)) {
          if (r.relevance > best) best = r.relevance;
          break;
        }
      }
    }
    if (best > 0) scores[tool] = best;
  }

  final byThreshold = scores.entries
      .where((e) => e.value >= _relevanceThreshold)
      .map((e) => e.key)
      .toSet();
  final sorted = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final top5 = sorted.take(5).map((e) => e.key).toSet();

  final picked = <String>{...byThreshold, ...top5}.toList()
    ..sort((a, b) => (scores[b] ?? 0).compareTo(scores[a] ?? 0));
  final capped = picked.take(_maxTools).toList();
  if (capped.length >= 2) return capped;

  // Safety net: never leave the model tool-less.
  final out = <String>[...capped];
  for (final f in _fallbackTools) {
    if (out.length >= 2) break;
    if (allTools.contains(f) && !out.contains(f)) out.add(f);
  }
  return out;
}
