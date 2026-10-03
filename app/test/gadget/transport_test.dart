import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/envelope.dart';
import 'package:muse_companion/src/gadget/framing.dart';
import 'package:muse_companion/src/gadget/noise_xx.dart';
import 'package:muse_companion/src/gadget/transport.dart';

class _Handshake {
  _Handshake(
      {required this.device,
      required this.vmSend,
      required this.vmRecv});
  final NoiseTransport device;
  final CipherState vmSend;
  final CipherState vmRecv;
}

/// Runs a full handshake: a device transport plus the VM's raw ciphers.
Future<_Handshake> _liveHandshake() async {
  final initiator = NoiseXXInitiator();
  final responder = NoiseXXResponder();
  await initiator.initialize();
  await responder.initialize();
  final msg1 = await initiator.writeMessage1();
  final msg2 = await responder.readMessage1AndWriteMessage2(msg1);
  await initiator.readMessage2(msg2);
  final msg3 = await initiator.writeMessage3();
  await responder.readMessage3(msg3);
  final (iSend, iRecv) = await initiator.split();
  final (rSend, rRecv) = await responder.split();
  return _Handshake(
      device: NoiseTransport(send: iSend, recv: iRecv),
      vmSend: rSend,
      vmRecv: rRecv);
}

/// Decrypt device-bound frames with a raw cipher and decode the envelope.
Future<ServiceFrame> _vmDecodeRequest(
    _Handshake hs, List<Uint8List> frames) async {
  final decoder = NoiseFrameDecoder();
  for (final frame in frames) {
    final plain = await hs.vmRecv.decryptWithAd(Uint8List(0), frame);
    final assembled = decoder.decode(plain);
    if (assembled != null) {
      return decodeRequestEnvelope(assembled);
    }
  }
  throw StateError('request never completed');
}

/// Encrypt a VM response envelope for the device transport.
Future<List<Uint8List>> _vmEncryptResponse(
    _Handshake hs, ServiceFrame frame) async {
  final out = <Uint8List>[];
  for (final proto in encodeNoiseFrames(encodeResponseEnvelope(frame))) {
    out.add(await hs.vmSend.encryptWithAd(Uint8List(0), proto));
  }
  return out;
}

void main() {
  group('noise transport', () {
    test('assigns increasing stream ids', () async {
      final hs = await _liveHandshake();
      final first = await hs.device.encryptHttpRequest('GET', '/identity');
      final second =
          await hs.device.startStreamRequest('POST', '/link-control');
      final third = await hs.device.encryptBodyChunk(9, Uint8List(0));
      expect(first.streamId, 1);
      expect(second.streamId, 2);
      expect(third, isNotEmpty);
    });

    test('device http request decodes on the vm side', () async {
      final hs = await _liveHandshake();
      final encrypted = await hs.device.encryptHttpRequest(
        'POST',
        '/chat/stream',
        body: Uint8List.fromList([1, 2, 3]),
        headers: const [Header('x-app-id', 'musegadget')],
      );
      final frame = await _vmDecodeRequest(hs, encrypted.frames);
      expect(frame.kind, ServiceFrameKind.request);
      expect(frame.streamId, encrypted.streamId);
      final request = frame.value! as ApplicationRequest;
      expect(request.verb, 'POST');
      expect(request.path, '/chat/stream');
      expect(request.body, [1, 2, 3]);
      expect(request.endBody, isTrue);
      expect(request.headers.single.value, 'musegadget');
    });

    test('stream request plus body chunks decode on the vm side', () async {
      final hs = await _liveHandshake();
      final open =
          await hs.device.startStreamRequest('POST', '/link-control');
      var frame = await _vmDecodeRequest(hs, open.frames);
      var request = frame.value! as ApplicationRequest;
      expect((request.path, request.endBody), ('/link-control', false));

      final chunk = await hs.device.encryptBodyChunk(
          open.streamId, Uint8List.fromList([4, 5]),
          endBody: true);
      frame = await _vmDecodeRequest(hs, chunk);
      expect(frame.kind, ServiceFrameKind.bodyChunk);
      expect(frame.streamId, open.streamId);
      final body = frame.value! as BodyChunk;
      expect(body.data, [4, 5]);
      expect(body.endBody, isTrue);
    });

    test('vm response decodes on the device side', () async {
      final hs = await _liveHandshake();
      final request = await hs.device.encryptHttpRequest('GET', '/identity');
      final frames = await _vmEncryptResponse(
          hs,
          ServiceFrame.response(
              request.streamId,
              ApplicationResponse(
                  status: 200,
                  body: Uint8List.fromList('{"ok":true}'.codeUnits),
                  endBody: true)));
      DecryptedFrame? decoded;
      for (final frame in frames) {
        decoded = await hs.device.decryptFrame(frame);
      }
      expect(decoded!.kind, DecryptedFrameKind.response);
      expect(decoded.streamId, request.streamId);
      expect(decoded.response!.status, 200);
      expect(decoded.response!.endBody, isTrue);
    });

    test('multi-chunk response reassembles before delivery', () async {
      final hs = await _liveHandshake();
      final request = await hs.device.encryptHttpRequest('GET', '/big');
      final big = Uint8List.fromList(List.filled(200000, 7));
      final frames = await _vmEncryptResponse(
          hs,
          ServiceFrame.response(
              request.streamId,
              ApplicationResponse(
                  status: 200, body: big, endBody: true)));
      expect(frames.length, greaterThan(1));
      DecryptedFrame? decoded;
      var nulls = 0;
      for (final frame in frames) {
        final out = await hs.device.decryptFrame(frame);
        if (out == null) {
          nulls += 1;
        } else {
          decoded = out;
        }
      }
      expect(nulls, frames.length - 1);
      expect(decoded!.response!.body, big);
    });

    test('vm reset decodes on the device side', () async {
      final hs = await _liveHandshake();
      final request = await hs.device.encryptHttpRequest('GET', '/x');
      final frames = await _vmEncryptResponse(
          hs,
          ServiceFrame.reset(request.streamId,
              const Reset(code: ResetCode.cancelled, reason: 'stop')));
      final decoded = await hs.device.decryptFrame(frames.single);
      expect(decoded!.kind, DecryptedFrameKind.reset);
      expect(decoded.reset!.reason, 'stop');
    });

    test('request envelope helpers round-trip', () {
      final frame = ServiceFrame.request(
          2, const ApplicationRequest(verb: 'POST', path: '/link-control'));
      final bytes = encodeServiceRequest(ServiceRequest(
          service: ServiceType.daemon, payload: encodeServiceFrame(frame)));
      final decoded = decodeRequestEnvelope(bytes);
      expect(decoded.kind, ServiceFrameKind.request);
      expect((decoded.value! as ApplicationRequest).path, '/link-control');
    });

    test('decrypt failure kills the transport', () async {
      final hs = await _liveHandshake();
      await expectLater(hs.device.decryptFrame(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<NoiseProtocolError>()));
      await expectLater(hs.device.decryptFrame(Uint8List.fromList([1])),
          throwsA(isA<NoiseProtocolError>()));
      await expectLater(hs.device.encryptHttpRequest('GET', '/x'),
          throwsA(isA<NoiseProtocolError>()));
    });
  });
}
