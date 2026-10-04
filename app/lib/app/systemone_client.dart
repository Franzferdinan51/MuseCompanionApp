// SystemOne client: asks SystemOne to rank which phone tools are relevant
// for a task, so the LM Studio integration can send a focused tool subset
// instead of all 18 tools every time.
//
// SystemOne runs on the Mac (default http://100.68.208.113:8765).
// POST /v1/systemone/route {"task": "..."} -> route.ranked_tools:
//   [{"id": "apple-events", "kind": "mcp", "relevance": 0.4}, ...]
//
// Fail-open design: any error (unreachable, bad JSON, timeout) returns an
// empty list, and the caller falls back to the full tool set. We never
// touch model routing here -- the configured LM Studio model is always
// used; SystemOne only narrows the TOOL list.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Per-request timeout for SystemOne routing.
const Duration _routeTimeout = Duration(seconds: 10);

/// A SystemOne-ranked tool: its ID in SystemOne's own vocabulary plus a
/// relevance score in 0.0-1.0.
class RankedTool {
  const RankedTool({required this.id, required this.relevance});

  final String id;
  final double relevance;
}

/// Thin client for SystemOne's /v1/systemone/route endpoint.
class SystemOneClient {
  SystemOneClient({required this.baseUrl});

  /// e.g. http://100.68.208.113:8765 (no trailing slash).
  final String baseUrl;

  Uri get _route => Uri.parse(
        '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/systemone/route',
      );

  /// Rank tools for [task]. Returns entries sorted by relevance
  /// descending. Returns [] on any error -- the caller falls back to
  /// the full tool set.
  Future<List<RankedTool>> rankTools(String task) async {
    try {
      final res = await http
          .post(
            _route,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'task': task}),
          )
          .timeout(_routeTimeout);
      if (res.statusCode != 200) {
        debugPrint(
          'SystemOne: HTTP ${res.statusCode}, falling back to all tools',
        );
        return const [];
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return const [];
      final route = decoded['route'];
      if (route is! Map) return const [];
      final ranked = route['ranked_tools'];
      if (ranked is! List) return const [];
      final tools = <RankedTool>[];
      for (final entry in ranked.whereType<Map>()) {
        final id = entry['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final rel = entry['relevance'];
        tools.add(
          RankedTool(
            id: id,
            relevance: rel is num ? rel.toDouble().clamp(0.0, 1.0) : 0.0,
          ),
        );
      }
      tools.sort((a, b) => b.relevance.compareTo(a.relevance));
      return tools;
    } catch (e) {
      debugPrint('SystemOne: route failed ($e), falling back to all tools');
      return const [];
    }
  }
}
