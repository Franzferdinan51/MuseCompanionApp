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

import '../src/gadget/phone_actions.dart';
import 'canvas_store.dart';

/// Context passed to every tool handler.
class LmToolContext {
  const LmToolContext({
    required this.phone,
    required this.cameraFacing,
    this.speakAllowed = true,
    this.canvas,
    this.onCanvasDocument,
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
