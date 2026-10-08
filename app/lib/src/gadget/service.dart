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
import 'dart:math';

import 'package:http/http.dart' as http;

import 'chat_events.dart';
import 'commands.dart';
import 'identity.dart';
import 'link_client.dart';
import 'muse_api.dart';
import '../../app/activity_log.dart';

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
    // +/-20% jitter so retries don't hammer in lockstep.
    delay *= 0.8 + 0.4 * _random.nextDouble();
    return delay > floor ? delay : floor;
  }

  void reset() {
    failures = 0;
    floor = 0;
  }
}

final Random _random = Random();

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
    this.onCharacterUrl,
    bool introSent = false,
    this.persistIntro,
  })  : _identity = identity,
        _commands = commands,
        _runCommand = runCommand,
        _pairingStore = pairingStore,
        _version = version,
        _sdkToken = sdkToken,
        _displayName = displayName,
        _connect = connect,
        _httpClient = httpClient,
        _logger = logger,
        _introSent = introSent;

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

  /// Draws a character image discovered on `GET /identity`.
  /// Returns true when the image was drawn; the service retries and
  /// eventually re-sends the intro when it keeps failing.
  final Future<bool> Function(String url)? onCharacterUrl;

  /// Remembers that the setup message was accepted, across app launches.
  /// Called with false when the pairing is removed.
  final Future<void> Function(bool sent)? persistIntro;

  final StreamController<ConnectionState> _state =
      StreamController<ConnectionState>.broadcast();
  final StreamController<ChatEvent> _chatEvents =
      StreamController<ChatEvent>.broadcast();

  /// Server-sent display cards (hermes-gadget-sdk `display`).
  final StreamController<DisplayCard> _displayCards =
      StreamController<DisplayCard>.broadcast();

  /// Server-sent transient one-liners (hermes-gadget-sdk `notice`).
  final StreamController<String> _notices =
      StreamController<String>.broadcast();

  /// Server-sent live working-state text (hermes-gadget-sdk `status`).
  /// Empty string clears it.
  final StreamController<String> _workingStatus =
      StreamController<String>.broadcast();

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
  bool _introSent;
  bool _introSkipLogged = false;
  int _invokesSeen = 0;
  int _resultsSent = 0;
  String _lastCommand = '';
  String _lastCommandResult = '';
  final List<String> _linkLog = [];
  final StreamController<void> _linkEvents =
      StreamController<void>.broadcast();

  /// Broadcast connection-state changes for the UI.
  Stream<ConnectionState> get onStateChanged => _state.stream;

  /// Assistant events from `/chat/subscribe`.
  Stream<ChatEvent> get onChatEvent => _chatEvents.stream;

  /// Display cards from the server. The UI shows title + body until
  /// ttlSeconds elapses (0 = until dismissed).
  Stream<DisplayCard> get onDisplayCard => _displayCards.stream;

  /// Transient one-line notices from the server.
  Stream<String> get onNotice => _notices.stream;

  /// Live working-state text from the server ("" clears it).
  Stream<String> get onWorkingStatus => _workingStatus.stream;

  ConnectionState get connectionState => _connectionState;

  /// Human-readable detail for [ConnectionState.waiting]/connecting.
  String get statusDetail => _statusDetail;

  /// Agent display name from the last identity fetch, if any.
  String? get agentName => _agentName;

  bool get isRegistered => _current?.registeredAt != null;

  /// Commands the phone has seen on the link since this process started.
  int get invokesSeen => _invokesSeen;

  /// `link.result` messages the phone has sent.
  int get resultsSent => _resultsSent;

  /// Last command name, without its result.
  String get lastCommand => _lastCommand;

  /// `command:ok` or `command:error` for the last result that left the phone.
  String get lastCommandResult => _lastCommandResult;

  /// Recent link log lines, oldest first. Capped at 30.
  List<String> get linkLog => List.unmodifiable(_linkLog);

  /// Fires when [linkLog] or the command counters change.
  Stream<void> get onLink => _linkEvents.stream;

  void _log(String message) {
    _logger(message);
    final line = message.length > 180 ? message.substring(0, 180) : message;
    _linkLog.add(line);
    if (_linkLog.length > 30) {
      _linkLog.removeAt(0);
    }
    if (!_linkEvents.isClosed) _linkEvents.add(null);
  }

  Identity get identity => _identity;

  void _setState(ConnectionState state, [String detail = '']) {
    final changed = _connectionState != state;
    _connectionState = state;
    _statusDetail = detail;
    if (!_state.isClosed) {
      _state.add(state);
    }
    // Mirror connection changes to the Activity tab.
    if (changed) {
      final label = switch (state) {
        ConnectionState.connected => 'Connected to Muse',
        ConnectionState.connecting => 'Connecting to Muse',
        ConnectionState.waiting => 'Waiting for Muse',
        ConnectionState.unpaired => 'Unpaired',
        ConnectionState.stopped => 'Service stopped',
      };
      ActivityLog.instance.add(
        ActivityKind.system,
        label,
        detail: detail,
        ok: state != ConnectionState.unpaired,
      );
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
  ///
  /// [attachments] carry a voice note or a camera frame. The returned map
  /// is the post acknowledgement; the reply is delivered on [onChatEvent].
  Future<Map<String, Object?>> sendChat(String message,
      [String? sessionId,
      List<ChatAttachment> attachments = const []]) async {
    final session = _current;
    if (session == null || session.registeredAt == null) {
      return {'ok': false, 'error': 'not connected to the Muse'};
    }
    return session.sendChat(message, sessionId, attachments);
  }

  /// Forget the saved pairing. The device identity is kept.
  Future<void> unpair() async {
    await _pairingStore.delete();
    _agentName = null;
    await _clearIntro();
  }

  Future<void> _clearIntro() async {
    _introSent = false;
    _introSkipLogged = false;
    final persist = persistIntro;
    if (persist != null) await persist(false);
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
        _log('not paired; pair from the Muse app to set up');
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
        _log('device token rejected by the API; refreshing');
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
        _log('no VMs leased; retrying');
        _setState(ConnectionState.waiting, _waitingDetail(delay, 'no Muse is available'));
        await _sleep(delay);
        continue;
      }

      final (outcome, lasted) = await _session(vm, current);
      if (_stopRequested || outcome == Outcome.stopped) break;
      if (outcome == Outcome.unpaired) {
        await _pairingStore.delete();
        _agentName = null;
        await _clearIntro();
        _log('pairing removed; pair again to set up');
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
      _log('reconnecting in ${delay.toStringAsFixed(0)}s');
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
      _log(status);
      if (status.startsWith('identity:')) {
        _agentName = status.substring('identity:'.length);
        if (_connectionState == ConnectionState.connected) {
          _setState(ConnectionState.connected, _agentName ?? '');
        }
      } else if (status.startsWith('invoke:')) {
        _invokesSeen += 1;
        _lastCommand = status.substring('invoke:'.length);
      } else if (status.startsWith('result:')) {
        _resultsSent += 1;
        _lastCommandResult = status.substring('result:'.length);
      }
    };
    session.onIdentity = (result) {
      final url = avatarUrlFromIdentity(result);
      final draw = onCharacterUrl;
      if (url != null && draw != null) {
        unawaited(_drawCharacterWithRetry(draw, url));
      }
    };
    session.onChatEvent = (event) {
      if (!_chatEvents.isClosed) _chatEvents.add(event);
    };
    session.onDisplayCard = (title, body, ttlSeconds) {
      if (!_displayCards.isClosed) {
        _displayCards.add(DisplayCard(
          title: title,
          body: body,
          ttl: Duration(seconds: ttlSeconds),
        ));
      }
    };
    session.onNotice = (text) {
      if (text.isNotEmpty && !_notices.isClosed) _notices.add(text);
    };
    session.onWorkingStatus = (text) {
      if (!_workingStatus.isClosed) _workingStatus.add(text);
    };
    session.onRegistered = () {
      _setState(ConnectionState.connected, _agentName ?? 'registered');
    };
    session.onSubscribed = () {
      unawaited(_introduce(session));
    };
    _log('connecting to ${vm.vmName.isNotEmpty ? vm.vmName : vm.vmId}');
    _setState(ConnectionState.connecting, 'connecting to your Muse…');
    _current = session;
    _setState(ConnectionState.connecting, 'registering…');
    Outcome outcome;
    try {
      outcome = await session.run(
          stopCompleter == null ? null : () => stopCompleter.future);
    } catch (e) {
      _log('session failed: $e');
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
    _log('session ended: ${outcome.name}');
    return (outcome, lasted);
  }

  /// Draw the Muse character from the identity URL, retrying transient
  /// failures before giving up.
  ///
  /// Fresh installs used to sit on the generic logo forever when the first
  /// draw failed: the intro was already marked sent, so no later session
  /// retried it. Now a draw that keeps failing resets the intro flag, so
  /// the next session asks the Muse for its character again.
  Future<void> _drawCharacterWithRetry(
      Future<bool> Function(String url) draw, String url) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (await draw(url)) {
          _log('character drawn from identity');
          return;
        }
        _log('character draw not applied, attempt ${attempt + 1}');
      } catch (e) {
        _log('character draw failed, attempt ${attempt + 1}: $e');
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    _log('character draw failed after 3 attempts; intro will be retried');
    _introSent = false;
    final persist = persistIntro;
    if (persist != null) unawaited(persist(false));
  }

  /// Ask the Muse to draw its character, once per pairing.
  ///
  /// The acceptance is persisted by [persistIntro]. Opening the app again
  /// must not post the initialize message a second time. A rejected post
  /// is retried on a later session. Unpair clears the flag.
  Future<void> _introduce(LinkSession session) async {
    if (_introSent) {
      if (!_introSkipLogged) {
        _introSkipLogged = true;
        _log('setup message already sent');
      }
      return;
    }
    if (!identical(_current, session) || session.registeredAt == null) return;
    // Claim the send before the await so a second subscribe cannot post
    // another copy while this one is in flight.
    _introSent = true;
    final result = await session.sendChat(companionIntroMessage());
    if (!identical(_current, session)) return;
    if (result['ok'] == true) {
      _log('asked the Muse for its character');
      final persist = persistIntro;
      if (persist != null) unawaited(persist(true));
    } else {
      _introSent = false;
      _log('character intro was not accepted: ${result['error'] ?? result['status']}');
    }
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
      _log('refreshing device token to report the SDK token');
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
      _log('device token rotated');
      // A successful rotation also reports the SDK token.
      _sdkTokenReportAttempted = true;
      return next;
    }
    if (!due) {
      // Only reporting the SDK token: nothing has rejected the current
      // token, so a refusal here must never unpair the device.
      _log('SDK token report refresh failed; keeping the pairing');
      return pairing;
    }
    if (refreshed.status == 401) {
      await _pairingStore.delete();
      await _clearIntro();
      _log('pairing revoked; pair again to set up');
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

/// A card overlay pushed by the server (hermes-gadget-sdk `display`).
class DisplayCard {
  const DisplayCard({
    required this.title,
    required this.body,
    required this.ttl,
  });

  final String title;
  final String body;

  /// How long to show it; zero means until dismissed.
  final Duration ttl;
}
