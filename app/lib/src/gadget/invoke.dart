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
// One Muse command invocation, in the shapes the gadget link and Hatch
// have been seen to send. The ESP32 session answers `link.invoke`. Hatch's
// device channel has also used `device.invoke`, with the command nested
// under params. A missing or odd shape must still produce a result: a
// command the phone never answers looks like a timeout on the Muse side.

/// Methods that travel the control stream and are not commands.
const Set<String> _controlMethods = {
  'link.register',
  'link.heartbeat',
  'link.result',
  'link.ping',
};

/// A command the phone should run and answer with `link.result`.
class ParsedInvoke {
  const ParsedInvoke({
    required this.id,
    required this.command,
    required this.params,
    required this.timeoutMs,
    required this.replyType,
  });

  /// Original id (string or number) so the reply matches what the VM sent.
  final Object id;
  final String command;
  final Map<String, Object?> params;
  final int? timeoutMs;

  /// `res` when the request was a typed `req`, so the reply carries `type`.
  final String? replyType;
}

/// Returns the invoke inside [message], or null when it is some other
/// control message (register ack, heartbeat, unpair).
///
/// Hatch's device channel has used three shapes on the same socket:
/// `link.invoke` with a top-level command (the ESP32 session), `device.invoke`
/// with the command nested under params, and the command name itself as
/// `method` (for example `device.health`). A missing id cannot be answered.
ParsedInvoke? parseInvoke(Map<dynamic, dynamic> message) {
  final method = message['method']?.toString();
  final rawId = message['id'];
  if (rawId == null) return null;
  if (rawId is! String && rawId is! num) return null;
  if (rawId.toString().isEmpty) return null;
  final id = rawId is double ? rawId.round() : rawId;

  final wrapped = method == 'link.invoke' ||
      method == 'device.invoke' ||
      method == 'invoke';
  var command = message['command'];
  var params = message['params'];
  if (wrapped) {
    if (command is! String || command.isEmpty) {
      if (params is Map) {
        final nested = params['command'] ?? params['name'] ?? params['method'];
        if (nested is String && nested.isNotEmpty) {
          command = nested;
          final inner =
              params['params'] ?? params['args'] ?? params['arguments'];
          params = inner is Map ? inner : <String, Object?>{};
        }
      }
    }
  } else if (method != null &&
      method.contains('.') &&
      !_controlMethods.contains(method)) {
    command = method;
  } else {
    return null;
  }
  final name = command is String ? command : '';
  if (name.isEmpty && !wrapped) return null;
  final type = message['type']?.toString();
  return ParsedInvoke(
    id: id,
    command: name,
    params: _stringKeyMap(params),
    timeoutMs: _timeout(message['timeout_ms'] ?? message['timeout']),
    replyType: type == 'req' ? 'res' : null,
  );
}

Map<String, Object?> _stringKeyMap(Object? value) {
  if (value is! Map) return <String, Object?>{};
  return value.map((key, item) => MapEntry(key.toString(), item));
}

int? _timeout(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return null;
}
