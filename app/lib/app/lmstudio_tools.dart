// Local AI tool registry: the phone's capabilities exposed as
// OpenAI-style function-calling tools for a local model via LM Studio.
//
// Pattern (after nano-claw's tools/): each tool is a self-contained
// definition with name, description, JSON Schema, and a handler. Adding
// a tool means adding one entry to [_registry] — the client loop in
// lmstudio_client.dart never changes.
//
// The registry maps 1:1 onto the phone commands in commands.dart, so the
// local model gets the same capabilities Muse would have if
// device.invoke worked.

import 'dart:convert';

import '../src/gadget/phone_actions.dart';
import 'canvas_store.dart';
import 'choice_cards.dart';
import 'home_integrations.dart';
import 'media_queue.dart';
import 'scenes.dart';
import 'sensors_snapshot.dart';
import 'vision_analyze.dart';
import 'workspace_files.dart';

/// Context passed to every tool handler.
class LmToolContext {
  const LmToolContext({
    required this.phone,
    required this.cameraFacing,
    this.speakAllowed = true,
    this.canvas,
    this.onCanvasDocument,
    this.workspace,
    this.scenes,
    this.sensors,
    this.mediaQueue,
    this.cards,
    this.visionAnalyzer,
    this.homeConfig,
    this.mqttPublisher,
  });

  final PhoneActions phone;

  /// 'back' or 'front' -- default camera for take_photo.
  final String cameraFacing;

  /// False when the user turned off "Speak replies": speak_text must not
  /// produce audio. (2026-10-04: voice doomloop fix)
  final bool speakAllowed;

  /// Versioned document store for the canvas tools. Null when the canvas
  /// feature is unavailable (e.g. unit tests without a documents dir);
  /// the canvas tools then report an error instead of crashing.
  final CanvasStore? canvas;

  /// Called whenever a canvas tool creates or updates a document so the
  /// UI can surface a tappable card in chat. (docId, title, updated)
  final void Function(String docId, String title, bool updated)?
  onCanvasDocument;

  /// Sandboxed workspace file store for the file_* tools. Null falls back
  /// to the default documents location inside the handlers; tests inject
  /// a temp dir.
  final WorkspaceFiles? workspace;

  /// Saved offline routines for the scene_* tools. Same fallback rule.
  final SceneStore? scenes;

  /// One-shot sensor reader for sensors_read. Null reads real hardware;
  /// tests inject a fake sampler.
  final SensorReader? sensors;

  /// Audio playback queue for the media_* tools. Null plays through a
  /// real audio backend; tests inject a fake backend.
  final MediaQueuePlayer? mediaQueue;

  /// Interactive display cards for the display_* tools. Null uses the
  /// process-wide store the companion screen observes; tests inject an
  /// isolated store.
  final ChoiceCardStore? cards;

  /// On-device image analysis backend for vision_analyze. Null uses real
  /// ML Kit models; tests inject a fake.
  final VisionAnalyzerBackend? visionAnalyzer;

  /// Smart-home config loader (Settings plus secrets) for the home_* and
  /// mqtt_* tools. Null means unconfigured; tests inject a fixed config.
  final Future<HomeIntegrationConfig?> Function()? homeConfig;

  /// MQTT publish seam for mqtt_publish. Null connects to the real broker
  /// per publish; tests inject a recording fake.
  final MqttPublisher? mqttPublisher;
}

/// A tool handler: runs the tool, returns text for the model.
typedef LmToolHandler =
    Future<String> Function(Map<String, Object?> args, LmToolContext ctx);

/// A single function tool: OpenAI JSON + how to run it.
class LmTool {
  const LmTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.handler,
    this.requiresUsbStorage = false,
    this.requiresUsbSerial = false,
    this.requiresApproval = false,
  });

  final String name;
  final String description;

  /// JSON Schema for the tool's arguments.
  final Map<String, Object?> parameters;

  /// Runs the tool. Returns a string for the model (keep it small).
  final LmToolHandler handler;

  /// Only offer this tool when USB storage is enabled in Settings.
  final bool requiresUsbStorage;

  /// Only offer this tool when USB serial is enabled in Settings.
  final bool requiresUsbSerial;

  /// When true, the user must approve each call in a popup before it runs.
  final bool requiresApproval;

  Map<String, Object?> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

Map<String, Object?> _strParam(String description) => {
  'type': 'string',
  'description': description,
};

Map<String, Object?> _intParam(
  String description, {
  int? minimum,
  int? maximum,
}) {
  final param = <String, Object?>{
    'type': 'integer',
    'description': description,
  };
  if (minimum != null) param['minimum'] = minimum;
  if (maximum != null) param['maximum'] = maximum;
  return param;
}

Map<String, Object?> _boolParam(String description) => {
  'type': 'boolean',
  'description': description,
};

