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
// Dart port of the Muse Gadget SDK link client
// (linux/src/musegadget/link_client.py).
//
// One control session with a Muse VM. Opens a WebSocket to `/v1/noise`
// with the per-VM credential in an Authorization header, runs the Noise XX
// handshake, then opens a long-lived `POST /link-control` stream. Both
// directions of that stream carry JSON messages, each prefixed with its
// length as a little-endian u32:
//   * device -> VM: `link.register` (capabilities), then `link.result`;
//   * VM -> device: the register reply, `link.invoke` requests, and events
//     such as `link.unpaired`.
// Messages the device sends to the Muse ([LinkSession.sendChat]) go as
// separate `POST /chat/stream` requests on the same session. Assistant
// replies are not in that response: they arrive as NDJSON on a long-lived
// `POST /chat/subscribe` stream opened after `link.register` succeeds.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'chat_events.dart';
import 'envelope.dart';
import 'noise_xx.dart';
import 'transport.dart';

const String noisePath = '/v1/noise';
const String controlPath = '/link-control';
const String chatPath = '/chat/stream';
const String identityPath = '/identity';
const String appId = 'musegadget';
const Duration requestTimeout = Duration(seconds: 60);
const int maxResponseBytes = 1024 * 1024;
const Duration handshakeTimeout = Duration(seconds: 20);
const Duration pingInterval = Duration(seconds: 20);
const int maxConcurrentInvokes = 4;
const int maxInboundMessage = 4 * 1024 * 1024;

// Matches JavaScript's encodeURIComponent, as the firmware does.
const String _uriComponentSafe = "-_.!~*'()";

/// How a link session ended.
enum Outcome {
  /// Connection ended; reconnect normally.
  closed,

  /// Edge refused the VM bearer; re-fetch VMs.
  authRejected,

  /// Authenticated but not allowed right now.
  forbidden,

  /// The Muse removed this device.
  unpaired,
  stopped,
}

typedef RunCommand = Future<Map<String, Object?>> Function(
    String command, Map<String, Object?> params, int? timeoutMs);

class DeviceDescription {
  const DeviceDescription({
    required this.nodeId,
    required this.displayName,
    required this.version,
    required this.commands,
    this.platform = 'android',
    this.deviceFamily = 'companion',
    this.modelId = 'companion-app',
  });

  final String nodeId;
  final String displayName;
  final String version;
  final Map<String, Object?> commands;
  final String platform;
  final String deviceFamily;
  final String modelId;

  Map<String, Object?> registerParams() => {
        'node_id': nodeId,
        'display_name': displayName,
        'platform': platform,
        'version': version,
        'device_family': deviceFamily,
        'model_id': modelId,
        'is_wakeup_supported': false,
        'commands_v2': commands,
      };
}

Uint8List encodeMessage(Map<String, Object?> obj) {
  final data = utf8.encode(json.encode(obj));
  final out = Uint8List(4 + data.length);
  ByteData.sublistView(out).setUint32(0, data.length, Endian.little);
  out.setRange(4, out.length, data);
  return out;
}

/// Splits the control stream into length-prefixed JSON messages.
///
/// A message may span body chunks, so bytes are buffered until complete.
class MessageDecoder {
  final List<int> _bytes = [];

  List<Map<String, Object?>> feed(Uint8List data) {
    _bytes.addAll(data);
    final messages = <Map<String, Object?>>[];
    while (_bytes.length >= 4) {
      final length = _bytes[0] |
          (_bytes[1] << 8) |
          (_bytes[2] << 16) |
          (_bytes[3] << 24);
      if (length < 0 || length > maxInboundMessage) {
        throw ArgumentError('inbound message too large: $length');
      }
      if (_bytes.length < 4 + length) {
        break;
      }
      final raw = Uint8List.fromList(_bytes.sublist(4, 4 + length));
      _bytes.removeRange(0, 4 + length);
      if (raw.isEmpty) {
        continue; // keepalive
      }
      try {
        final message = json.decode(utf8.decode(raw));
        if (message is Map<String, Object?>) {
          messages.add(message);
        } else if (message is Map) {
          messages.add(message.cast<String, Object?>());
        }
      } on FormatException {
        // Drop malformed control messages, as the reference does.
        continue;
      }
    }
    return messages;
  }
}

