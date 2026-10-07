// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Offline scenes: named routines the agent or the user saves and runs.
//
// A scene is 1-10 command steps run in order through the normal command
// dispatch, stopping at the first failure — the same "stop on first
// failure" contract as the outbox flush. Scenes persist as JSON (atomic
// temp-file + rename) so they survive restarts, and they run fully
// offline: every step executes on the phone. The agent reaches scenes
// through the `scene.*` commands and the scene_* local tools.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Thrown for invalid scene definitions and missing scenes.
class SceneException implements Exception {
  SceneException(this.message);

  final String message;

  @override
  String toString() => 'SceneException: $message';
}

/// One step: a command plus its params, as the `scene.save` caller sends.
class SceneStep {
  const SceneStep({required this.command, this.params = const {}});

  final String command;
  final Map<String, Object?> params;

  Map<String, Object?> toJson() => {'command': command, 'params': params};

  static SceneStep fromJson(Map<String, Object?> json) {
    final command = json['command'];
    if (command is! String || command.isEmpty) {
      throw SceneException('scene step needs a command name');
    }
    final params = json['params'];
    return SceneStep(
      command: command,
      params: params is Map
          ? params.map((k, v) => MapEntry(k.toString(), v))
          : const {},
    );
  }
}

/// A saved routine: id, title, and 1-10 steps.
class Scene {
  const Scene({
    required this.id,
    required this.title,
    required this.steps,
  });

  final String id;
  final String title;
  final List<SceneStep> steps;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'steps': [for (final s in steps) s.toJson()],
  };

  static Scene fromJson(Map<String, Object?> json) {
    final steps = json['steps'];
    if (steps is! List || steps.isEmpty) {
      throw SceneException('scene needs 1-10 steps');
    }
    return Scene(
      id: (json['id']?.toString() ?? '').trim(),
      title: (json['title']?.toString() ?? '').trim(),
      steps: [
        for (final s in steps)
          if (s is Map) SceneStep.fromJson(s.cast<String, Object?>()),
      ],
    );
  }
}

/// Outcome of one executed step.
class SceneStepResult {
  const SceneStepResult({
    required this.command,
    required this.ok,
    this.detail = '',
  });

  final String command;
  final bool ok;
  final String detail;

  Map<String, Object?> toJson() => {
    'command': command,
    'ok': ok,
    'detail': detail,
  };
}

/// Outcome of [SceneStore.runScene].
class SceneRunResult {
  const SceneRunResult({
    required this.id,
    required this.steps,
    required this.completed,
  });

  final String id;
  final List<SceneStepResult> steps;
  final bool completed;

  Map<String, Object?> toJson() => {
    'id': id,
    'completed': completed,
    'steps': [for (final s in steps) s.toJson()],
  };
}

/// Persistent scene library. [runCommand] executes one step and reports
/// `{ok, payload}` like the command executor; the store stops the scene
/// at the first failing step.
class SceneStore {
  /// When [dir] is set, the documents directory is never touched
  /// (unit tests inject a temp dir).
  SceneStore({Directory? dir}) : _dirOverride = dir;

  final Directory? _dirOverride;

  /// Max steps per scene: long routines belong in scenes that call out
  /// to the agent, not in one uninterruptible run.
  static const int maxSteps = 10;

  static final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');

  final Map<String, Scene> _scenes = {};
  bool _loaded = false;

  Future<File> _file() async {
    final base = _dirOverride ?? await getApplicationDocumentsDirectory();
    return File('${base.path}/scenes.json');
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final scenes = decoded['scenes'];
      if (scenes is! List) return;
      for (final item in scenes) {
        if (item is! Map) continue;
        try {
          final scene = Scene.fromJson(item.cast<String, Object?>());
          _validate(scene);
          _scenes[scene.id] = scene;
        } catch (_) {
          // Skip corrupt scenes, keep the rest.
        }
      }
    } catch (_) {
      // A broken library must never break the caller.
    }
  }

  Future<void> _persist() async {
    final file = await _file();
    final tmp = File('${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'scenes': [for (final s in _scenes.values) s.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  static void _validate(Scene scene) {
    if (!_idPattern.hasMatch(scene.id)) {
      throw SceneException(
        'scene id must be 1-32 chars of a-z, 0-9, _ or -, starting '
        'alphanumeric: ${scene.id}',
      );
    }
    if (scene.title.isEmpty) throw SceneException('scene title is required');
    if (scene.steps.isEmpty || scene.steps.length > maxSteps) {
      throw SceneException('scene needs 1-$maxSteps steps');
    }
  }

  /// Save (or replace) a scene. Returns the stored id.
  Future<String> save(Scene scene) async {
    final normalized = Scene(
      id: scene.id.trim().toLowerCase(),
      title: scene.title.trim(),
      steps: scene.steps,
    );
    _validate(normalized);
    await _load();
    _scenes[normalized.id] = normalized;
    await _persist();
    return normalized.id;
  }

  /// All scenes, sorted by id.
  Future<List<Scene>> list() async {
    await _load();
    final scenes = _scenes.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return scenes;
  }

  /// The scene with [id], or null.
  Future<Scene?> get(String id) async {
    await _load();
    return _scenes[id.trim().toLowerCase()];
  }

  /// Delete [id]. Returns true when something was removed.
  Future<bool> delete(String id) async {
    await _load();
    final removed = _scenes.remove(id.trim().toLowerCase()) != null;
    if (removed) await _persist();
    return removed;
  }

  /// Run the scene with [id] through [runCommand], stopping at the
  /// first failing step. Throws [SceneException] for unknown ids.
  Future<SceneRunResult> runScene(
    String id,
    Future<Map<String, Object?>> Function(String command, Map<String, Object?> params)
    runCommand,
  ) async {
    final scene = await get(id);
    if (scene == null) throw SceneException('unknown scene: $id');
    final results = <SceneStepResult>[];
    for (final step in scene.steps) {
      var ok = false;
      var detail = '';
      try {
        final outcome = await runCommand(step.command, step.params);
        ok = outcome['ok'] == true;
        final payload = outcome['payload'];
        if (payload is Map && payload['error'] != null) {
          detail = payload['error'].toString();
        } else if (!ok) {
          detail = outcome.toString();
        }
      } catch (e) {
        detail = '$e';
      }
      results.add(SceneStepResult(command: step.command, ok: ok, detail: detail));
      if (!ok) break;
    }
    return SceneRunResult(
      id: scene.id,
      steps: results,
      completed: results.length == scene.steps.length &&
          results.every((r) => r.ok),
    );
  }
}