Map<String, Object?> _objectSchema(
  Map<String, Map<String, Object?>> properties, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

/// Run a phone command and stringify the result, capped for context.
Future<String> _run(
  LmToolContext ctx,
  String command,
  Map<String, Object?> args,
) async {
  final result = await ctx.phone.run(command, args);
  return _cap(result.toString());
}

/// Cap a tool result so it fits the model's context.
String _cap(String s, [int cap = 4000]) =>
    s.length <= cap ? s : '${s.substring(0, cap)}... [truncated]';

/// Parse a buttons_json array for display_show_card, or null when malformed.
List<CardButton>? _parseCardButtons(Object? raw) {
  if (raw == null) return const [];
  if (raw is! String || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return [
      for (final item in decoded)
        if (item is Map<String, Object?>)
          CardButton.fromJson(item)
        else if (item is Map)
          CardButton.fromJson(item.cast<String, Object?>()),
    ];
  } catch (_) {
    return null;
  }
}

/// A configured [HomeAssistant], or an error string when the
/// integration is off or missing its URL/token.
Future<Object> _homeAssistant(LmToolContext ctx) async {
  final config =
      await ctx.homeConfig?.call() ?? const HomeIntegrationConfig();
  if (!config.homeEnabled) {
    return 'error: Home Assistant is disabled in Companion Settings.';
  }
  if (config.homeBaseUrl.isEmpty || config.homeToken.isEmpty) {
    return 'error: Home Assistant is not set up: enter the base URL and '
        'token in Settings.';
  }
  return HomeAssistant(baseUrl: config.homeBaseUrl, token: config.homeToken);
}

/// Parse a data_json object for home_call. Null means malformed; absent
/// means no extra data.
Map<String, Object?>? _parseServiceData(Object? raw) {
  if (raw == null) return const {};
  if (raw is! String || raw.trim().isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return decoded.cast<String, Object?>();
    return null;
  } catch (_) {
    return null;
  }
}

/// Parse a steps_json array for scene_save, or null when malformed.
List<SceneStep>? _parseToolSteps(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.isEmpty) return null;
    return [
      for (final item in decoded)
        if (item is Map<String, Object?>)
          SceneStep.fromJson(item)
        else if (item is Map)
          SceneStep.fromJson(item.cast<String, Object?>()),
    ];
  } catch (_) {
    return null;
  }
}

/// Run one scene step through the phone bridge, shaped like an executor
/// outcome so [SceneStore.runScene] can judge it. A throw is a failure.
Future<Map<String, Object?>> _runMap(
  LmToolContext ctx,
  String command,
  Map<String, Object?> params,
) async {
  try {
    final result = await ctx.phone.run(command, params);
    return {'ok': true, 'payload': result};
  } catch (e) {
    return {
      'ok': false,
      'payload': {'error': '$e'},
    };
  }
}