String noiseUrl(String noiseHost, String vmId) {
  final encoded = Uri.encodeComponent(vmId);
  // Uri.encodeComponent leaves "-_.!~*'()" unescaped already, matching
  // encodeURIComponent; keep the constant for documentation.
  assert(_uriComponentSafe.isNotEmpty);
  return 'wss://$noiseHost$noisePath?vm_id=$encoded';
}

/// Minimal WebSocket surface a [LinkSession] needs; injectable for tests.
abstract class LinkSocket {
  Future<void> send(Uint8List data);
  Stream<Uint8List> get stream;
  Future<void> close();
}

class _IoLinkSocket implements LinkSocket {
  _IoLinkSocket(this._socket);
  final WebSocket _socket;

  @override
  Future<void> send(Uint8List data) async {
    _socket.add(data);
  }

  @override
  Stream<Uint8List> get stream => _socket
      .where((event) => event is List<int>)
      .map((event) => Uint8List.fromList(event as List<int>));

  @override
  Future<void> close() => _socket.close();
}

typedef LinkConnector = Future<LinkSocket> Function(
    String url, Map<String, String> headers, String userAgent);

class _UpgradeRejected implements Exception {
  const _UpgradeRejected(this.status);
  final int status;
}

class _Request {
  _Request() : done = Completer<(int, Uint8List)>();

  final Completer<(int, Uint8List)> done;
  int status = 0;
  final BytesBuilder body = BytesBuilder();
  int bodyLength = 0;

  /// When set, chunks are delivered as they arrive instead of being
  /// buffered until the stream ends. Used by `/chat/subscribe`.
  void Function(int status, Uint8List data, bool ended)? onChunk;

  void onFrame(DecryptedFrame frame) {
    if (done.isCompleted) return;
    if (frame.kind == DecryptedFrameKind.reset) {
      done.completeError(
          StateError('stream reset: ${frame.reset?.reason ?? ''}'));
      return;
    }
    Uint8List data;
    bool ended;
    if (frame.kind == DecryptedFrameKind.response) {
      final response = frame.response!;
      status = response.status;
      data = response.body ?? Uint8List(0);
      ended = response.endBody;
    } else {
      final chunk = frame.bodyChunk!;
      data = chunk.data ?? Uint8List(0);
      ended = chunk.endBody;
    }
    final chunkHandler = onChunk;
    if (chunkHandler != null) {
      chunkHandler(status, data, ended);
      if (ended) done.complete((status, Uint8List(0)));
      return;
    }
    body.add(data);
    bodyLength += data.length;
    if (bodyLength > maxResponseBytes) {
      done.completeError(ArgumentError('response too large'));
    } else if (ended) {
      done.complete((status, body.toBytes()));
    }
  }
}

class LinkSession {
  LinkSession({
    required String noiseHost,
    required String vmId,
    required String vmAuthToken,
    required DeviceDescription device,
    required RunCommand runCommand,
    required String userAgent,
    LinkConnector? connect,
  })  : _url = noiseUrl(noiseHost, vmId),
        _token = vmAuthToken,
        _device = device,
        _runCommand = runCommand,
        _userAgent = userAgent,
        _connect = connect;

  final String _url;
  final String _token;
  final DeviceDescription _device;
  final RunCommand _runCommand;
  final String _userAgent;
  final LinkConnector? _connect;

  LinkSocket? _socket;
  NoiseTransport? _transport;
  Future<void> _sendTail = Future.value();
  int _inflightInvokes = 0;
  final List<Completer<void>> _invokeWaiters = [];
  final Set<Future<void>> _tasks = {};
  int _streamId = 0;
  String _registerId = '';
  final Map<int, _Request> _requests = {};
  DateTime? registeredAt;

  /// The agent (Muse) display name, once the identity fetch returns it.
  String? agentName;

  /// Progress/status callback for UI and diagnostics (best effort).
  void Function(String status)? onStatus;

  /// Called once the VM accepts `link.register`.
  void Function()? onRegistered;

  /// Called once the reply subscription has been written to the socket,
  /// so a following chat post is not missed.
  void Function()? onSubscribed;

  /// Fires for each assistant event on `/chat/subscribe`.
  void Function(ChatEvent event)? onChatEvent;

