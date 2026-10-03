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
// Dart port of the Muse Gadget SDK connection loop
// (linux/src/musegadget/service.py), adapted to the companion app.
//
// Keep a paired device connected to its Muse. Each round fetches the
// leased VMs with the device token (which also yields a fresh per-VM
// bearer), connects to the default VM and serves commands until the
// connection ends. Failures back off exponentially. A session that stayed
// up for a while resets the backoff. The device token is rotated before
// it expires, and immediately if the API rejects it.

import 'dart:async';

import 'package:http/http.dart' as http;

import 'identity.dart';
import 'link_client.dart';
import 'muse_api.dart';

const String defaultNoiseHost = 'hatch.metaaivm.com';
const double backoffBaseS = 2.0;
const double backoffMaxS = 60.0;
const double authBackoffMinS = 15.0;
const double healthySessionS = 30.0;
const double unpairedPollS = 30.0;

/// Device access tokens live about 4 hours; rotate at 3.
const double tokenRefreshAgeS = 3 * 3600;
const double tokenRetryS = 300;

/// UI-facing connection state.
enum ConnectionState {
  /// No pairing saved.
  unpaired,

  /// Working towards a session (fetching VMs, handshaking, registering).
  connecting,

  /// Registered with the Muse and serving commands.
  connected,

  /// Between attempts; [GadgetService.statusDetail] says when/why.
  waiting,

  /// Stopped by the user.
  stopped,
}

/// Persists the pairing record; implemented with secure storage in the app.
abstract class PairingStore {
  Future<Map<String, Object?>?> load();
  Future<void> save(Map<String, Object?> pairing);
  Future<void> delete();
}

/// In-memory store for tests and previews.
class MemoryPairingStore implements PairingStore {
  Map<String, Object?>? _pairing;

  @override
  Future<Map<String, Object?>?> load() async => _pairing == null
      ? null
      : Map<String, Object?>.from(_pairing!);

  @override
  Future<void> save(Map<String, Object?> pairing) async {
    _pairing = Map<String, Object?>.from(pairing);
  }

  @override
  Future<void> delete() async {
    _pairing = null;
  }
}

class Backoff {
  int failures = 0;
  double floor = 0;

  double nextDelay() {
    var delay = backoffBaseS * (1 << failures);
    if (delay > backoffMaxS) delay = backoffMaxS;
    failures += 1;
    return delay > floor ? delay : floor;
  }

  void reset() {
    failures = 0;
    floor = 0;
  }
}

typedef ServiceLogger = void Function(String message);

void _nullLogger(String message) {}

class GadgetService {
  GadgetService({
    required Identity identity,
    required Map<String, Object?> commands,
    required RunCommand runCommand,
    required PairingStore pairingStore,
    required String version,
    String? sdkToken,
    String displayName = 'Muse Companion',
    LinkConnector? connect,
    http.Client? httpClient,
    ServiceLogger logger = _nullLogger,
  })  : _identity = identity,
        _commands = commands,
        _runCommand = runCommand,
        _pairingStore = pairingStore,
        _version = version,
        _sdkToken = sdkToken,
        _displayName = displayName,
        _connect = connect,
        _httpClient = httpClient,
        _logger = logger;

  final Identity _identity;
  final Map<String, Object?> _commands;
  final RunCommand _runCommand;
  final PairingStore _pairingStore;
  final String _version;
  String? _sdkToken;
  final String _displayName;
  final LinkConnector? _connect;
  final http.Client? _httpClient;
  final ServiceLogger _logger;

  final StreamController<ConnectionState> _state =
      StreamController<ConnectionState>.broadcast();

  ConnectionState _connectionState = ConnectionState.stopped;
  String _statusDetail = '';
  bool _stopRequested = false;
  Completer<void>? _stopCompleter;
  Completer<void>? _sleepCompleter;
  Timer? _sleepTimer;
  double _lastRefreshAttempt = double.negativeInfinity;
  bool _sdkTokenReportAttempted = false;
  LinkSession? _current;
  String? _agentName;
  Future<void>? _loop;

  /// Broadcast connection-state changes for the UI.
  Stream<ConnectionState> get onStateChanged => _state.stream;

  ConnectionState get connectionState => _connectionState;

  /// Human-readable detail for [ConnectionState.waiting]/connecting.
  String get statusDetail => _statusDetail;

  /// Agent display name from the last identity fetch, if any.
  String? get agentName => _agentName;

  bool get isRegistered => _current?.registeredAt != null;

  Identity get identity => _identity;

  void _setState(ConnectionState state, [String detail = '']) {
    _connectionState = state;
    _statusDetail = detail;
    if (!_state.isClosed) {
      _state.add(state);
    }
  }

