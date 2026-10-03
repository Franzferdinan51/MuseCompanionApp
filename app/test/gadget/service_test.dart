import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse_companion/src/gadget/chat_events.dart';
import 'package:muse_companion/src/gadget/envelope.dart';
import 'package:muse_companion/src/gadget/framing.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/link_client.dart';
import 'package:muse_companion/src/gadget/noise_xx.dart';
import 'package:muse_companion/src/gadget/service.dart';
import 'package:muse_companion/src/gadget/transport.dart';

Map<String, Object?> _pairing({int? savedAt}) => {
      'access_token': 'a1',
      'refresh_token': 'r1',
      'token_type': 'device',
      'username': 'someone',
      'api_url': '',
      'api_url_v2': '',
      'noise_host': '',
      'access_token_saved_at': savedAt ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };

String _vmsBody() => json.encode({
      'vm_list': [
        {
          'vm_ws_url': 'wss://vm',
          'vm_auth_token': 'vm-tok',
          'vm_name': 'muse',
          'vm_id': 'vm-1',
          'default': true,
        }
      ]
    });

/// Scripted VM: handshake, control stream, register reply, then [after].
///
/// [gate] holds the script after the register reply until the test has
/// observed `connected`: without it the script outruns the test's poll
/// loop and the connected state flashes by unseen.
class _ScriptedLink {
  _ScriptedLink(this.after, {this.gate});

  final Future<void> Function(_VmSide vm) after;
  final Future<void>? gate;
  int connects = 0;

  Future<LinkSocket> connect(String url, Map<String, String> headers,
      String userAgent) async {
    connects += 1;
    final toDevice = StreamController<Uint8List>();
    final toVm = StreamController<Uint8List>();
    final device = _Pipe(toDevice, toVm);
    final vm = _VmSide(_Pipe(toVm, toDevice));
    () async {
      try {
        await vm.handshake();
        final open = await vm.nextFrame();
        final request = open.value! as ApplicationRequest;
        vm.streamId = open.streamId;
        await vm.sendFrame(ServiceFrame.response(
            vm.streamId, const ApplicationResponse(status: 200)));
        expect(request.path, '/link-control');
        final register = await vm.nextMessage();
        await vm.sendMessage(
            {'type': 'res', 'id': register['id'], 'ok': true});
        await vm.settleIdentity();
        final heldGate = gate;
        if (heldGate != null) {
          await heldGate;
        }
        await after(vm);
      } catch (_) {
        // Test teardown closes sockets mid-script; ignore.
      } finally {
        // Release the socket subscription: an idle StreamIterator pauses
        // it, which would deadlock the device's socket.close().
        await vm.incoming.cancel();
      }
    }();
    return device;
  }
}

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

class _VmSide {
  _VmSide(this.socket) : incoming = StreamIterator(socket.stream);
  final LinkSocket socket;
  final StreamIterator<Uint8List> incoming;
  final NoiseFrameDecoder decoder = NoiseFrameDecoder();
  final MessageDecoder messages = MessageDecoder();
  late CipherState send;
  late CipherState recv;
  int streamId = 0;
  bool identitySeen = false;

  Future<void> handshake() async {
    final responder = NoiseXXResponder();
    await responder.initialize();
    await incoming.moveNext();
    await socket.send(await responder
        .readMessage1AndWriteMessage2(incoming.current));
    await incoming.moveNext();
    await responder.readMessage3(incoming.current);
    final (s, r) = await responder.split();
    send = s;
    recv = r;
  }

  Future<ServiceFrame> nextFrame() async {
    while (await incoming.moveNext()) {
      final plain =
          await recv.decryptWithAd(Uint8List(0), incoming.current);
      final assembled = decoder.decode(plain);
      if (assembled != null) {
        return decodeRequestEnvelope(assembled);
      }
    }
    throw StateError('closed');
  }

  Future<Map<String, Object?>> nextMessage() async {
    while (true) {
      final frame = await nextFrame();
      if (frame.kind == ServiceFrameKind.request) {
        final request = frame.value! as ApplicationRequest;
        if (request.path == identityPath) {
          identitySeen = true;
          await _answerIdentity(frame);
        } else if (request.path == chatSubscribePath) {
          await _ackSubscribe(frame);
        }
        continue;
      }
      final chunk = frame.value! as BodyChunk;
      final out = messages.feed(chunk.data ?? Uint8List(0));
      if (out.isNotEmpty) return out.first;
    }
  }

