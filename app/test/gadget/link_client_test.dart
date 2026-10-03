import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/chat_events.dart';
import 'package:muse_companion/src/gadget/envelope.dart';
import 'package:muse_companion/src/gadget/framing.dart';
import 'package:muse_companion/src/gadget/link_client.dart';
import 'package:muse_companion/src/gadget/noise_xx.dart';
import 'package:muse_companion/src/gadget/transport.dart';

final _device = DeviceDescription(
  nodeId: 'homelink-abcdef',
  displayName: 'companion',
  version: '0.1.0',
  commands: {
    'companion.set_status': {
      'description': 'set status',
      'required': {},
      'optional': {},
    },
  },
);

/// One end of an in-memory socket pair.
class _Pipe implements LinkSocket {
  _Pipe(this._inbox, this._outbox);

  final StreamController<Uint8List> _inbox;
  final StreamController<Uint8List> _outbox;

  @override
  Future<void> send(Uint8List data) async {
    _outbox.add(data);
  }

  @override
  Stream<Uint8List> get stream => _inbox.stream;

  @override
  Future<void> close() async {
    await _outbox.close();
  }
}

/// Just enough of the Muse VM: Noise responder plus the control stream.
///
/// A background reader decrypts every frame, answers agent-identity
/// requests immediately, and queues everything else for [nextFrame], so
/// tests never race the device's identity fetch.
class _FakeVm {
  _FakeVm(this._socket)
      : _incoming = StreamIterator(_socket.stream);

  final LinkSocket _socket;
  final StreamIterator<Uint8List> _incoming;
  final NoiseFrameDecoder _decoder = NoiseFrameDecoder();
  final MessageDecoder _messages = MessageDecoder();
  // Explicit queue (not a stream): idle StreamIterators pause their
  // subscription, which deadlocks StreamController.close().
  final List<ServiceFrame> _frameQueue = [];
  Completer<void>? _frameWaiter;
  bool _queueClosed = false;
  late CipherState _send;
  late CipherState _recv;
  int streamId = 0;

  Future<void> handshake() async {
    final responder = NoiseXXResponder();
    await responder.initialize();
    await _incoming.moveNext();
    final msg2 =
        await responder.readMessage1AndWriteMessage2(_incoming.current);
    await _socket.send(msg2);
    await _incoming.moveNext();
    await responder.readMessage3(_incoming.current);
    final (send, recv) = await responder.split();
    _send = send;
    _recv = recv;
    _startReader();
  }

  void _startReader() {
    () async {
      try {
        while (await _incoming.moveNext()) {
          final plain = await _recv.decryptWithAd(
              Uint8List(0), _incoming.current);
          final assembled = _decoder.decode(plain);
          if (assembled == null) continue;
          final frame = decodeRequestEnvelope(assembled);
          if (frame.kind == ServiceFrameKind.request) {
            final path = (frame.value! as ApplicationRequest).path;
            if (path == identityPath || path == chatSubscribePath) {
              try {
                if (path == identityPath) {
                  await _answerIdentity(frame);
                } else {
                  await _ackSubscribe(frame);
                }
              } on StateError {
                // The test closed the socket mid-answer; done.
                break;
              }
              continue;
            }
          }
          _frameQueue.add(frame);
          _frameWaiter?.complete();
          _frameWaiter = null;
        }
      } catch (_) {
        // Socket closed; the queue ends with it.
      } finally {
        // Release the socket subscription first so a concurrent close()
        // on the other end never waits on this idle iterator.
        await _incoming.cancel();
        _queueClosed = true;
        _frameWaiter?.complete();
        _frameWaiter = null;
      }
    }();
  }

  Future<ServiceFrame> nextFrame() async {
    while (_frameQueue.isEmpty) {
      if (_queueClosed) {
        throw StateError('socket closed');
      }
      _frameWaiter = Completer<void>();
      await _frameWaiter!.future;
    }
    return _frameQueue.removeAt(0);
  }

  /// Next control-stream message.
  Future<Map<String, Object?>> nextMessage() async {
    while (true) {
      final frame = await nextFrame();
      if (frame.kind != ServiceFrameKind.bodyChunk) {
        throw StateError('unexpected frame ${frame.kind}');
      }
      final chunk = frame.value! as BodyChunk;
      final messages = _messages.feed(chunk.data ?? Uint8List(0));
      if (messages.isNotEmpty) {
        return messages.first;
      }
    }
  }

  /// Keep the reply stream open. The device opens it right after register.
  Future<void> _ackSubscribe(ServiceFrame frame) async {
    await sendFrame(ServiceFrame.response(
        frame.streamId,
        const ApplicationResponse(status: 200, endBody: false)));
  }