/// The tool registry. To add a tool, add one entry here.
Map<String, LmTool> get _registry => {
  'take_photo': LmTool(
    name: 'take_photo',
    requiresApproval: true,
    description:
        'Take a photo with the phone camera. Returns confirmation with '
        'the photo size in bytes.',
    parameters: _objectSchema({
      'facing': _strParam('Camera to use: "back" or "front". Default "back".'),
    }),
    handler: (args, ctx) async {
      final facing =
          args['facing']?.toString() == 'front' ? 'front' : ctx.cameraFacing;
      final jpeg = await ctx.phone.captureJpeg(facing: facing);
      final kb = (jpeg.length / 1024).toStringAsFixed(1);
      return 'Photo captured with the $facing camera: ${jpeg.length} bytes '
          'JPEG ($kb KB). The image is not attached; describe that a photo '
          'was taken.';
    },
  ),
  'speak_text': LmTool(
    name: 'speak_text',
    description: 'Speak text aloud on the phone speaker using text-to-speech.',
    parameters: _objectSchema({
      'text': _strParam('Text to speak aloud.'),
    }, ['text']),
    handler: (args, ctx) async {
      final text = args['text']?.toString() ?? '';
      if (text.trim().isEmpty) return 'error: text is required';
      if (!ctx.speakAllowed) {
        return 'speech is disabled: the user turned off Speak replies';
      }
      await ctx.phone.speak(text);
      final shown = text.length > 80 ? '${text.substring(0, 80)}...' : text;
      return 'Speaking "$shown"';
    },
  ),
  'get_device_health': LmTool(
    name: 'get_device_health',
    description:
        'Report phone health: battery level percent, whether charging, '
        'device model, OS version, app version.',
    parameters: _objectSchema({}),
    handler: (args, ctx) => _run(ctx, 'device.health', {}),
  ),
  'get_location': LmTool(
    name: 'get_location',
    requiresApproval: true,
    description:
        'Get the phone\'s last known location: latitude, longitude, '
        'accuracy in meters. Requires location permission.',
    parameters: _objectSchema({}),
    handler: (args, ctx) => _run(ctx, 'phone.location', {}),
  ),
  'list_notifications': LmTool(
    name: 'list_notifications',
    requiresApproval: true,
    description: 'List recent notifications on the phone.',
    parameters: _objectSchema({}),
    handler: (args, ctx) => _run(ctx, 'phone.notifications', {}),
  ),
  'set_alarm': LmTool(
    name: 'set_alarm',
    requiresApproval: true,
    description: 'Set an alarm on the phone clock.',
    parameters: _objectSchema({
      'hour': _intParam('Hour 0-23.', minimum: 0, maximum: 23),
      'minute': _intParam('Minute 0-59.', minimum: 0, maximum: 59),
      'message': _strParam('Alarm label. Optional.'),
    }, ['hour', 'minute']),
    handler: (args, ctx) => _run(ctx, 'phone.alarm', args),
  ),
  'set_timer': LmTool(
    name: 'set_timer',
    requiresApproval: true,
    description: 'Start a countdown timer on the phone clock.',
    parameters: _objectSchema({
      'seconds': _intParam(
        'Length in seconds, 1 to 86400.',
        minimum: 1,
        maximum: 86400,
      ),
      'message': _strParam('Timer label. Optional.'),
    }, ['seconds']),
    handler: (args, ctx) => _run(ctx, 'phone.timer', args),
  ),
  'show_notification': LmTool(
    name: 'show_notification',
    requiresApproval: true,
    description: 'Show a notification on the phone.',
    parameters: _objectSchema({
      'title': _strParam('Notification title.'),
      'text': _strParam('Notification body.'),
    }, ['title', 'text']),
    handler: (args, ctx) => _run(ctx, 'phone.notify', args),
  ),
  'open_url': LmTool(
    name: 'open_url',
    requiresApproval: true,
    description: 'Open a URL on the phone (browser or handling app).',
    parameters: _objectSchema({
      'url': _strParam('http:// or https:// URL to open.'),
    }, ['url']),
    handler: (args, ctx) => _run(ctx, 'phone.open_url', args),
  ),
  'launch_app': LmTool(
    name: 'launch_app',
    requiresApproval: true,
    description:
        'Open an installed app by package name or app name, e.g. "maps".',
    parameters: _objectSchema({
      'name': _strParam('Package name or app name.'),
    }, ['name']),
    handler: (args, ctx) => _run(ctx, 'phone.launch_app', args),
  ),
  'vibrate': LmTool(
    name: 'vibrate',
    description: 'Vibrate the phone for a short time.',
    parameters: _objectSchema({
      'ms': _intParam(
        'Duration in milliseconds, 1 to 5000. Default 200.',
        minimum: 1,
        maximum: 5000,
      ),
    }),
    handler: (args, ctx) => _run(ctx, 'phone.vibrate', args),
  ),
  'get_clipboard': LmTool(
    name: 'get_clipboard',
    requiresApproval: true,
    description: 'Read the current phone clipboard text.',
    parameters: _objectSchema({}),
    handler: (args, ctx) =>
        _run(ctx, 'phone.clipboard', {'action': 'get'}),
  ),
  'set_clipboard': LmTool(
    name: 'set_clipboard',
    requiresApproval: true,
    description: 'Copy text to the phone clipboard.',
    parameters: _objectSchema({
      'text': _strParam('Text to copy to the clipboard.'),
    }, ['text']),
    handler: (args, ctx) => _run(
      ctx,
      'phone.clipboard',
      {'action': 'set', ...args},
    ),
  ),
  'toggle_flashlight': LmTool(
    name: 'toggle_flashlight',
    description: 'Turn the phone flashlight on or off.',
    parameters: _objectSchema({
      'on': _boolParam('True to turn the torch on, false to turn it off.'),
    }, ['on']),
    handler: (args, ctx) => _run(ctx, 'phone.flashlight', args),
  ),
  'usb_list_devices': LmTool(
    name: 'usb_list_devices',
    description:
        'List USB devices plugged into the phone over OTG: name, '
        'manufacturer, vendor/product ID, device class.',
    parameters: _objectSchema({}),
    handler: (args, ctx) => _run(ctx, 'usb.list_devices', {}),
    requiresUsbStorage: true,
  ),
  'usb_list_volumes': LmTool(
    name: 'usb_list_volumes',
    description:
        'List mounted USB storage volumes: path, label, total and free '
        'space. Use the path with usb_list_files.',
    parameters: _objectSchema({}),
    handler: (args, ctx) => _run(ctx, 'usb.list_volumes', {}),
    requiresUsbStorage: true,
  ),
  'usb_list_files': LmTool(
    name: 'usb_list_files',
    description: 'List files in a directory on USB storage.',
    parameters: _objectSchema({
      'path': _strParam(
        'Directory path from usb_list_volumes, e.g. /storage/1A2B-3C4D.',
      ),
    }, ['path']),
    handler: (args, ctx) => _run(ctx, 'usb.list_files', args),
    requiresUsbStorage: true,
  ),
  'usb_serial_list': LmTool(
    name: 'usb_serial_list',
    description:
        'List USB serial ports: device name, driver, vendor/product ID, '
        'whether permission is granted.',
    parameters: _objectSchema({}),
    handler: (args, ctx) => _run(ctx, 'usb.serial_list', {}),
    requiresUsbSerial: true,
  ),
  // --- Workspace files ---------------------------------------------------
  // Sandboxed agent storage beside the chat (notes, itineraries, data).
  // Pure Dart: the handlers call WorkspaceFiles directly instead of
  // PhoneBridge.run, which would forward to Kotlin and find nothing.
  'file_list': LmTool(
    name: 'file_list',
    description:
        'List files and folders in the agent workspace: name, type, '
        'size, modified time. Folders first. Omit path for the root.',
    parameters: _objectSchema({
      'path': _strParam('Folder inside the workspace, e.g. notes.'),
    }),
    handler: (args, ctx) async {
      final ws = ctx.workspace ?? WorkspaceFiles();
      try {
        final entries = await ws.list(args['path']?.toString() ?? '');
        if (entries.isEmpty) return 'Workspace is empty.';
        return entries
            .map(
              (e) =>
                  '${e.isDirectory ? '[dir]' : '[file]'} ${e.path} '
                  '(${e.sizeBytes} bytes)',
            )
            .join('\n');
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  'file_read': LmTool(
    name: 'file_read',
    description:
        'Read a workspace file as text (capped, truncated past the cap). '
        'Paths stay inside the workspace.',
    parameters: _objectSchema({
      'path': _strParam('Workspace file path, e.g. notes/todo.txt.'),
    }, ['path']),
    handler: (args, ctx) async {
      final ws = ctx.workspace ?? WorkspaceFiles();
      final path = args['path']?.toString().trim() ?? '';
      if (path.isEmpty) return 'error: path is required';
      try {
        return _cap(await ws.readText(path));
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  'file_write': LmTool(
    name: 'file_write',
    requiresApproval: true,
    description:
        'Write text to a workspace file (5MB cap), creating parent '
        'folders. Replaces the file; set append true to append.',
    parameters: _objectSchema({
      'path': _strParam('Workspace file path, e.g. notes/todo.txt.'),
      'content': _strParam('Text to store.'),
      'append': _boolParam('Append instead of replacing. Default false.'),
    }, ['path', 'content']),
    handler: (args, ctx) async {
      final ws = ctx.workspace ?? WorkspaceFiles();
      final path = args['path']?.toString().trim() ?? '';
      final content = args['content']?.toString() ?? '';
      if (path.isEmpty) return 'error: path is required';
      try {
        final size = await ws.writeText(
          path,
          content,
          append: args['append'] == true,
        );
        return 'Wrote $size bytes to $path.';
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  // --- Offline scenes ----------------------------------------------------
  // Named routines (1-10 command steps) saved on the phone and run on
  // request. scene_run executes each step as a phone command through the
  // normal bridge path and stops at the first failure.
  'scene_save': LmTool(
    name: 'scene_save',
    requiresApproval: true,
    description:
        'Save a named offline routine: 1-10 command steps the phone runs '
        'in order, stopping at the first failure. Run it later with '
        'scene_run. Steps cannot be other scene_* commands.',
    parameters: _objectSchema({
      'id': _strParam(
        'Scene id: 1-32 chars of a-z, 0-9, _ or -, e.g. movie-night.',
      ),
      'title': _strParam('Human title shown in the scene list.'),
      'steps_json': _strParam(
        'JSON array of steps, each {"command": "...", "params": {...}}.',
      ),
    }, ['id', 'steps_json']),
    handler: (args, ctx) async {
      final store = ctx.scenes ?? SceneStore();
      final id = args['id']?.toString().trim() ?? '';
      if (id.isEmpty) return 'error: id is required';
      final steps = _parseToolSteps(args['steps_json']);
      if (steps == null) {
        return 'error: steps_json must be a JSON array of '
            '{"command": ..., "params": {...}} steps';
      }
      if (steps.any((s) => s.command.startsWith('scene.'))) {
        return 'error: scenes cannot contain scene.* steps';
      }
      final title = args['title']?.toString().trim();
      try {
        final stored = await store.save(
          Scene(
            id: id,
            title: title == null || title.isEmpty ? id : title,
            steps: steps,
          ),
        );
        return 'Saved scene "$stored" with ${steps.length} steps.';
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  'scene_list': LmTool(
    name: 'scene_list',
    description: 'List saved offline routines: id, title, step count.',
    parameters: _objectSchema({}),
    handler: (args, ctx) async {
      final store = ctx.scenes ?? SceneStore();
      final scenes = await store.list();
      if (scenes.isEmpty) return 'No scenes saved yet.';
      return scenes
          .map((s) => '"${s.id}": ${s.title} (${s.steps.length} steps)')
          .join('\n');
    },
  ),
  'scene_run': LmTool(
    name: 'scene_run',
    requiresApproval: true,
    description:
        'Run a saved offline routine by id: its steps execute in order '
        'on the phone. Reports per-step results and completion.',
    parameters: _objectSchema({
      'id': _strParam('Scene id from scene_list.'),
    }, ['id']),
    handler: (args, ctx) async {
      final store = ctx.scenes ?? SceneStore();
      final id = args['id']?.toString().trim() ?? '';
      if (id.isEmpty) return 'error: id is required';
      try {
        final outcome = await store.runScene(
          id,
          (c, p) => _runMap(ctx, c, p),
        );
        final lines = outcome.steps
            .map((s) => '${s.ok ? 'ok' : 'FAILED'}: ${s.command}'
                '${s.detail.isEmpty ? '' : ' (${s.detail})'}')
            .join('\n');
        return 'Scene "${outcome.id}" '
            '${outcome.completed ? 'completed' : 'stopped early'}:\n$lines';
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  'scene_delete': LmTool(
    name: 'scene_delete',
    requiresApproval: true,
    description: 'Delete a saved offline routine.',
    parameters: _objectSchema({
      'id': _strParam('Scene id from scene_list.'),
    }, ['id']),
    handler: (args, ctx) async {
      final store = ctx.scenes ?? SceneStore();
      final id = args['id']?.toString().trim() ?? '';
      if (id.isEmpty) return 'error: id is required';
      final removed = await store.delete(id);
      return removed ? 'Deleted scene "$id".' : 'No scene "$id".';
    },
  ),
  'sensors_read': LmTool(
    name: 'sensors_read',
    description:
        'Take one-shot motion and magnetic-field readings: accelerometer '
        '(m/s^2 incl. gravity), gyroscope (rad/s), magnetometer '
        '(microtesla), plus per-sensor availability. Read-only.',
    parameters: _objectSchema({}),
    handler: (args, ctx) async {
      final reader = ctx.sensors ?? SensorReader();
      final snapshot = await reader.read();
      final available = snapshot['available'] as Map;
      final lines = [
        for (final name in ['accelerometer', 'gyroscope', 'magnetometer'])
          available[name] == true
              ? '$name: ${(snapshot[name] as List).join(', ')}'
              : '$name: unavailable',
      ];
      return lines.join('\n');
    },
  ),
  // --- Media queue -------------------------------------------------------
  // Audio playback queue on the phone speaker. Queue management is
  // silent; playing sound asks approval first.
  'media_enqueue': LmTool(
    name: 'media_enqueue',
    requiresApproval: true,
    description:
        'Queue an audio URL for playback on the phone speaker '
        '(http/https only).',
    parameters: _objectSchema({
      'url': _strParam('http(s) audio URL to queue.'),
      'title': _strParam('Track title for the queue listing.'),
      'next': _boolParam('Play right after the current track.'),
    }, ['url']),
    handler: (args, ctx) async {
      final player = ctx.mediaQueue ?? MediaQueuePlayer();
      final url = args['url']?.toString().trim() ?? '';
      if (url.isEmpty) return 'error: url is required';
      try {
        player.queue.add(
          MediaTrack(
            url: url,
            title: args['title']?.toString() ?? '',
          ),
          next: args['next'] == true,
        );
        return 'Queued (${player.queue.length} tracks).';
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  'media_queue': LmTool(
    name: 'media_queue',
    description: 'Show the audio playback queue and player state.',
    parameters: _objectSchema({}),
    handler: (args, ctx) async {
      final player = ctx.mediaQueue ?? MediaQueuePlayer();
      final status = player.status();
      final tracks = player.queue.tracks;
      if (tracks.isEmpty) return 'Queue is empty (${status['state']}).';
      final lines = [
        for (var i = 0; i < tracks.length; i++)
          '${i == player.queue.index ? '>' : ' '} $i: '
              '${tracks[i].title.isEmpty ? tracks[i].url : tracks[i].title}',
      ];
      return 'State: ${status['state']}\n${lines.join('\n')}';
    },
  ),
  'media_play': LmTool(
    name: 'media_play',
    requiresApproval: true,
    description: 'Play the audio queue from the current track or an index.',
    parameters: _objectSchema({
      'index': _intParam('Queue index to start from. Default current.'),
    }),
    handler: (args, ctx) async {
      final player = ctx.mediaQueue ?? MediaQueuePlayer();
      final raw = args['index'];
      final ok = await player.play(raw is num ? raw.toInt() : null);
      return ok ? 'Playing (${player.status()['state']}).' : 'error: ${player.lastError.isEmpty ? 'nothing to play' : player.lastError}';
    },
  ),
  'media_control': LmTool(
    name: 'media_control',
    requiresApproval: true,
    description: 'Control audio playback: pause, resume, stop, next, previous.',
    parameters: _objectSchema({
      'action': _strParam('"pause", "resume", "stop", "next" or "previous".'),
    }, ['action']),
    handler: (args, ctx) async {
      final player = ctx.mediaQueue ?? MediaQueuePlayer();
      switch (args['action']?.toString()) {
        case 'pause':
          return await player.pause() ? 'Paused.' : 'error: nothing playing';
        case 'resume':
          return await player.resume() ? 'Resumed.' : 'error: nothing paused';
        case 'stop':
          await player.stop();
          return 'Stopped.';
        case 'next':
          await player.next();
          return 'Next (${player.status()['state']}).';
        case 'previous':
          await player.previous();
          return 'Previous (${player.status()['state']}).';
      }
      return 'error: action must be pause, resume, stop, next or previous';
    },
  ),
  // --- Display cards -----------------------------------------------------
  // Interactive cards on the phone stage: the model shows one, the user
  // taps a button, the model reads the choice back with card_status.
  'display_show_card': LmTool(
    name: 'display_show_card',
    requiresApproval: true,
    description:
        'Show an interactive card on the phone stage: title, text, up to '
        '4 buttons. The user taps a button on the phone; read the choice '
        'back with display_card_status. Auto-dismisses after ttl_s.',
    parameters: _objectSchema({
      'title': _strParam('Card title.'),
      'text': _strParam('Card body text.'),
      'buttons_json': _strParam(
        'JSON array of buttons, each {"id": "...", "label": "..."}.',
      ),
      'ttl_s': _intParam(
        'Seconds before auto-dismiss. Default 60, max 3600.',
        minimum: 1,
        maximum: 3600,
      ),
    }, ['title']),
    handler: (args, ctx) async {
      final store = ctx.cards ?? ChoiceCardStore.instance;
      final title = args['title']?.toString().trim() ?? '';
      if (title.isEmpty) return 'error: title is required';
      final buttons = _parseCardButtons(args['buttons_json']);
      if (buttons == null) {
        return 'error: buttons_json must be a JSON array of '
            '{"id": ..., "label": ...} buttons';
      }
      final rawTtl = args['ttl_s'];
      try {
        final card = store.show(
          title: title,
          text: args['text']?.toString() ?? '',
          buttons: buttons,
          ttlSeconds: rawTtl is num ? rawTtl.toInt() : 60,
        );
        return 'Showing card "${card.id}" with ${buttons.length} buttons.';
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  'display_card_status': LmTool(
    name: 'display_card_status',
    description:
        'Report the current display card (if any) and the last recorded '
        'button choice.',
    parameters: _objectSchema({}),
    handler: (args, ctx) async {
      final store = ctx.cards ?? ChoiceCardStore.instance;
      final status = store.status();
      final card = status['card'] as Map?;
      final choice = status['last_choice'] as Map?;
      final lines = <String>[
        if (card == null)
          'No card showing.'
        else
          'Showing "${card['title']}" (${(card['buttons'] as List).length} buttons).',
        if (choice == null)
          'No choice recorded yet.'
        else
          'Last choice: button "${choice['button_id']}" '
              'on card "${choice['card_id']}".',
      ];
      return lines.join('\n');
    },
  ),
  'display_clear_card': LmTool(
    name: 'display_clear_card',
    description: 'Dismiss the current display card without recording a choice.',
    parameters: _objectSchema({}),
    handler: (args, ctx) async {
      final store = ctx.cards ?? ChoiceCardStore.instance;
      store.clear();
      return 'Card dismissed.';
    },
  ),
  'vision_analyze': LmTool(
    name: 'vision_analyze',
    description:
        'Read text (OCR) and barcodes from a workspace image, fully '
        'on-device — the image never leaves the phone. Store image bytes '
        'first with file_write encoding base64.',
    parameters: _objectSchema({
      'path': _strParam('Workspace image path, e.g. scans/receipt.jpg.'),
      'mode': _strParam('"text", "barcode" or "both" (default).'),
    }, ['path']),
    handler: (args, ctx) async {
      final path = args['path']?.toString().trim() ?? '';
      if (path.isEmpty) return 'error: path is required';
      try {
        final analysis = await analyzeWorkspaceImage(
          files: ctx.workspace ?? WorkspaceFiles(),
          relPath: path,
          mode: args['mode']?.toString() ?? 'both',
          backend: ctx.visionAnalyzer,
        );
        final lines = <String>[];
        if (analysis.text.isNotEmpty) {
          lines.add('Text:\n${_cap(analysis.text, 2000)}');
        }
        for (final code in analysis.barcodes) {
          lines.add('Barcode [${code.format}]: ${code.value}');
        }
        if (lines.isEmpty) return 'No text or barcodes found.';
        return lines.join('\n');
      } on VisionException catch (e) {
        return 'error: ${e.message}';
      } on WorkspaceException catch (e) {
        return 'error: ${e.message}';
      }
    },
  ),
  // --- Smart home --------------------------------------------------------
  // Home Assistant and MQTT. Both strictly opt-in via Companion Settings;
  // handlers refuse to run when disabled or unconfigured, and secrets
  // never appear in results.
  'home_status': LmTool(
    name: 'home_status',
    description:
        'Show smart-home integration status: whether Home Assistant and '
        'MQTT are enabled and configured. Secrets are never included.',
    parameters: _objectSchema({}),
    handler: (args, ctx) async {
      final config =
          await ctx.homeConfig?.call() ?? const HomeIntegrationConfig();
      final ha = config.status()['home_assistant'] as Map;
      final mqtt = config.status()['mqtt'] as Map;
      return 'Home Assistant: '
          '${ha['enabled'] == true ? 'enabled' : 'disabled'}'
          '${ha['configured'] == true ? ', configured (${ha['base_url']})' : ', not set up'}\n'
          'MQTT: '
          '${mqtt['enabled'] == true ? 'enabled' : 'disabled'}'
          '${mqtt['configured'] == true ? ', ${mqtt['host']}:${mqtt['port']} prefix ${mqtt['topic_prefix']}' : ', not set up'}';
    },
  ),
  'home_states': LmTool(
    name: 'home_states',
    requiresApproval: true,
    description:
        'Read Home Assistant entity states (capped list), or one entity '
        'with entity_id like light.kitchen. Reveals household state, so '
        'it asks approval.',
    parameters: _objectSchema({
      'entity_id': _strParam(
        'Entity id, e.g. light.kitchen. Omit to list states.',
      ),
    }),
    handler: (args, ctx) async {
      final api = await _homeAssistant(ctx);
      if (api is String) return api;
      final entity = args['entity_id']?.toString();
      try {
        final states = await (api as HomeAssistant).states(
          entity == null || entity.isEmpty ? null : entity,
        );
        return _cap(states.toString());
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  'home_call': LmTool(
    name: 'home_call',
    requiresApproval: true,
    description:
        'Call a Home Assistant service, e.g. domain light, service '
        'turn_on with entity_id light.kitchen. Drives the home.',
    parameters: _objectSchema({
      'domain': _strParam('Service domain, e.g. light.'),
      'service': _strParam('Service name, e.g. turn_on.'),
      'entity_id': _strParam('Target entity, e.g. light.kitchen.'),
      'data_json': _strParam(
        'Extra service data as a JSON object, e.g. {"brightness": 128}.',
      ),
    }, ['domain', 'service']),
    handler: (args, ctx) async {
      final api = await _homeAssistant(ctx);
      if (api is String) return api;
      final domain = args['domain']?.toString() ?? '';
      final service = args['service']?.toString() ?? '';
      if (domain.isEmpty) return 'error: domain is required';
      if (service.isEmpty) return 'error: service is required';
      final data = _parseServiceData(args['data_json']);
      if (data == null) return 'error: data_json must be a JSON object';
      try {
        final changed = await (api as HomeAssistant).callService(
          domain,
          service,
          entityId: args['entity_id']?.toString(),
          data: data,
        );
        return 'Service called: ${_cap(changed.toString(), 1000)}';
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  'mqtt_status': LmTool(
    name: 'mqtt_status',
    description:
        'Show MQTT status: enabled, broker host/port, topic prefix. '
        'Same payload as home_status.',
    parameters: _objectSchema({}),
    handler: (args, ctx) async {
      final config =
          await ctx.homeConfig?.call() ?? const HomeIntegrationConfig();
      final mqtt = config.status()['mqtt'] as Map;
      if (mqtt['enabled'] != true) return 'MQTT is disabled.';
      if (mqtt['configured'] != true) {
        return 'MQTT is enabled but the broker host is not set.';
      }
      return 'MQTT ${mqtt['host']}:${mqtt['port']} '
          'prefix ${mqtt['topic_prefix']}';
    },
  ),
  'mqtt_publish': LmTool(
    name: 'mqtt_publish',
    requiresApproval: true,
    description:
        'Publish a message to the MQTT broker under the configured '
        'topic prefix (default muse/). Absolute topics, wildcards and '
        'escapes are refused.',
    parameters: _objectSchema({
      'topic': _strParam('Topic under the prefix, e.g. desk/lamp/set.'),
      'message': _strParam('Message payload.'),
    }, ['topic', 'message']),
    handler: (args, ctx) async {
      final config =
          await ctx.homeConfig?.call() ?? const HomeIntegrationConfig();
      if (!config.mqttEnabled) return 'error: MQTT is disabled.';
      if (config.mqttHost.isEmpty) {
        return 'error: MQTT broker host is not set.';
      }
      final topic = args['topic']?.toString() ?? '';
      final message = args['message']?.toString() ?? '';
      if (topic.isEmpty) return 'error: topic is required';
      try {
        final full = resolveMqttTopic(config.mqttTopicPrefix, topic);
        await (ctx.mqttPublisher ?? RealMqttPublisher()).publish(
          host: config.mqttHost,
          port: config.mqttPort,
          username: config.mqttUsername,
          password: config.mqttPassword,
          topic: full,
          message: message,
        );
        return 'Published to $full.';
      } catch (e) {
        return 'error: $e';
      }
    },
  ),
  // --- Shared canvas ---------------------------------------------------
  // Documents the agent and the user share beside the chat. The user can
  // open them from a card in chat or the Canvas screen, read, edit and
  // keep them. Purely local: these tools never touch the phone hardware.
  'canvas_create': LmTool(
    name: 'canvas_create',
    description:
        'Create a document on the shared canvas: a panel beside the chat '
        'where the user can read, edit, preview and keep it. Use it for '
        'anything document-like: long writing, notes, plans, reports, '
        'code files, HTML/SVG pages or small web apps, tables. Keep the '
        'chat reply short and point to the canvas instead of pasting the '
        'whole thing into chat. HTML runs OFFLINE in a sandbox: put all '
        'CSS and JS inline in one self-contained file (no CDN scripts, '
        'external fonts/images, fetch or localStorage: they are blocked).',
    parameters: _objectSchema({
      'title': _strParam('Document title.'),
      'type': _strParam(
        'Content type: "markdown", "html", "code", "text" or "svg". '
        'Default "markdown".',
      ),
      'content': _strParam('Full document text.'),
      'lang': _strParam(
        'Programming language when type is "code", e.g. "python", '
        '"dart". Optional.',
      ),
    }, ['title', 'content']),
    handler: (args, ctx) async {
      final store = ctx.canvas;
      if (store == null) return 'error: canvas is not available';
      final title = args['title']?.toString().trim() ?? '';
      if (title.isEmpty) return 'error: title is required';
      final content = args['content']?.toString() ?? '';
      try {
        final doc = await store.create(
          title: title,
          type: CanvasDocType.fromName(args['type']?.toString()),
          content: content,
          lang: args['lang']?.toString().trim() ?? '',
          by: 'agent',
          note: 'created',
        );
        ctx.onCanvasDocument?.call(doc.id, doc.title, false);
        return 'Created canvas document "${doc.title}" '
            '(id: ${doc.id}, type: ${doc.type.name}). '
            'Tell the user it is on their canvas.';
      } on CanvasStoreException catch (e) {
        return 'error: ${e.message}';
      }
    },
  ),
  'canvas_update': LmTool(
    name: 'canvas_update',
    description:
        'Replace a canvas document\'s whole content (creates a new '
        'version; the old one stays in history). Call canvas_list first '
        'if you do not know the document id.',
    parameters: _objectSchema({
      'id': _strParam('Document id (from canvas_create or canvas_list).'),
      'content': _strParam('Full replacement text.'),
      'note': _strParam(
        'Short note for the version history, e.g. "added section 3". '
        'Optional.',
      ),
    }, ['id', 'content']),
    handler: (args, ctx) async {
      final store = ctx.canvas;
      if (store == null) return 'error: canvas is not available';
      final id = args['id']?.toString().trim() ?? '';
      if (id.isEmpty) return 'error: id is required';
      try {
        final doc = await store.update(
          id,
          content: args['content']?.toString() ?? '',
          by: 'agent',
          note: args['note']?.toString().trim() ?? '',
        );
        ctx.onCanvasDocument?.call(doc.id, doc.title, true);
        return 'Updated canvas document "${doc.title}" '
            '(now revision ${doc.rev}). '
            'Tell the user it is on their canvas.';
      } on CanvasStoreException catch (e) {
        return 'error: ${e.message}';
      }
    },
  ),
  'canvas_list': LmTool(
    name: 'canvas_list',
    description:
        'List the documents on the shared canvas: id, title, type and '
        'revision. Use before canvas_update when you need an id.',
    parameters: _objectSchema({}),
    handler: (args, ctx) async {
      final store = ctx.canvas;
      if (store == null) return 'error: canvas is not available';
      final docs = await store.list();
      if (docs.isEmpty) return 'The canvas is empty.';
      final lines = docs.map(
        (d) =>
            '- "${d.title}" (id: ${d.id}, type: ${d.type.name}, '
            'rev ${d.rev})',
      );
      return _cap(lines.join('\n'));
    },
  ),
};

/// Phone tools as [LmTool] objects, filtered by the USB settings gates.
List<LmTool> lmToolsListFor({
  required bool usbStorageEnabled,
  required bool usbSerialEnabled,
}) {
  return [
    for (final tool in _registry.values)
      if (!(tool.requiresUsbStorage && !usbStorageEnabled) &&
          !(tool.requiresUsbSerial && !usbSerialEnabled))
        tool,
  ];
}

/// Tools to send to the model, filtered by the USB settings gates.
/// Returns clean OpenAI tool JSON.
List<Map<String, Object?>> lmToolsFor({
  required bool usbStorageEnabled,
  required bool usbSerialEnabled,
}) {
  return [
    for (final tool in lmToolsListFor(
      usbStorageEnabled: usbStorageEnabled,
      usbSerialEnabled: usbSerialEnabled,
    ))
      tool.toJson(),
  ];
}

/// Look up a tool handler by name. Null when unknown.
LmTool? lmToolNamed(String name) => _registry[name];
