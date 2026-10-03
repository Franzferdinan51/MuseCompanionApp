import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' hide CipherState;
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/ble_framing.dart';
import 'package:muse_companion/src/gadget/ble_setup.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/p256.dart';
import 'package:muse_companion/src/gadget/pairing.dart';

Map<String, Object?> _appVector() {
  final file = File('test/testdata/link_pairing_v5.json');
  final decoded = json.decode(file.readAsStringSync()) as Map<String, Object?>;
  for (final vector in decoded['vectors'] as List) {
    final map = (vector as Map).cast<String, Object?>();
    if (map['name'] == 'community_app_v5') return map;
  }
  throw StateError('no community_app_v5 vector');
}

Uint8List _hex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Mobile side of the record layer, from the vector keys.
class _Mobile {
  _Mobile(Map<String, Object?> vector)
      : sessionId = vector['session_id'] as String,
        _tx = SecretKey(
            _hex(vector['mobile_tx_key_hex'] as String)),
        _rx = SecretKey(
            _hex(vector['mobile_rx_key_hex'] as String));

  final String sessionId;
  final SecretKey _tx;
  final SecretKey _rx;
  int txCounter = 0;

  static final AesGcm _aes = AesGcm.with256bits();

  Future<Map<String, Object?>> seal(Map<String, Object?> command,
      [int? counter]) async {
    final c = counter ?? txCounter++;
    final sealed = await _aes.encrypt(
      Uint8List.fromList(utf8.encode(json.encode(command))),
      secretKey: _tx,
      nonce: recordNonce(0, c),
      aad: recordAad(sessionId, 0, c),
    );
    return {
      'action': 'pairing_encrypted',
      'session_id': sessionId,
      'counter': c.toString(),
      'ciphertext':
          b64urlEncode(Uint8List.fromList(sealed.cipherText)),
      'tag': b64urlEncode(Uint8List.fromList(sealed.mac.bytes)),
    };
  }

  Future<Map<String, Object?>> open(Map<String, Object?> envelope) async {
    final counter = int.parse(envelope['counter'] as String);
    final plain = await _aes.decrypt(
      SecretBox(
        b64urlDecode(envelope['ciphertext']),
        nonce: recordNonce(1, counter),
        mac: Mac(b64urlDecode(envelope['tag'])),
      ),
      secretKey: _rx,
      aad: recordAad(sessionId, 1, counter),
    );
    return (json.decode(utf8.decode(plain)) as Map).cast<String, Object?>();
  }
}

class _FakeTransport implements SetupTransport {
  _FakeTransport([this._mtu = 185]);

  final int _mtu;
  final List<Object?> messages = [];
  final List<Duration> disconnects = [];
  final ChunkAssembler _assembler = ChunkAssembler();

  @override
  int mtu() => _mtu;

  @override
  Future<void> sendPackets(List<Uint8List> packets) async {
    for (final packet in packets) {
      final maxPacket = _mtu - 3 > 20 ? _mtu - 3 : 20;
      assert(packet.length <= maxPacket);
      final message = _assembler.feed(packet);
      if (message == null) continue;
      if (packet[0] == chunkMagic) {
        messages.add((json.decode(utf8.decode(message)) as Map)
            .cast<String, Object?>());
      } else {
        messages.add(utf8.decode(message));
      }
    }
  }

  @override
  void disconnect(Duration delay) {
    disconnects.add(delay);
  }
}

class _FakeNetwork implements SetupNetwork {
  _FakeNetwork({this.online = true});
  bool online;

  @override
  Future<bool> isOnline() async => online;

  @override
  Map<String, Object?> currentConnectionEntry() =>
      {'ssid': 'HomeNet', 'rssi': -40, 'secure': false};
}

Map<String, Object?> _hello(Map<String, Object?> vector,
    [Map<String, Object?> overrides = const {}]) {
  return {
    'action': 'pairing_client_hello',
    'version': 5,
    'pairing_auth': 'none',
    'pairing_policy': 'confirm_app',
    'mobile_pub': vector['mobile_pub'],
    'mobile_nonce': vector['mobile_nonce'],
    ...overrides,
  };
}

Map<String, Object?> _clientFinishedRecord(Map<String, Object?> vector) => {
      'action': 'pairing_encrypted',
      'session_id': vector['session_id'],
      'counter': '0',
      'ciphertext': vector['client_finished_ciphertext'],
      'tag': vector['client_finished_tag'],
    };

class _Harness {
  _Harness(
      {bool online = true,
      ProvisionRunner? provision,
      int mtu = 185,
      Map<String, Object?>? vector})
      : vector = vector ?? _appVector(),
        transport = _FakeTransport(mtu),
        network = _FakeNetwork(online: online) {
    final devicePoint = b64urlDecode(this.vector['device_pub'] as String);
    pairing = PairingSession(
      nodeId: this.vector['node_id'] as String,
      deviceId: this.vector['device_id'] as String,
      mac: this.vector['mac'] as String,
      firmwareVersion: this.vector['firmware_version'] as String,
      clock: () => 1000.0,
      generateKey: () async => P256KeyPair(
        d: _hex(this.vector['device_private_scalar_hex'] as String),
        x: devicePoint.sublist(1, 33),
        y: devicePoint.sublist(33, 65),
      ),
      randomBytes: (_) =>
          b64urlDecode(this.vector['device_nonce'] as String),
    );
    controller = SetupController(
      pairing: pairing,
      identity: Identity(this.vector['mac'] as String),
      version: this.vector['firmware_version'] as String,
      transport: transport,
      network: network,
      provision: provision ?? _defaultProvision,
      onComplete: () => completed.complete(),
    );
    mobile = _Mobile(this.vector);
  }