  Future<void> _answerIdentity(ServiceFrame frame) async {
    final request = frame.value! as ApplicationRequest;
    expect(request.path, identityPath);
    await sendFrame(ServiceFrame.response(
        frame.streamId,
        ApplicationResponse(
            status: 200,
            body: Uint8List.fromList(
                '{"ok":true,"result":{"name":"Test Muse"}}'.codeUnits),
            endBody: true)));
  }

  Future<void> sendFrame(ServiceFrame frame) async {
    for (final chunk
        in encodeNoiseFrames(encodeResponseEnvelope(frame))) {
      await _socket.send(await _send.encryptWithAd(Uint8List(0), chunk));
    }
  }

  Future<ServiceFrame> acceptControlStream({int status = 200}) async {
    final request = await nextFrame();
    streamId = request.streamId;
    await sendFrame(ServiceFrame.response(
        streamId,
        ApplicationResponse(
            status: status, endBody: status >= 400)));
    return request;
  }

  Future<void> sendMessage(Map<String, Object?> message) async {
    await sendFrame(ServiceFrame.bodyChunk(
        streamId, BodyChunk(data: encodeMessage(message))));
  }

  Future<void> close() => _socket.close();
}

class _SessionPair {
  _SessionPair(this.session, this.vm);
  final LinkSession session;
  final _FakeVm vm;
}

_SessionPair _makeSession(
    RunCommand runCommand, List<(String, Map<String, String>)> connectLog) {
  final toDevice = StreamController<Uint8List>();
  final toVm = StreamController<Uint8List>();
  final deviceSocket = _Pipe(toDevice, toVm);
  final vmSocket = _Pipe(toVm, toDevice);

  Future<LinkSocket> connect(
      String url, Map<String, String> headers, String userAgent) async {
    connectLog.add((url, headers));
    return deviceSocket;
  }

  final session = LinkSession(
    noiseHost: 'gw.example',
    vmId: 'vm 1&x',
    vmAuthToken: 'tok',
    device: _device,
    runCommand: runCommand,
    userAgent: 'test/0',
    connect: connect,
  );
  return _SessionPair(session, _FakeVm(vmSocket));
}

/// Skips the heartbeat the session sends as soon as register is acked.
Future<Map<String, Object?>> _nextCommand(_FakeVm vm) async {
  var message = await vm.nextMessage();
  while (message['method'] == 'link.heartbeat') {
    message = await vm.nextMessage();
  }
  return message;
}

