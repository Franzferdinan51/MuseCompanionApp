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
// Dart port of the Muse Gadget SDK Noise transport
// (linux/src/musegadget/noise/transport.py).

import 'dart:typed_data';

import 'envelope.dart';
import 'framing.dart';
import 'noise_xx.dart';

final Uint8List emptyAd = Uint8List(0);

/// Frames ready to send on one stream.
class EncryptedFrames {
  const EncryptedFrames({required this.streamId, required this.frames});
  final int streamId;
  final List<Uint8List> frames;
}

enum DecryptedFrameKind { response, bodyChunk, reset }

/// One decrypted inbound frame.
class DecryptedFrame {
  const DecryptedFrame._(
      {required this.kind, required this.streamId, required this.value});

  factory DecryptedFrame.response(int streamId, ApplicationResponse response) =>
      DecryptedFrame._(
          kind: DecryptedFrameKind.response,
          streamId: streamId,
          value: response);

  factory DecryptedFrame.bodyChunk(int streamId, BodyChunk chunk) =>
      DecryptedFrame._(
          kind: DecryptedFrameKind.bodyChunk,
          streamId: streamId,
          value: chunk);

  factory DecryptedFrame.reset(int streamId, Reset reset) =>
      DecryptedFrame._(
          kind: DecryptedFrameKind.reset, streamId: streamId, value: reset);

  final DecryptedFrameKind kind;
  final int streamId;
  final Object value;

  ApplicationResponse? get response =>
      kind == DecryptedFrameKind.response ? value as ApplicationResponse : null;
  BodyChunk? get bodyChunk =>
      kind == DecryptedFrameKind.bodyChunk ? value as BodyChunk : null;
  Reset? get reset =>
      kind == DecryptedFrameKind.reset ? value as Reset : null;
}

/// Encrypts outbound requests and decrypts inbound frames on a Noise session.
class NoiseTransport {
  NoiseTransport({required CipherState send, required CipherState recv})
      : _send = send,
        _recv = recv;

  final CipherState _send;
  final CipherState _recv;
  final NoiseFrameDecoder _decoder = NoiseFrameDecoder();
  int _nextStreamId = 1;
  bool _dead = false;

  void _assertAlive() {
    if (_dead) {
      throw NoiseProtocolError('NoiseTransport: dead after prior failure');
    }
  }

  /// One complete request with its body inline.
  Future<EncryptedFrames> encryptHttpRequest(
    String httpMethod,
    String path, {
    Uint8List? body,
    ServiceType service = ServiceType.daemon,
    List<Header>? headers,
  }) {
    return _sendApplicationRequest(
      httpMethod: httpMethod,
      path: path,
      body: body ?? Uint8List(0),
      service: service,
      headers: headers,
      endBody: true,
    );
  }

  /// A request whose body follows in later chunks.
  Future<EncryptedFrames> startStreamRequest(
    String httpMethod,
    String path, {
    ServiceType service = ServiceType.daemon,
    List<Header>? headers,
  }) {
    return _sendApplicationRequest(
      httpMethod: httpMethod,
      path: path,
      body: Uint8List(0),
      service: service,
      headers: headers,
      endBody: false,
    );
  }

  Future<EncryptedFrames> _sendApplicationRequest({
    required String httpMethod,
    required String path,
    required Uint8List body,
    required ServiceType service,
    required List<Header>? headers,
    required bool endBody,
  }) async {
    _assertAlive();
    try {
      final streamId = _nextStreamId;
      _nextStreamId += 1;
      final request = ApplicationRequest(
        verb: httpMethod,
        path: path,
        headers: headers ?? const [],
        body: body,
        endBody: endBody,
      );
      final frame = ServiceFrame.request(streamId, request);
      final frames = await _encryptRequest(service, frame);
      return EncryptedFrames(streamId: streamId, frames: frames);
    } catch (_) {
      _dead = true;
      rethrow;
    }
  }

  Future<List<Uint8List>> encryptBodyChunk(
    int streamId,
    Uint8List data, {
    ServiceType service = ServiceType.daemon,
    bool endBody = false,
  }) async {
    _assertAlive();
    try {
      final frame = ServiceFrame.bodyChunk(
          streamId, BodyChunk(data: data, endBody: endBody));
      return await _encryptRequest(service, frame);
    } catch (_) {
      _dead = true;
      rethrow;
    }
  }

  Future<List<Uint8List>> encryptReset(
    int streamId, {
    ServiceType service = ServiceType.daemon,
    String reason = '',
    ResetCode code = ResetCode.cancelled,
  }) async {
    _assertAlive();
    try {
      final frame = ServiceFrame.reset(
          streamId, Reset(code: code, reason: reason));
      return await _encryptRequest(service, frame);
    } catch (_) {
      _dead = true;
      rethrow;
    }
  }

  /// Decrypt one inbound frame; null while a multi-chunk message reassembles.
  Future<DecryptedFrame?> decryptFrame(Uint8List ciphertext) async {
    _assertAlive();
    try {
      final plainFrame = await _recv.decryptWithAd(emptyAd, ciphertext);
      final reassembled = _decoder.decode(plainFrame);
      if (reassembled == null) {
        return null;
      }

      final response = decodeServiceResponse(reassembled);
      final payload = response.payload;
      if (payload == null || payload.isEmpty) {
        throw NoiseProtocolError('empty ServiceResponse payload');
      }

      final frame = decodeServiceFrame(payload);
      switch (frame.kind) {
        case ServiceFrameKind.response:
          final value = frame.value;
          if (value is! ApplicationResponse) {
            throw NoiseProtocolError('invalid response frame');
          }
          return DecryptedFrame.response(frame.streamId, value);
        case ServiceFrameKind.bodyChunk:
          final value = frame.value;
          if (value is! BodyChunk) {
            throw NoiseProtocolError('invalid body_chunk frame');
          }
          return DecryptedFrame.bodyChunk(frame.streamId, value);
        case ServiceFrameKind.reset:
          final value = frame.value;
          if (value is! Reset) {
            throw NoiseProtocolError('invalid reset frame');
          }
          return DecryptedFrame.reset(frame.streamId, value);
        case ServiceFrameKind.request:
          throw NoiseProtocolError(
              'NoiseTransport: unexpected request frame from server');
        case null:
          return null;
      }
    } catch (_) {
      _dead = true;
      rethrow;
    }
  }

  Future<List<Uint8List>> _encryptRequest(
      ServiceType service, ServiceFrame frame) async {
    final frameBytes = encodeServiceFrame(frame);
    final requestBytes = encodeServiceRequest(
        ServiceRequest(service: service, payload: frameBytes));
    final protoFrames = encodeNoiseFrames(requestBytes);
    final out = <Uint8List>[];
    for (final protoFrame in protoFrames) {
      out.add(await _send.encryptWithAd(emptyAd, protoFrame));
    }
    return out;
  }
}

/// Decode a request envelope (used by tests and the mock peer).
ServiceFrame decodeRequestEnvelope(Uint8List data) {
  final request = decodeServiceRequest(data);
  return decodeServiceFrame(request.payload ?? Uint8List(0));
}

/// Encode a response envelope (used by tests and the mock peer).
Uint8List encodeResponseEnvelope(ServiceFrame frame) {
  return encodeServiceResponse(
      ServiceResponse(payload: encodeServiceFrame(frame)));
}