  final Map<String, Object?> vector;
  final _FakeTransport transport;
  final _FakeNetwork network;
  late final PairingSession pairing;
  late final SetupController controller;
  late final _Mobile mobile;
  final List<Credentials> saved = [];
  final Completer<void> completed = Completer<void>();

  Future<void> _defaultProvision(Credentials credentials,
      Future<bool> Function(Future<bool> Function()) commit) async {
    final ok = await commit(() async {
      saved.add(credentials);
      return true;
    });
    if (!ok) {
      throw const ProvisionFailed('error_storage');
    }
  }

  Future<void> send(Map<String, Object?> obj) =>
      controller.handleMessage(
          Uint8List.fromList(utf8.encode(json.encode(obj))));

  Future<void> sendEncrypted(Map<String, Object?> command) async {
    await send(await mobile.seal(command));
  }

  /// Run hello + client_finished from the vector.
  Future<void> pair() async {
    await send(_hello(vector));
    await send(_clientFinishedRecord(vector));
    mobile.txCounter = 1;
  }

  Future<List<Map<String, Object?>>> opened() async {
    final out = <Map<String, Object?>>[];
    // Snapshot: provisioning appends messages while records open.
    for (final message in List.of(transport.messages)) {
      if (message is Map<String, Object?> &&
          message['type'] == 'pairing_encrypted') {
        out.add(await mobile.open(message));
      }
    }
    return out;
  }

  Future<List<String>> statuses() async => [
        for (final m in await opened())
          if (m['type'] == 'status') m['status'] as String
      ];