  /// Start the connection loop (idempotent while running).
  Future<void> start() {
    if (_loop != null) return _loop!;
    _stopRequested = false;
    _stopCompleter = Completer<void>();
    _loop = _run().whenComplete(() {
      _loop = null;
    });
    return _loop!;
  }

  /// Stop the loop and close the session.
  Future<void> stop() async {
    _stopRequested = true;
    final stopper = _stopCompleter;
    if (stopper != null && !stopper.isCompleted) {
      stopper.complete();
    }
    _wakeSleeper();
    await _loop;
    _setState(ConnectionState.stopped);
  }

  /// Cut any current backoff or poll sleep short.
  ///
  /// The pairing wizard calls this after a new pairing is committed so
  /// the loop picks it up immediately instead of sleeping out the
  /// unpaired poll. Safe to call any time, even while stopped.
  void wake() {
    _wakeSleeper();
  }

  void _wakeSleeper() {
    final sleeper = _sleepCompleter;
    if (sleeper != null && !sleeper.isCompleted) {
      sleeper.complete();
    }
    _sleepTimer?.cancel();
  }

  /// Send a message to the Muse from this device.
  Future<Map<String, Object?>> sendChat(String message,
      [String? sessionId]) async {
    final session = _current;
    if (session == null || session.registeredAt == null) {
      return {'ok': false, 'error': 'not connected to the Muse'};
    }
    return session.sendChat(message, sessionId);
  }

  /// Forget the saved pairing. The device identity is kept.
  Future<void> unpair() async {
    await _pairingStore.delete();
    _agentName = null;
  }

  /// Update the SDK token reported on token refresh (null clears it).
  ///
  /// The next loop pass reports a newly set token, even when no rotation
  /// is due; clearing it stops reporting without touching the pairing.
  void setSdkToken(String? token) {
    _sdkToken = (token == null || token.isEmpty) ? null : token;
    _sdkTokenReportAttempted = false;
  }

  Future<void> _run() async {
    final backoff = Backoff();
    while (!_stopRequested) {
      final pairing = await _pairingStore.load();
      if (pairing == null) {
        _logger('not paired; pair from the Muse app to set up');
        _setState(ConnectionState.unpaired);
        await _sleep(unpairedPollS);
        continue;
      }
      final current = await _maybeRefresh(pairing);
      if (current == null) {
        await _sleep(tokenRetryS);
        continue;
      }

      _setState(ConnectionState.connecting, 'finding your Muse…');
      final api = apiRoot(_string(current, 'api_url_v2'));
      final fetched = await fetchVmsWithStatus(
        _string(current, 'access_token'),
        root: api,
        version: _version,
        client: _httpClient,
      );
      if (_stopRequested) break;
      if (fetched.status == 401) {
        _logger('device token rejected by the API; refreshing');
        if (await _maybeRefresh(current, force: true) == null) {
          await _sleep(tokenRetryS);
        }
        continue;
      }
      LeasedVm? vm;
      for (final candidate in fetched.vms) {
        if (candidate.isDefault) vm = candidate;
      }
      vm ??= fetched.vms.isNotEmpty ? fetched.vms.first : null;
      if (vm == null) {
        final delay = backoff.nextDelay();
        _logger('no VMs leased; retrying');
        _setState(ConnectionState.waiting, _waitingDetail(delay, 'no Muse is available'));
        await _sleep(delay);
        continue;
      }

      final (outcome, lasted) = await _session(vm, current);
      if (_stopRequested || outcome == Outcome.stopped) break;
      if (outcome == Outcome.unpaired) {
        await _pairingStore.delete();
        _agentName = null;
        _logger('pairing removed; pair again to set up');
        _setState(ConnectionState.unpaired);
        continue;
      }
      if (lasted >= healthySessionS) {
        backoff.reset();
      }
      if (outcome == Outcome.authRejected || outcome == Outcome.forbidden) {
        backoff.floor = authBackoffMinS;
      }
      final delay = backoff.nextDelay();
      _logger('reconnecting in ${delay.toStringAsFixed(0)}s');
      _setState(ConnectionState.waiting,
          _waitingDetail(delay, _outcomeDetail(outcome)));
      await _sleep(delay);
    }
  }

  String _waitingDetail(double delay, String reason) =>
      '$reason — retrying in ${delay.toStringAsFixed(0)}s';

  String _outcomeDetail(Outcome outcome) {
    switch (outcome) {
      case Outcome.closed:
        return 'connection ended';
      case Outcome.authRejected:
        return 'VM credentials refused';
      case Outcome.forbidden:
        return 'not allowed right now';
      case Outcome.unpaired:
        return 'unpaired';
      case Outcome.stopped:
        return 'stopped';
    }
  }

