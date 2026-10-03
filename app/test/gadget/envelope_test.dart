import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/envelope.dart';

void main() {
  group('header', () {
    test('round-trips', () {
      const header = Header('Content-Type', 'application/json');
      final decoded = decodeHeader(encodeHeader(header));
      expect((decoded.key, decoded.value), ('Content-Type', 'application/json'));
    });

    test('empty header encodes to empty bytes', () {
      expect(encodeHeader(const Header('', '')), isEmpty);
    });
  });

  group('application request', () {
    test('round-trips all fields', () {
      final request = ApplicationRequest(
        verb: 'POST',
        path: '/link-control',
        headers: const [Header('x-app-id', 'musegadget')],
        body: Uint8List.fromList([1, 2, 3]),
        endBody: true,
      );
      final decoded = decodeApplicationRequest(encodeApplicationRequest(request));
      expect(decoded.verb, 'POST');
      expect(decoded.path, '/link-control');
      expect(decoded.headers, hasLength(1));
      expect(decoded.headers.single.key, 'x-app-id');
      expect(decoded.body, [1, 2, 3]);
      expect(decoded.endBody, isTrue);
    });

    test('defaults encode to empty bytes', () {
      expect(encodeApplicationRequest(const ApplicationRequest()), isEmpty);
    });
  });

  group('application response', () {
    test('round-trips all fields', () {
      final response = ApplicationResponse(
        status: 200,
        headers: const [Header('a', 'b')],
        body: Uint8List.fromList([9]),
        endBody: true,
      );
      final decoded =
          decodeApplicationResponse(encodeApplicationResponse(response));
      expect(decoded.status, 200);
      expect(decoded.headers, hasLength(1));
      expect(decoded.body, [9]);
      expect(decoded.endBody, isTrue);
    });

    test('negative statuses survive the int32 encoding', () {
      const response = ApplicationResponse(status: -1);
      final decoded =
          decodeApplicationResponse(encodeApplicationResponse(response));
      expect(decoded.status, -1);
    });
  });

  group('body chunk and reset', () {
    test('body chunk round-trips', () {
      final chunk =
          BodyChunk(data: Uint8List.fromList([1, 2]), endBody: true);
      final decoded = decodeBodyChunk(encodeBodyChunk(chunk));
      expect(decoded.data, [1, 2]);
      expect(decoded.endBody, isTrue);
    });

    test('reset round-trips code and reason', () {
      const reset = Reset(code: ResetCode.cancelled, reason: 'bye');
      final decoded = decodeReset(encodeReset(reset));
      expect(decoded.code, ResetCode.cancelled);
      expect(decoded.reason, 'bye');
    });
  });

  group('service frame', () {
    test('each kind round-trips with stream id', () {
      final frames = [
        ServiceFrame.request(
            7, const ApplicationRequest(verb: 'GET', path: '/identity')),
        ServiceFrame.response(8, const ApplicationResponse(status: 200)),
        ServiceFrame.bodyChunk(
            9, BodyChunk(data: Uint8List.fromList([1]))),
        ServiceFrame.reset(10, const Reset(code: ResetCode.timeout)),
      ];
      final kinds = [
        ServiceFrameKind.request,
        ServiceFrameKind.response,
        ServiceFrameKind.bodyChunk,
        ServiceFrameKind.reset,
      ];
      for (var i = 0; i < frames.length; i++) {
        final decoded = decodeServiceFrame(encodeServiceFrame(frames[i]));
        expect(decoded.streamId, 7 + i);
        expect(decoded.kind, kinds[i]);
      }
    });

    test('frame without a kind carries only the stream id', () {
      final decoded = decodeServiceFrame(encodeServiceFrame(ServiceFrame.empty(3)));
      expect(decoded.streamId, 3);
      expect(decoded.kind, isNull);
    });

    test('negative stream ids survive the int64 encoding', () {
      final frame = ServiceFrame.response(-5, const ApplicationResponse());
      final decoded = decodeServiceFrame(encodeServiceFrame(frame));
      expect(decoded.streamId, -5);
    });
  });

  group('service request and response', () {
    test('daemon service is the default and encodes empty', () {
      const request = ServiceRequest();
      expect(encodeServiceRequest(request), isEmpty);
      final decoded = decodeServiceRequest(encodeServiceRequest(request));
      expect(decoded.service, ServiceType.daemon);
      expect(decoded.payload, isEmpty);
    });

    test('non-default service and payload round-trip', () {
      final request = ServiceRequest(
          service: ServiceType.authd,
          payload: Uint8List.fromList([1, 2, 3]));
      final decoded = decodeServiceRequest(encodeServiceRequest(request));
      expect(decoded.service, ServiceType.authd);
      expect(decoded.payload, [1, 2, 3]);
    });

    test('empty response encodes to empty bytes', () {
      expect(encodeServiceResponse(const ServiceResponse()), isEmpty);
      final decoded =
          decodeServiceResponse(encodeServiceResponse(const ServiceResponse()));
      expect(decoded.payload, isEmpty);
    });
  });
}