  /// Read and answer the identity request when it is still in flight.
  ///
  /// The device always sends exactly one GET /identity after opening the
  /// control stream; it races link.register, so it may arrive after it.
  Future<void> settleIdentity() async {
    if (identitySeen) return;
    while (true) {
      final frame = await nextFrame();
      if (frame.kind != ServiceFrameKind.request) {
        throw StateError('expected the identity request, got $frame');
      }
      final request = frame.value! as ApplicationRequest;
      if (request.path == chatSubscribePath) {
        await _ackSubscribe(frame);
        continue;
      }
      if (request.path != identityPath) {
        throw StateError('expected the identity request, got ${request.path}');
      }
      identitySeen = true;
      await _answerIdentity(frame);
      return;
    }
  }

  Future<void> _answerIdentity(ServiceFrame frame) async {
    await sendFrame(ServiceFrame.response(
        frame.streamId,
        ApplicationResponse(
            status: 200,
            body: Uint8List.fromList(
                '{"result":{"name":"VM Muse"}}'.codeUnits),
            endBody: true)));
  }

  Future<void> _ackSubscribe(ServiceFrame frame) async {
    await sendFrame(ServiceFrame.response(
        frame.streamId,
        const ApplicationResponse(status: 200, endBody: false)));
  }

  Future<void> sendFrame(ServiceFrame frame) async {
    for (final chunk in encodeNoiseFrames(encodeResponseEnvelope(frame))) {
      await socket.send(await send.encryptWithAd(Uint8List(0), chunk));
    }
  }

  Future<void> sendMessage(Map<String, Object?> message) async {
    await sendFrame(ServiceFrame.bodyChunk(
        streamId, BodyChunk(data: encodeMessage(message))));
  }
}

