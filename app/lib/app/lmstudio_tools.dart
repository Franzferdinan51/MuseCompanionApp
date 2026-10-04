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

/// Context passed to every tool handler.
class LmToolContext {
  const LmToolContext({
    required this.phone,
    required this.cameraFacing,
  });

  final PhoneActions phone;

  /// 'back' or 'front' — default camera for take_photo.
  final String cameraFacing;
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