  /// Fires with the decoded `GET /identity` result object.
  void Function(Map<String, Object?> result)? onIdentity;

  int _subscribeAttempts = 0;
  bool _subscribeOpen = false;
  bool _alive = true;

  Future<Outcome> run(Future<void> Function()? waitForStop) async {
    late final LinkSocket socket;
    try {
      socket = await _open();
    } on _UpgradeRejected catch (rejected) {
      return rejected.status == 401 ? Outcome.authRejected : Outcome.forbidden;
    }
    _socket = socket;
    // One subscription for the session lifetime: handshake and read loop
    // share it so no frame is dropped between them.
    final incoming = StreamIterator(socket.stream);
    try {
      _transport =
          await _handshake(socket, incoming).timeout(handshakeTimeout);
      await _openControlStream();
      _requestIdentity();
      if (waitForStop == null) {
        return await _readLoop(incoming);
      }
      var stopNotified = false;
      final stopFuture = waitForStop().then((_) {
        stopNotified = true;
      });
      final readFuture = _readLoop(incoming);
      await Future.any([readFuture, stopFuture]);
      if (stopNotified) {
        return Outcome.stopped;
      }
      return await readFuture;
    } finally {
      _alive = false;
      for (final request in _requests.values) {
        if (!request.done.isCompleted) {
          request.done.completeError(StateError('session ended'));
        }
      }
      _requests.clear();
      // Close first so a pending moveNext in the read loop completes,
      // then release the subscription.
      await socket.close();
      await incoming.cancel();
    }
  }

  Future<LinkSocket> _open() async {
    final connect = _connect;
    final headers = {'Authorization': 'Bearer $_token'};
    if (connect != null) {
      return connect(_url, headers, _userAgent);
    }
    try {
      final socket = await WebSocket.connect(
        _url,
        headers: headers,
        protocols: null,
      ).timeout(handshakeTimeout);
      socket.pingInterval = pingInterval;
      // Note: dart:io sets its own User-Agent; the reference sets a custom
      // one. Headers beyond Authorization are best-effort here.
      return _IoLinkSocket(socket);
    } on WebSocketException catch (e) {
      final status = _httpStatusFrom(e.message);
      if (status != null && (status == 401 || status == 403)) {
        throw _UpgradeRejected(status);
      }
      rethrow;
    }
  }