Future<void> _waitFor(
    GadgetService service, ConnectionState state) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (service.connectionState != state) {
    if (DateTime.now().isAfter(deadline)) {
      fail('never reached $state (at ${service.connectionState} '
          '${service.statusDetail})');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('gadget service', () {
    test('reports unpaired with no pairing saved', () async {
      final service = GadgetService(
        identity: const Identity('02:aa:bb:cc:dd:ee'),
        commands: const {},
        runCommand: (_, _, _) async => {'ok': true},
        pairingStore: MemoryPairingStore(),
        version: '0.1.0',
      );
      final states = <ConnectionState>[];
      final sub = service.onStateChanged.listen(states.add);
      final running = service.start();
      await _waitFor(service, ConnectionState.unpaired);
      await service.stop();
      await running;
      await sub.cancel();
      expect(states, contains(ConnectionState.unpaired));
    });

    test('connects, registers, then handles unpair', () async {
      final store = MemoryPairingStore();
      await store.save(_pairing());
      final httpClient = MockClient((request) async {
        if (request.url.path.endsWith('/fetch_vms')) {
          return http.Response(_vmsBody(), 200);
        }
        return http.Response('', 404);
      });
      final gate = Completer<void>();
      final link = _ScriptedLink(
        (vm) async {
          await vm.sendMessage({'type': 'evt', 'event': 'link.unpaired'});
        },
        gate: gate.future,
      );
      final service = GadgetService(
        identity: const Identity('02:aa:bb:cc:dd:ee'),
        commands: const {},
        runCommand: (_, _, _) async => {'ok': true},
        pairingStore: store,
        version: '0.1.0',
        connect: link.connect,
        httpClient: httpClient,
      );
      final running = service.start();
      await _waitFor(service, ConnectionState.connected);
      // The identity answer races the register reply; wait for both.
      final deadline =
          DateTime.now().add(const Duration(seconds: 10));
      while (service.agentName == null) {
        if (DateTime.now().isAfter(deadline)) {
          fail('identity answer never arrived');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.agentName, 'VM Muse');
      expect(service.isRegistered, isTrue);
      gate.complete();
      await _waitFor(service, ConnectionState.unpaired);
      expect(await store.load(), isNull);
      expect(link.connects, 1);
      await service.stop();
      await running;
    });

    test('rotates the device token after a 401', () async {
      final store = MemoryPairingStore();
      await store.save(_pairing());
      var fetches = 0;
      final httpClient = MockClient((request) async {
        if (request.url.path.endsWith('/fetch_vms')) {
          fetches += 1;
          if (fetches == 1) {
            return http.Response('', 401);
          }
          return http.Response(_vmsBody(), 200);
        }
        if (request.url.path.endsWith('/device_token/refresh')) {
          return http.Response(
              json.encode(
                  {'access_token': 'a2', 'refresh_token': 'r2'}),
              200);
        }
        return http.Response('', 404);
      });
      final gate = Completer<void>();
      final link = _ScriptedLink(
        (vm) async {
          await vm.socket.close();
        },
        gate: gate.future,
      );
      final service = GadgetService(
        identity: const Identity('02:aa:bb:cc:dd:ee'),
        commands: const {},
        runCommand: (_, _, _) async => {'ok': true},
        pairingStore: store,
        version: '0.1.0',
        connect: link.connect,
        httpClient: httpClient,
      );
      final running = service.start();
      await _waitFor(service, ConnectionState.connected);
      gate.complete();
      final rotated = await store.load();
      expect(rotated!['access_token'], 'a2');
      expect(rotated['refresh_token'], 'r2');
      await service.stop();
      await running;
    });

    test('revoked pairing is deleted', () async {
      final store = MemoryPairingStore();
      await store.save(_pairing());
      final httpClient = MockClient((request) async {
        if (request.url.path.endsWith('/fetch_vms')) {
          return http.Response('', 401);
        }
        return http.Response('', 401);
      });
      final link = _ScriptedLink((_) async {});
      final service = GadgetService(
        identity: const Identity('02:aa:bb:cc:dd:ee'),
        commands: const {},
        runCommand: (_, _, _) async => {'ok': true},
        pairingStore: store,
        version: '0.1.0',
        connect: link.connect,
        httpClient: httpClient,
      );
      final running = service.start();
      await _waitFor(service, ConnectionState.unpaired);
      expect(await store.load(), isNull);
      expect(link.connects, 0);
      await service.stop();
      await running;
    });

    test('aged tokens rotate proactively', () async {
      final store = MemoryPairingStore();
      await store.save(_pairing(
          savedAt:
              DateTime.now().millisecondsSinceEpoch ~/ 1000 - 4 * 3600));
      var refreshed = false;
      final httpClient = MockClient((request) async {
        if (request.url.path.endsWith('/fetch_vms')) {
          return http.Response(_vmsBody(), 200);
        }
        if (request.url.path.endsWith('/device_token/refresh')) {
          refreshed = true;
          return http.Response(
              json.encode(
                  {'access_token': 'a9', 'refresh_token': 'r9'}),
              200);
        }
        return http.Response('', 404);
      });
      final gate = Completer<void>();
      final link = _ScriptedLink(
        (vm) async {
          await vm.socket.close();
        },
        gate: gate.future,
      );
      final service = GadgetService(
        identity: const Identity('02:aa:bb:cc:dd:ee'),
        commands: const {},
        runCommand: (_, _, _) async => {'ok': true},
        pairingStore: store,
        version: '0.1.0',
        connect: link.connect,
        httpClient: httpClient,
      );
      final running = service.start();
      await _waitFor(service, ConnectionState.connected);
      gate.complete();
      expect(refreshed, isTrue);
      expect((await store.load())!['access_token'], 'a9');
      await service.stop();
      await running;
    });

    test('sendChat is gated until registered', () async {
      final service = GadgetService(
        identity: const Identity('02:aa:bb:cc:dd:ee'),
        commands: const {},
        runCommand: (_, _, _) async => {'ok': true},
        pairingStore: MemoryPairingStore(),
        version: '0.1.0',
      );
      final reply = await service.sendChat('hi');
      expect(reply['ok'], isFalse);
    });

    test('backoff waits between closed sessions', () async {
      final store = MemoryPairingStore();
      await store.save(_pairing());
      final httpClient = MockClient((request) async {
        if (request.url.path.endsWith('/fetch_vms')) {
          return http.Response(_vmsBody(), 200);
        }
        return http.Response('', 404);
      });
      final gate = Completer<void>();
      final link = _ScriptedLink(
        (vm) async {
          await vm.socket.close();
        },
        gate: gate.future,
      );
      final service = GadgetService(
        identity: const Identity('02:aa:bb:cc:dd:ee'),
        commands: const {},
        runCommand: (_, _, _) async => {'ok': true},
        pairingStore: store,
        version: '0.1.0',
        connect: link.connect,
        httpClient: httpClient,
      );
      final running = service.start();
      await _waitFor(service, ConnectionState.connected);
      gate.complete();
      await _waitFor(service, ConnectionState.waiting);
      expect(service.statusDetail, contains('retrying'));
      expect(link.connects, 1);
      await service.stop();
      await running;
      // Stopping during backoff ends promptly (no lingering sleep).
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });
}
