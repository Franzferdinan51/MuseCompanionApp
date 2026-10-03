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
// Dart port of the Muse Gadget SDK Noise service envelopes
// (linux/src/musegadget/noise/envelope.py).

import 'dart:convert';
import 'dart:typed_data';

import 'proto.dart';

/// Service selector carried on [ServiceRequest].
enum ServiceType {
  daemon(0),
  sentinel(1),
  vault(2),
  authd(3);

  const ServiceType(this.value);
  final int value;

  static ServiceType fromValue(int value) {
    for (final type in ServiceType.values) {
      if (type.value == value) return type;
    }
    throw ProtoError('unknown service type');
  }
}

/// Stream reset reason carried on [Reset].
enum ResetCode {
  unspecified(0),
  cancelled(1),
  timeout(2),
  protocolError(3),
  refusedStream(4),
  internalError(5),
  serviceUnavailable(6);

  const ResetCode(this.value);
  final int value;

  static ResetCode fromValue(int value) {
    for (final code in ResetCode.values) {
      if (code.value == value) return code;
    }
    throw ProtoError('unknown reset code');
  }
}

class Header {
  const Header(this.key, this.value);
  final String key;
  final String value;
}

class ApplicationRequest {
  const ApplicationRequest({
    this.verb = '',
    this.path = '',
    this.headers = const [],
    this.body,
    this.endBody = false,
  });
  final String verb;
  final String path;
  final List<Header> headers;
  final Uint8List? body;
  final bool endBody;
}

class ApplicationResponse {
  const ApplicationResponse({
    this.status = 0,
    this.headers = const [],
    this.body,
    this.endBody = false,
  });
  final int status;
  final List<Header> headers;
  final Uint8List? body;
  final bool endBody;
}

class BodyChunk {
  const BodyChunk({this.data, this.endBody = false});
  final Uint8List? data;
  final bool endBody;
}

class Reset {
  const Reset({this.code = ResetCode.unspecified, this.reason = ''});
  final ResetCode code;
  final String reason;
}

/// Kinds of [ServiceFrame] payload.
enum ServiceFrameKind { request, response, bodyChunk, reset }

class ServiceFrame {
  const ServiceFrame._(this.streamId, this.kind, this.value);

  factory ServiceFrame.request(int streamId, ApplicationRequest request) =>
      ServiceFrame._(streamId, ServiceFrameKind.request, request);

  factory ServiceFrame.response(int streamId, ApplicationResponse response) =>
      ServiceFrame._(streamId, ServiceFrameKind.response, response);

  factory ServiceFrame.bodyChunk(int streamId, BodyChunk chunk) =>
      ServiceFrame._(streamId, ServiceFrameKind.bodyChunk, chunk);

  factory ServiceFrame.reset(int streamId, Reset reset) =>
      ServiceFrame._(streamId, ServiceFrameKind.reset, reset);

  /// A frame with no payload (stream id only).
  factory ServiceFrame.empty(int streamId) =>
      ServiceFrame._(streamId, null, null);

  final int streamId;
  final ServiceFrameKind? kind;
  final Object? value;
}

class ServiceRequest {
  const ServiceRequest({this.service = ServiceType.daemon, this.payload});
  final ServiceType service;
  final Uint8List? payload;
}

class ServiceResponse {
  const ServiceResponse({this.payload});
  final Uint8List? payload;
}

String _decodeString(Uint8List value) {
  try {
    return utf8.decode(value);
  } on FormatException catch (e) {
    throw ProtoError('invalid utf-8 string: $e');
  }
}

Uint8List encodeHeader(Header header) {
  final out = BytesBuilder();
  if (header.key.isNotEmpty) {
    out.add(stringField(1, header.key));
  }
  if (header.value.isNotEmpty) {
    out.add(stringField(2, header.value));
  }
  return out.toBytes();
}