  static int? _httpStatusFrom(String message) {
    final match = RegExp(r'(\d{3})').firstMatch(message);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  Future<NoiseTransport> _handshake(
      LinkSocket socket, StreamIterator<Uint8List> incoming) async {
    final initiator = NoiseXXInitiator();
    await initiator.initialize();
    await socket.send(await initiator.writeMessage1());
    if (!await incoming.moveNext()) {
      throw StateError('connection closed during handshake');
    }
    final msg2 = incoming.current;
    await initiator.readMessage2(msg2);
    // The Authorization header authenticated us at upgrade; message 3
    // carries an empty payload.
    await socket.send(await initiator.writeMessage3());
    final (send, recv) = await initiator.split();
    return NoiseTransport(send: send, recv: recv);
  }

  Future<void> _openControlStream() async {
    final transport = _transport!;
    final encrypted = await transport.startStreamRequest('POST', controlPath);
    _streamId = encrypted.streamId;
    await _sendFrames(encrypted.frames);
    _registerId = newUuid();
    await send({
      'type': 'req',
      'id': _registerId,
      'method': 'link.register',
      'params': _device.registerParams(),
    });
    onStatus?.call('registered');
  }

  /// Ask the daemon for the agent identity (PGA display name).
  void _requestIdentity() {
    () async {
      try {
        final transport = _transport!;
        final encrypted =
            await transport.encryptHttpRequest('GET', identityPath);
        final request = _Request();
        _requests[encrypted.streamId] = request;
        try {
          await _sendFrames(encrypted.frames);
          final (status, response) =
              await request.done.future.timeout(requestTimeout);
          if (status == 200 && response.isNotEmpty) {
            final decoded = json.decode(utf8.decode(response));
            final result = decoded is Map ? decoded['result'] : null;
            if (result is Map) {
              final cast = result.cast<String, Object?>();
              final name = cast['name'];
              if (name is String && name.isNotEmpty) {
                agentName = name;
                onStatus?.call('identity:$name');
              }
              onIdentity?.call(cast);
            }
          }
        } finally {
          _requests.remove(encrypted.streamId);
        }
      } catch (_) {
        // Identity is best-effort; the session works without it.
      }
    }();
  }

  /// Post a user message to the Muse as coming from this device.
  ///
  /// [sessionId] targets a side chat; an id the Muse has not seen before
  /// starts a new one. Without it the message goes to the main chat.
  /// [attachments] are voice notes or camera frames. The HTTP body is only
  /// an acknowledgement; the reply arrives through [onChatEvent].
  Future<Map<String, Object?>> sendChat(String message,
      [String? sessionId, List<ChatAttachment> attachments = const []]) async {
    final transport = _transport;
    if (transport == null) {
      return {'ok': false, 'error': 'not connected to the Muse'};
    }
    if (message.trim().isEmpty && attachments.isEmpty) {
      return {'ok': false, 'error': 'message is empty'};
    }
    // Note: no registered gate here; the service layer refuses chats
    // until the VM accepts link.register (mirroring the reference).
    try {
      final requestBody = buildChatRequest(
        message: message,
        deviceId: _device.nodeId,
        sessionId: sessionId,
        attachments: attachments,
      );
      final body = Uint8List.fromList(utf8.encode(json.encode(requestBody)));
      final headers = [
        const Header('Content-Type', 'application/json'),
        Header('x-request-id', newUuid()),
        const Header('x-app-id', appId),
      ];
      final encrypted = await transport.encryptHttpRequest('POST', chatPath,
          body: body, headers: headers);
      final request = _Request();
      _requests[encrypted.streamId] = request;
      try {
        await _sendFrames(encrypted.frames);
        final (status, response) =
            await request.done.future.timeout(requestTimeout);
        Object? decoded;
        if (response.isNotEmpty) {
          try {
            decoded = json.decode(utf8.decode(response));
          } on FormatException {
            decoded = utf8.decode(response, allowMalformed: true);
            if ((decoded as String).length > 2000) {
              decoded = decoded.substring(0, 2000);
            }
          }
        }
        return {
          'ok': status >= 200 && status < 300,
          'status': status,
          'response': decoded
        };
      } finally {
        _requests.remove(encrypted.streamId);
      }
    } catch (e) {
      // The session ended mid-request (close, reset, timeout).
      return {'ok': false, 'error': '$e'};
    }
  }

  Future<void> send(Map<String, Object?> message) async {
    final transport = _transport!;
    final frames =
        await transport.encryptBodyChunk(_streamId, encodeMessage(message));
    await _sendFrames(frames);
  }

  Future<void> _sendFrames(List<Uint8List> frames) {
    final next = _sendTail.then((_) async {
      final socket = _socket;
      if (socket == null) throw StateError('session ended');
      for (final frame in frames) {
        await socket.send(frame);
      }
    });
    _sendTail = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<Outcome> _readLoop(StreamIterator<Uint8List> incoming) async {
    final decoder = MessageDecoder();
    final transport = _transport!;
    while (await incoming.moveNext()) {
      final raw = incoming.current;
      DecryptedFrame? frame;
      try {
        frame = await transport.decryptFrame(raw);
      } catch (_) {
        return Outcome.closed;
      }
      if (frame == null) {
        continue;
      }
      if (frame.streamId != _streamId) {
        _requests[frame.streamId]?.onFrame(frame);
        continue;
      }
      if (frame.kind == DecryptedFrameKind.reset) {
        return Outcome.closed;
      }
      Uint8List data;
      bool ended;
      if (frame.kind == DecryptedFrameKind.response) {
        final response = frame.response!;
        if (response.status >= 400) {
          return response.status == 403 ? Outcome.forbidden : Outcome.closed;
        }
        data = response.body ?? Uint8List(0);
        ended = response.endBody;
      } else {
        final chunk = frame.bodyChunk!;
        data = chunk.data ?? Uint8List(0);
        ended = chunk.endBody;
      }
      List<Map<String, Object?>> messages;
      try {
        messages = decoder.feed(data);
      } on ArgumentError {
        return Outcome.closed;
      }
      for (final message in messages) {
        final outcome = _handle(message);
        if (outcome != null) {
          return outcome;
        }
      }
      // Yield so invokes and timers run while frames stream in.
      await Future<void>.delayed(Duration.zero);
      if (ended) {
        return Outcome.closed;
      }
    }
    return Outcome.closed;
  }

  Outcome? _handle(Map<String, Object?> message) {
    if (message['id'] == _registerId && message['method'] == null) {
      if (message['error'] == null) {
        registeredAt = DateTime.now();
        onRegistered?.call();
        final task = _openChatSubscription();
        _tasks.add(task);
        task.whenComplete(() => _tasks.remove(task));
      }
      return null;
    }
    final event = message['event'];
    if (event == 'link.unpaired' || event == 'node.unpaired') {
      return Outcome.unpaired;
    }
    if (message['method'] == 'link.invoke') {
      final task = _invoke(message);
      _tasks.add(task);
      task.whenComplete(() => _tasks.remove(task));
    }
    return null;
  }

  Future<void> _invoke(Map<String, Object?> message) async {
    final invokeId = message['id'];
    if (invokeId is! String || invokeId.isEmpty) return;
    final command = message['command'];
    final params = message['params'];
    final timeoutMs = message['timeout_ms'];
    await _acquireInvokeSlot();
    Map<String, Object?> result;
    try {
      result = await _runCommand(
        command is String ? command : '',
        params is Map ? params.cast<String, Object?>() : <String, Object?>{},
        timeoutMs is int ? timeoutMs : null,
      );
    } finally {
      _releaseInvokeSlot();
    }
    try {
      await send({'method': 'link.result', 'id': invokeId, ...result});
    } catch (_) {
      // The session is gone; nothing left to report to.
    }
  }

  /// Long-lived reply stream. Opened after register so events that follow
  /// the intro message are not missed. Failures are reported and retried
  /// a few times; command serving does not depend on it.
  Future<void> _openChatSubscription() async {
    if (_subscribeOpen || _transport == null || _socket == null) return;
    if (_subscribeAttempts >= 3) return;
    _subscribeAttempts += 1;
    final transport = _transport!;
    final body = Uint8List.fromList(utf8.encode('{}'));
    final headers = [
      const Header('Content-Type', 'application/json'),
      const Header('Accept', 'application/x-ndjson'),
      Header('x-request-id', newUuid()),
      const Header('x-app-id', appId),
    ];
    final encrypted = await transport.encryptHttpRequest(
        'POST', chatSubscribePath,
        body: body, headers: headers);
    final request = _Request();
    final decoder = NdjsonEventDecoder();
    request.onChunk = (status, data, ended) {
      if (status >= 400) {
        onStatus?.call('subscribe:$status');
        return;
      }
      if (data.isNotEmpty) {
        try {
          for (final event in decoder.add(data)) {
            onChatEvent?.call(event);
          }
        } on StateError catch (e) {
          onStatus?.call('subscribe:$e');
        }
      }
      if (ended) {
        for (final event in decoder.flush()) {
          onChatEvent?.call(event);
        }
        _subscribeOpen = false;
      }
    };
    _requests[encrypted.streamId] = request;
    _subscribeOpen = true;
    var announced = false;
    try {
      await _sendFrames(encrypted.frames);
      onStatus?.call('subscribed');
      announced = true;
      onSubscribed?.call();
      await request.done.future;
    } catch (e) {
      onStatus?.call('subscribe ended: $e');
    } finally {
      _requests.remove(encrypted.streamId);
      _subscribeOpen = false;
    }
    if (!announced && _subscribeAttempts >= 3) {
      onSubscribed?.call();
    }
    if (_alive && registeredAt != null && _subscribeAttempts < 3) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_alive && registeredAt != null) {
        await _openChatSubscription();
      }
    }
  }

  Future<void> _acquireInvokeSlot() async {
    if (_inflightInvokes < maxConcurrentInvokes) {
      _inflightInvokes += 1;
      return;
    }
    final waiter = Completer<void>();
    _invokeWaiters.add(waiter);
    await waiter.future;
  }

  void _releaseInvokeSlot() {
    if (_invokeWaiters.isNotEmpty) {
      _invokeWaiters.removeAt(0).complete();
    } else {
      _inflightInvokes -= 1;
    }
  }
}

final Random _secureRandom = Random.secure();

String newUuid() {
  final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