  Future<(Outcome, double)> _session(
      LeasedVm vm, Map<String, Object?> pairing) async {
    final device = DeviceDescription(
      nodeId: _identity.nodeId,
      displayName: _displayName,
      version: _version,
      commands: _commands,
    );
    final stopCompleter = _stopCompleter;
    final session = LinkSession(
      noiseHost: _string(pairing, 'noise_host', defaultNoiseHost),
      vmId: vm.vmId.isNotEmpty ? vm.vmId : vm.vmName,
      vmAuthToken: vm.vmAuthToken,
      device: device,
      runCommand: _runCommand,
      userAgent: userAgent(_version),
      connect: _connect,
    );
    session.onStatus = (status) {
      if (status.startsWith('identity:')) {
        _agentName = status.substring('identity:'.length);
        if (_connectionState == ConnectionState.connected) {
          _setState(ConnectionState.connected, _agentName ?? '');
        }
      }
    };
    session.onRegistered = () {
      _setState(ConnectionState.connected, _agentName ?? 'registered');
    };
    _logger('connecting to ${vm.vmName.isNotEmpty ? vm.vmName : vm.vmId}');
    _setState(ConnectionState.connecting, 'connecting to your Muse…');
    _current = session;
    _setState(ConnectionState.connecting, 'registering…');
    Outcome outcome;
    try {
      outcome = await session.run(
          stopCompleter == null ? null : () => stopCompleter.future);
    } catch (e) {
      _logger('session failed: $e');
      outcome = Outcome.closed;
    } finally {
      if (identical(_current, session)) {
        _current = null;
      }
    }
    final registeredAt = session.registeredAt;
    final lasted = registeredAt == null
        ? 0.0
        : DateTime.now().difference(registeredAt).inMilliseconds / 1000;
    _logger('session ended: ${outcome.name}');
    return (outcome, lasted);
  }

  /// Return current pairing, rotating tokens first if they are due.
  ///
  /// Returns null only when a due refresh failed and the old token should
  /// not be used yet; the pairing is deleted when it has been revoked.
  Future<Map<String, Object?>?> _maybeRefresh(Map<String, Object?> pairing,
      {bool force = false}) async {
    final savedAt = pairing['access_token_saved_at'];
    final age = DateTime.now().millisecondsSinceEpoch / 1000 -
        (savedAt is num ? savedAt.toDouble() : 0);
    final sdkToken = _sdkToken;
    final reportDue = sdkToken != null &&
        sdkToken.isNotEmpty &&
        !_sdkTokenReportAttempted;
    final due = force || age >= tokenRefreshAgeS;
    if (!due && !reportDue) {
      return pairing;
    }
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    if (!force && now - _lastRefreshAttempt < tokenRetryS) {
      return pairing;
    }
    _lastRefreshAttempt = now;
    if (reportDue) {
      _sdkTokenReportAttempted = true;
      _logger('refreshing device token to report the SDK token');
    }
    final refreshed = await refreshDeviceToken(
      _string(pairing, 'refresh_token'),
      _identity.nodeId,
      root: apiRoot(_string(pairing, 'api_url_v2')),
      sdkToken: _sdkToken,
      version: _version,
      client: _httpClient,
    );
    if (refreshed.tokens != null) {
      final next = Map<String, Object?>.from(pairing)
        ..['access_token'] = refreshed.tokens!['access_token']!
        ..['refresh_token'] = refreshed.tokens!['refresh_token']!
        ..['access_token_saved_at'] =
            DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _pairingStore.save(next);
      _logger('device token rotated');
      // A successful rotation also reports the SDK token.
      _sdkTokenReportAttempted = true;
      return next;
    }
    if (!due) {
      // Only reporting the SDK token: nothing has rejected the current
      // token, so a refusal here must never unpair the device.
      _logger('SDK token report refresh failed; keeping the pairing');
      return pairing;
    }
    if (refreshed.status == 401) {
      await _pairingStore.delete();
      _logger('pairing revoked; pair again to set up');
      _setState(ConnectionState.unpaired);
      return null;
    }
    // Transient failure: keep using the current token while it still works.
    return force ? null : pairing;
  }

  Future<void> _sleep(double seconds) async {
    if (_stopRequested) return;
    final completer = Completer<void>();
    _sleepCompleter = completer;
    // A real Timer stored on the instance so an early wake via _wakeSleeper
    // cancels it synchronously instead of leaving a dangling Future.delayed
    // timer pending until it fires.
    _sleepTimer?.cancel();
    _sleepTimer = Timer(
      Duration(milliseconds: (seconds * 1000).round()),
      () {
        if (identical(_sleepCompleter, completer)) {
          _sleepCompleter = null;
          completer.complete();
        }
      },
    );
    try {
      await completer.future;
    } finally {
      _sleepTimer = null;
    }
  }

  String _string(Map<String, Object?> map, String key,
      [String fallback = '']) {
    final value = map[key];
    return value is String ? value : fallback;
  }
}