Header decodeHeader(Uint8List data) {
  var key = '';
  var value = '';
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('Header.key wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      key = _decodeString(raw.value);
    } else if (k.fieldNumber == 2) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('Header.value wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      value = _decodeString(raw.value);
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  return Header(key, value);
}

Uint8List encodeApplicationRequest(ApplicationRequest request) {
  final out = BytesBuilder();
  if (request.verb.isNotEmpty) {
    out.add(stringField(1, request.verb));
  }
  if (request.path.isNotEmpty) {
    out.add(stringField(2, request.path));
  }
  for (final header in request.headers) {
    out.add(delimitedField(3, encodeHeader(header)));
  }
  final body = request.body;
  if (body != null && body.isNotEmpty) {
    out.add(bytesField(4, body));
  }
  if (request.endBody) {
    out.add(boolField(5, true));
  }
  return out.toBytes();
}

ApplicationRequest decodeApplicationRequest(Uint8List data) {
  var verb = '';
  var path = '';
  final headers = <Header>[];
  Uint8List body = Uint8List(0);
  var endBody = false;
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ApplicationRequest.verb wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      verb = _decodeString(raw.value);
    } else if (k.fieldNumber == 2) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ApplicationRequest.path wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      path = _decodeString(raw.value);
    } else if (k.fieldNumber == 3) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ApplicationRequest.headers wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      headers.add(decodeHeader(raw.value));
    } else if (k.fieldNumber == 4) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ApplicationRequest.body wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      body = raw.value;
    } else if (k.fieldNumber == 5) {
      if (k.wireType != wireVarint) {
        throw ProtoError('ApplicationRequest.end_body wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      endBody = raw.value != 0;
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  return ApplicationRequest(
      verb: verb, path: path, headers: headers, body: body, endBody: endBody);
}

Uint8List encodeApplicationResponse(ApplicationResponse response) {
  final out = BytesBuilder();
  if (response.status != 0) {
    out.add(int32Field(1, response.status));
  }
  for (final header in response.headers) {
    out.add(delimitedField(2, encodeHeader(header)));
  }
  final body = response.body;
  if (body != null && body.isNotEmpty) {
    out.add(bytesField(3, body));
  }
  if (response.endBody) {
    out.add(boolField(4, true));
  }
  return out.toBytes();
}

ApplicationResponse decodeApplicationResponse(Uint8List data) {
  var status = 0;
  final headers = <Header>[];
  Uint8List body = Uint8List(0);
  var endBody = false;
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireVarint) {
        throw ProtoError('ApplicationResponse.status wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      status = decodeInt32(raw.value);
    } else if (k.fieldNumber == 2) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ApplicationResponse.headers wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      headers.add(decodeHeader(raw.value));
    } else if (k.fieldNumber == 3) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ApplicationResponse.body wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      body = raw.value;
    } else if (k.fieldNumber == 4) {
      if (k.wireType != wireVarint) {
        throw ProtoError('ApplicationResponse.end_body wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      endBody = raw.value != 0;
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  return ApplicationResponse(
      status: status, headers: headers, body: body, endBody: endBody);
}

Uint8List encodeBodyChunk(BodyChunk chunk) {
  final out = BytesBuilder();
  final data = chunk.data;
  if (data != null && data.isNotEmpty) {
    out.add(bytesField(1, data));
  }
  if (chunk.endBody) {
    out.add(boolField(2, true));
  }
  return out.toBytes();
}

BodyChunk decodeBodyChunk(Uint8List data) {
  Uint8List chunkData = Uint8List(0);
  var endBody = false;
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('BodyChunk.data wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      chunkData = raw.value;
    } else if (k.fieldNumber == 2) {
      if (k.wireType != wireVarint) {
        throw ProtoError('BodyChunk.end_body wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      endBody = raw.value != 0;
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  return BodyChunk(data: chunkData, endBody: endBody);
}

Uint8List encodeReset(Reset reset) {
  final out = BytesBuilder();
  if (reset.code != ResetCode.unspecified) {
    out.add(int32Field(1, reset.code.value));
  }
  if (reset.reason.isNotEmpty) {
    out.add(stringField(2, reset.reason));
  }
  return out.toBytes();
}

Reset decodeReset(Uint8List data) {
  var code = ResetCode.unspecified;
  var reason = '';
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireVarint) {
        throw ProtoError('Reset.code wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      code = ResetCode.fromValue(decodeInt32(raw.value));
    } else if (k.fieldNumber == 2) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('Reset.reason wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      reason = _decodeString(raw.value);
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  return Reset(code: code, reason: reason);
}

Uint8List encodeServiceFrame(ServiceFrame frame) {
  final out = BytesBuilder();
  if (frame.streamId != 0) {
    out.add(int64Field(1, frame.streamId));
  }
  final kind = frame.kind;
  if (kind == null) {
    if (frame.value != null) {
      throw ProtoError('ServiceFrame value provided without kind');
    }
    return out.toBytes();
  }
  switch (kind) {
    case ServiceFrameKind.request:
      final value = frame.value;
      if (value is! ApplicationRequest) {
        throw ProtoError('ServiceFrame request value has wrong type');
      }
      out.add(delimitedField(2, encodeApplicationRequest(value)));
    case ServiceFrameKind.response:
      final value = frame.value;
      if (value is! ApplicationResponse) {
        throw ProtoError('ServiceFrame response value has wrong type');
      }
      out.add(delimitedField(3, encodeApplicationResponse(value)));
    case ServiceFrameKind.bodyChunk:
      final value = frame.value;
      if (value is! BodyChunk) {
        throw ProtoError('ServiceFrame body_chunk value has wrong type');
      }
      out.add(delimitedField(4, encodeBodyChunk(value)));
    case ServiceFrameKind.reset:
      final value = frame.value;
      if (value is! Reset) {
        throw ProtoError('ServiceFrame reset value has wrong type');
      }
      out.add(delimitedField(5, encodeReset(value)));
  }
  return out.toBytes();
}

ServiceFrame decodeServiceFrame(Uint8List data) {
  var streamId = 0;
  ServiceFrameKind? kind;
  Object? value;
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireVarint) {
        throw ProtoError('ServiceFrame.stream_id wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      streamId = decodeInt64(raw.value);
    } else if (k.fieldNumber == 2) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ServiceFrame.request wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      kind = ServiceFrameKind.request;
      value = decodeApplicationRequest(raw.value);
    } else if (k.fieldNumber == 3) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ServiceFrame.response wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      kind = ServiceFrameKind.response;
      value = decodeApplicationResponse(raw.value);
    } else if (k.fieldNumber == 4) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ServiceFrame.body_chunk wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      kind = ServiceFrameKind.bodyChunk;
      value = decodeBodyChunk(raw.value);
    } else if (k.fieldNumber == 5) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ServiceFrame.reset wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      kind = ServiceFrameKind.reset;
      value = decodeReset(raw.value);
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  if (kind == null) {
    return ServiceFrame.empty(streamId);
  }
  switch (kind) {
    case ServiceFrameKind.request:
      return ServiceFrame.request(streamId, value! as ApplicationRequest);
    case ServiceFrameKind.response:
      return ServiceFrame.response(streamId, value! as ApplicationResponse);
    case ServiceFrameKind.bodyChunk:
      return ServiceFrame.bodyChunk(streamId, value! as BodyChunk);
    case ServiceFrameKind.reset:
      return ServiceFrame.reset(streamId, value! as Reset);
  }
}

Uint8List encodeServiceRequest(ServiceRequest request) {
  final out = BytesBuilder();
  if (request.service != ServiceType.daemon) {
    out.add(varintField(1, request.service.value));
  }
  final payload = request.payload;
  if (payload != null && payload.isNotEmpty) {
    out.add(bytesField(2, payload));
  }
  return out.toBytes();
}

ServiceRequest decodeServiceRequest(Uint8List data) {
  var service = ServiceType.daemon;
  Uint8List payload = Uint8List(0);
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireVarint) {
        throw ProtoError('ServiceRequest.service wrong wire type');
      }
      final raw = readVarint(data, offset);
      offset = raw.offset;
      service = ServiceType.fromValue(raw.value);
    } else if (k.fieldNumber == 2) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ServiceRequest.payload wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      payload = raw.value;
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  return ServiceRequest(service: service, payload: payload);
}

Uint8List encodeServiceResponse(ServiceResponse response) {
  final payload = response.payload;
  if (payload == null || payload.isEmpty) {
    return Uint8List(0);
  }
  return bytesField(1, payload);
}

ServiceResponse decodeServiceResponse(Uint8List data) {
  Uint8List payload = Uint8List(0);
  var offset = 0;
  while (offset < data.length) {
    final k = readKey(data, offset);
    offset = k.offset;
    if (k.fieldNumber == 1) {
      if (k.wireType != wireDelimited) {
        throw ProtoError('ServiceResponse.payload wrong wire type');
      }
      final raw = readDelimited(data, offset);
      offset = raw.offset;
      payload = raw.value;
    } else {
      offset = skipField(data, offset, k.wireType);
    }
  }
  return ServiceResponse(payload: payload);
}