  Future<void> waitForStatus(String status) async {
    final deadline =
        DateTime.now().add(const Duration(seconds: 5));
    while (!(await statuses()).contains(status)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('no $status; got ${await statuses()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

final Map<String, Object?> _provision = {
  'action': 'provision_v2',
  'ssid': 'HomeNet',
  'password': '',
  'access_token': 'device-access',
  'refresh_token': 'device-refresh',
  'token_type': 'device',
  'username': 'someone',
  'api_url': 'https://legacy-api.example',
  'api_url_v2': 'https://api.example',
};

void main() {
  group('ble setup', () {
    test('device info matches the pairing transcript fields', () async {
      final h = _Harness();
      await h.send({'action': 'get_device_info'});
      final info = h.transport.messages.last as Map;
      expect(info['type'], 'device_info');
      expect(info['node_id'], h.vector['node_id']);
      expect(info['version'], h.vector['firmware_version']);
      expect(info['model'], 'hatch_link');
      expect(info['pairing_protocol'], 5);
      expect(info['pairing_auth'], 'none');
      expect(info['pairing_policy'], 'confirm_app');
      expect(info['network_ready'], isTrue);
    });

    test('hello returns pairing ready in chunks at minimum mtu', () async {
      final h = _Harness(mtu: 23);
      await h.send(_hello(h.vector));
      final ready = h.transport.messages.last as Map;
      expect(ready['type'], 'pairing_ready');
      expect(ready['session_id'], h.vector['session_id']);
    });

    test('full setup flow', () async {
      final h = _Harness();
      await h.pair();
      expect(await h.statuses(), ['pairing_confirmed']);

      await h.sendEncrypted({'action': 'wifi_scan'});
      final scan = (await h.opened()).last;
      expect(scan, {
        'type': 'wifi_scan_result',
        'networks': [
          {'ssid': 'HomeNet', 'rssi': -40, 'secure': false}
        ],
      });

      await h.sendEncrypted(Map<String, Object?>.from(_provision));
      await h.waitForStatus('auth_ok');
      expect(await h.statuses(), [
        'pairing_confirmed',
        'wifi_connecting',
        'wifi_connected',
        'auth_ok',
      ]);
      expect(h.completed.isCompleted, isTrue);
      final saved = h.saved.single;
      expect(
          (saved.accessToken, saved.refreshToken, saved.username),
          ('device-access', 'device-refresh', 'someone'));
      expect((saved.apiUrl, saved.apiUrlV2),
          ('https://legacy-api.example', 'https://api.example'));
      expect(h.pairing.state, PairingState.provisioning);
    });

    test('setup commands need encryption', () async {
      final h = _Harness();
      await h.send({'action': 'wifi_scan'});
      await h.send(
          {'action': 'provision_v2', ..._provision});
      expect(h.transport.messages, [
        'error_encryption_required',
        'error_encryption_required',
      ]);
    });

    test('plaintext is ignored once pairing starts', () async {
      final h = _Harness();
      await h.send(_hello(h.vector));
      await h.send({'action': 'wifi_scan'});
      expect(h.transport.messages, hasLength(1));
    });

    test('device info is answered mid-session and a new hello restarts',
        () async {
      final h = _Harness();
      await h.pair();
      await h.send({'action': 'get_device_info'});
      final info = h.transport.messages.last as Map;
      expect(info['type'], 'device_info');
      expect(h.pairing.confirmed, isTrue);
      await h.send(_hello(h.vector));
      final ready = h.transport.messages.last as Map;
      expect(ready['type'], 'pairing_ready');
      expect(h.pairing.state, PairingState.waitClientFinished);
    });

    test('bad hello gets a plaintext error', () async {
      final h = _Harness();
      await h.send(
          _hello(h.vector, {'pairing_policy': 'confirm_press'}));
      expect(h.transport.messages, ['error_pairing_invalid_hello']);
    });

    test('decrypt failure disconnects without a plaintext reply', () async {
      final h = _Harness();
      await h.send(_hello(h.vector));
      final record = _clientFinishedRecord(h.vector);
      record['counter'] = '1';
      await h.send(record);
      expect(h.transport.messages, hasLength(1)); // just pairing_ready
      expect(h.transport.disconnects,
          [const Duration(milliseconds: 300)]);
      expect(h.pairing.state, PairingState.idle);
    });

    test('wrong first record means the session can never confirm', () async {
      final h = _Harness();
      await h.send(_hello(h.vector));
      await h.sendEncrypted({'action': 'wifi_scan'});
      expect(await h.statuses(), ['error_pairing_confirm_required']);
      await h.sendEncrypted({'action': 'pairing_client_finished'});
      expect(h.transport.disconnects,
          [const Duration(milliseconds: 300)]);
      expect(h.pairing.state, PairingState.idle);
    });

    test('provision requires device tokens', () async {
      final variants = [
        {'refresh_token': ''},
        {'token_type': 'user'},
        {'access_token': null},
        {'token_type': null},
      ];
      for (final change in variants) {
        final h = _Harness();
        await h.pair();
        await h.sendEncrypted(
            {..._provision, ...change});
        expect((await h.statuses()).last, 'error_missing_credentials',
            reason: 'for $change');
        expect(h.pairing.state, PairingState.ready);
      }
    });

    test('provision without wifi fields succeeds', () async {
      final h = _Harness();
      await h.pair();
      await h.sendEncrypted({
        'action': 'provision_v2',
        'access_token': 'device-access',
        'refresh_token': 'device-refresh',
        'token_type': 'device',
        'username': 'someone',
        'api_url_v2': 'https://api.example',
      });
      await h.waitForStatus('auth_ok');
      expect(h.saved.single.accessToken, 'device-access');
    });

    test('v1 provision action provisions like v2', () async {
      final h = _Harness();
      await h.pair();
      await h.sendEncrypted({..._provision, 'action': 'provision'});
      await h.waitForStatus('auth_ok');
      expect(h.saved.single.refreshToken, 'device-refresh');
    });

    test('offline device reports wifi failure and can retry', () async {
      final h = _Harness(online: false);
      await h.pair();
      await h.sendEncrypted({'action': 'wifi_scan'});
      expect((await h.opened()).last['networks'], isEmpty);

      await h.sendEncrypted(Map<String, Object?>.from(_provision));
      await h.waitForStatus('wifi_failed');
      expect(h.transport.disconnects, isEmpty);

      h.network.online = true;
      await h.sendEncrypted(Map<String, Object?>.from(_provision));
      await h.waitForStatus('auth_ok');
    });

    test('rejected token reports auth failed and disconnects', () async {
      Future<void> reject(Credentials credentials,
          Future<bool> Function(Future<bool> Function()) commit) async {
        throw const ProvisionFailed('auth_failed');
      }

      final h = _Harness(provision: reject);
      await h.pair();
      await h.sendEncrypted(Map<String, Object?>.from(_provision));
      await h.waitForStatus('auth_failed');
      expect(h.transport.disconnects,
          [const Duration(milliseconds: 500)]);
      expect(h.completed.isCompleted, isFalse);
    });

    test('disconnect clears the session', () async {
      final h = _Harness();
      await h.pair();
      h.controller.onDisconnect();
      expect(h.pairing.state, PairingState.idle);
      await h.send({'action': 'wifi_scan'});
      expect(h.transport.messages.last, 'error_encryption_required');
    });

    test('writes are reassembled before dispatch', () async {
      final h = _Harness();
      h.controller.start();
      try {
        final packets = encodeChunks(
            Uint8List.fromList(
                utf8.encode(json.encode(_hello(h.vector)))),
            23);
        for (final packet in packets) {
          h.controller.onWrite(packet);
        }
        final deadline =
            DateTime.now().add(const Duration(seconds: 5));
        while (h.transport.messages.isEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            fail('no reply to chunked hello');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      } finally {
        await h.controller.stop();
      }
      final first = h.transport.messages.first as Map;
      expect(first['type'], 'pairing_ready');
    });
  });
}