void main() {
  group('link session', () {
    test('register, invoke, result and unpair', () async {
      final calls = <(String, Map<String, Object?>, int?)>[];
      final connects = <(String, Map<String, String>)>[];

      Future<Map<String, Object?>> runCommand(String command,
          Map<String, Object?> params, int? timeoutMs) async {
        calls.add((command, params, timeoutMs));
        return {
          'ok': true,
          'payload': {'status': 'ok'},
        };
      }

      final pair = _makeSession(runCommand, connects);
      final outcomeFuture = pair.session.run(null);

      await pair.vm.handshake();
      final request = await pair.vm.acceptControlStream();
      expect(request.kind, ServiceFrameKind.request);
      final open = request.value! as ApplicationRequest;
      expect(open.verb, 'POST');
      expect(open.path, '/link-control');
      expect(open.endBody, isFalse);

      final register = await pair.vm.nextMessage();
      expect(register['method'], 'link.register');
      final params = register['params'] as Map;
      expect(params['node_id'], 'homelink-abcdef');
      expect(params['platform'], 'android');
      expect(params['device_family'], 'companion');
      expect((params['commands_v2'] as Map).keys,
          contains('companion.set_status'));
      await pair.vm.sendMessage(
          {'type': 'res', 'id': register['id'], 'ok': true});
      // The register reply and identity answer race each other; wait for
      // both before asserting.
      for (var i = 0;
          i < 100 &&
              (pair.session.registeredAt == null ||
                  pair.session.agentName == null);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(pair.session.registeredAt, isNotNull);
      expect(pair.session.agentName, 'Test Muse');

      await pair.vm.sendMessage({
        'method': 'link.invoke',
        'id': 'inv-1',
        'command': 'companion.set_status',
        'params': {'text': 'hello'},
        'timeout_ms': 5000,
      });
      final result = await _nextCommand(pair.vm);
      expect(result, {
        'method': 'link.result',
        'id': 'inv-1',
        'ok': true,
        'payload': {'status': 'ok'},
      });
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'companion.set_status');
      expect(calls.single.$2, {'text': 'hello'});
      expect(calls.single.$3, 5000);

      await pair.vm.sendMessage({'type': 'evt', 'event': 'link.unpaired'});
      await expectLater(outcomeFuture, completion(Outcome.unpaired));

      final (url, headers) = connects.single;
      expect(url, 'wss://gw.example/v1/noise?vm_id=vm%201%26x');
      expect(headers, {'Authorization': 'Bearer tok'});
    });

    test('forbidden control stream', () async {
      Future<Map<String, Object?>> runCommand(String command,
              Map<String, Object?> params, int? timeoutMs) async =>
          {'ok': true};
      final pair = _makeSession(runCommand, []);
      final outcomeFuture = pair.session.run(null);
      await pair.vm.handshake();
      await pair.vm.acceptControlStream(status: 403);
      await expectLater(outcomeFuture, completion(Outcome.forbidden));
    });

    test('stop ends the session', () async {
      Future<Map<String, Object?>> runCommand(String command,
              Map<String, Object?> params, int? timeoutMs) async =>
          {'ok': true};
      final pair = _makeSession(runCommand, []);
      final stopper = Completer<void>();
      final outcomeFuture = pair.session.run(() => stopper.future);
      await pair.vm.handshake();
      await pair.vm.acceptControlStream();
      await pair.vm.nextMessage(); // link.register
      stopper.complete();
      await expectLater(outcomeFuture, completion(Outcome.stopped));
    });

    test('closed socket ends the session', () async {
      Future<Map<String, Object?>> runCommand(String command,
              Map<String, Object?> params, int? timeoutMs) async =>
          {'ok': true};
      final pair = _makeSession(runCommand, []);
      final outcomeFuture = pair.session.run(null);
      await pair.vm.handshake();
      await pair.vm.acceptControlStream();
      await pair.vm.nextMessage(); // link.register
      await pair.vm.close();
      await expectLater(outcomeFuture, completion(Outcome.closed));
    });

    test('send_chat posts a device-attributed message', () async {
      Future<Map<String, Object?>> runCommand(String command,
              Map<String, Object?> params, int? timeoutMs) async =>
          {'ok': true};
      final pair = _makeSession(runCommand, []);
      final outcomeFuture = pair.session.run(null);
      await pair.vm.handshake();
      await pair.vm.acceptControlStream();
      await pair.vm.nextMessage(); // link.register

      final replyFuture = pair.session.sendChat('porch light on', 'side-1');
      final frame = await pair.vm.nextFrame();
      expect(frame.kind, ServiceFrameKind.request);
      final chat = frame.value! as ApplicationRequest;
      expect(chat.verb, 'POST');
      expect(chat.path, '/chat/stream');
      expect(chat.endBody, isTrue);
      expect(json.decode(utf8.decode(chat.body!)), {
        'message': 'porch light on',
        'output_modality': 'text',
        'device_id': 'homelink-abcdef',
        'session_id': 'side-1',
      });
      final headers = {for (final h in chat.headers) h.key.toLowerCase(): h.value};
      expect(headers['content-type'], 'application/json');
      expect(headers['x-app-id'], 'musegadget');
      await pair.vm.sendFrame(ServiceFrame.response(
          frame.streamId,
          ApplicationResponse(
              status: 200,
              body: Uint8List.fromList('{"accepted":true}'.codeUnits),
              endBody: true)));
      expect(await replyFuture, {
        'ok': true,
        'status': 200,
        'response': {'accepted': true},
      });
      await pair.vm.close();
      await expectLater(outcomeFuture, completion(Outcome.closed));
    });

    test('device.invoke on another stream is answered with link.result',
        () async {
      final calls = <String>[];
      Future<Map<String, Object?>> runCommand(String command,
          Map<String, Object?> params, int? timeoutMs) async {
        calls.add(command);
        return {
          'ok': true,
          'payload': {'status': 'ok', 'battery': 80},
        };
      }

      final pair = _makeSession(runCommand, []);
      final outcomeFuture = pair.session.run(null);
      await pair.vm.handshake();
      await pair.vm.acceptControlStream();
      final register = await pair.vm.nextMessage();
      await pair.vm.sendMessage(
          {'type': 'res', 'id': register['id'], 'ok': true});
      await pair.vm.sendFrame(ServiceFrame.bodyChunk(
        99,
        BodyChunk(
          data: encodeMessage({
            'method': 'device.invoke',
            'id': 7,
            'params': {
              'command': 'device.health',
              'params': <String, Object?>{},
            },
          }),
        ),
      ));
      final result = await _nextCommand(pair.vm);
      expect(result['method'], 'link.result');
      expect(result['id'], 7);
      expect(result['ok'], isTrue);
      expect(calls, ['device.health']);
      await pair.vm.close();
      await expectLater(outcomeFuture, completion(Outcome.closed));
    });

    test('a bare JSON invoke on the control stream is answered', () async {
      Future<Map<String, Object?>> runCommand(String command,
              Map<String, Object?> params, int? timeoutMs) async =>
          {'ok': true, 'payload': {'status': 'ok'}};
      final pair = _makeSession(runCommand, []);
      final outcomeFuture = pair.session.run(null);
      await pair.vm.handshake();
      await pair.vm.acceptControlStream();
      final register = await pair.vm.nextMessage();
      await pair.vm.sendMessage(
          {'type': 'res', 'id': register['id'], 'ok': true});
      await pair.vm.sendFrame(ServiceFrame.bodyChunk(
        pair.vm.streamId,
        BodyChunk(
          data: Uint8List.fromList(utf8.encode(json.encode({
            'type': 'req',
            'method': 'device.health',
            'id': 'bare-1',
            'params': <String, Object?>{},
          }))),
        ),
      ));
      final result = await _nextCommand(pair.vm);
      expect(result, {
        'type': 'res',
        'method': 'link.result',
        'id': 'bare-1',
        'ok': true,
        'payload': {'status': 'ok'},
      });
      await pair.vm.close();
      await expectLater(outcomeFuture, completion(Outcome.closed));
    });

    test('a thrown command still sends link.result', () async {
      Future<Map<String, Object?>> runCommand(String command,
          Map<String, Object?> params, int? timeoutMs) async {
        throw StateError('boom');
      }

      final pair = _makeSession(runCommand, []);
      final outcomeFuture = pair.session.run(null);
      await pair.vm.handshake();
      await pair.vm.acceptControlStream();
      final register = await pair.vm.nextMessage();
      await pair.vm.sendMessage(
          {'type': 'res', 'id': register['id'], 'ok': true});
      await pair.vm.sendMessage({
        'method': 'link.invoke',
        'id': 'bad-1',
        'command': 'device.health',
        'params': <String, Object?>{},
      });
      final result = await _nextCommand(pair.vm);
      expect(result['method'], 'link.result');
      expect(result['id'], 'bad-1');
      expect(result['ok'], isFalse);
      expect(result['error'], contains('boom'));
      await pair.vm.close();
      await expectLater(outcomeFuture, completion(Outcome.closed));
    });
  });

  group('message decoder', () {
    test('handles split and batched messages plus keepalives', () {
      final data = BytesBuilder()
        ..add(encodeMessage({'a': 1}))
        ..add(encodeMessage({'b': 2}))
        ..add(Uint8List(4)); // keepalive
      final bytes = data.toBytes();
      final decoder = MessageDecoder();
      expect(decoder.feed(bytes.sublist(0, 5)), isEmpty);
      expect(decoder.feed(bytes.sublist(5)), [
        {'a': 1},
        {'b': 2},
      ]);
    });

    test('rejects oversize messages', () {
      final header = Uint8List(4)
        ..buffer.asByteData().setUint32(0, 1 << 30, Endian.little);
      expect(() => MessageDecoder().feed(header), throwsArgumentError);
    });

    test('reads one bare JSON object', () {
      final raw = utf8.encode('{"method":"device.health","id":"b"}');
      expect(MessageDecoder().feed(Uint8List.fromList(raw)), [
        {'method': 'device.health', 'id': 'b'},
      ]);
    });

    test('reads NDJSON without a length prefix', () {
      final raw = utf8.encode(
          '{"method":"device.health","id":1}\n{"method":"link.invoke","id":"c","command":"device.health"}\n');
      expect(MessageDecoder().feed(Uint8List.fromList(raw)), [
        {'method': 'device.health', 'id': 1},
        {'method': 'link.invoke', 'id': 'c', 'command': 'device.health'},
      ]);
    });

    test('drops malformed json', () {
      final bad = utf8.encode('not json');
      final framed = Uint8List(4 + bad.length)
        ..buffer.asByteData().setUint32(0, bad.length, Endian.little)
        ..setRange(4, 4 + bad.length, bad);
      expect(MessageDecoder().feed(framed), isEmpty);
    });
  });

  group('noise url', () {
    test('escapes vm ids like encodeURIComponent', () {
      expect(noiseUrl('h', 'a-b_c.d!~*\'()?&='),
          'wss://h/v1/noise?vm_id=a-b_c.d!~*\'()%3F%26%3D');
    });
  });
}
