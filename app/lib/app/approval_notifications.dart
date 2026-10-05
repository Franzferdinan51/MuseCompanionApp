// Notification-based approval fallback.
//
// Ported concept from hermes-mobile-app (MIT, Omar Qaterge): when the app
// is NOT in the foreground, approval requests arrive as Android
// notifications with inline action buttons (their HermesService.java
// `case "approval"` posts Allow once / Allow session / Deny). Tapping an
// action completes the same ApprovalRequest the agent is awaiting WITHOUT
// opening the app. While a request is pending and unanswered, the
// notification re-posts on a cadence until it is answered or times out
// (their `tickApproval` / `reAlertApproval` pattern; they tick every 1s and
// re-alert at 20s/40s — we re-post every 10s, which re-triggers heads-up).
//
// When the app IS foregrounded the in-app dialog owns the request and no
// notification is posted (see ui/approval_prompt.dart).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'approval_service.dart';

/// Notification action ids. The body tap carries no action id: it opens
/// the app and the in-app dialog takes over.
const String _actionAllowOnce = 'appr_allow_once';
const String _actionAllowSession = 'appr_allow_session';
const String _actionDeny = 'appr_deny';

const String _channelId = 'approval_requests';
const String _channelName = 'Approval requests';
const String _channelDescription = 'Agent action approval prompts';

/// How often a pending, unanswered approval re-posts its notification.
const Duration _reAlertInterval = Duration(seconds: 10);

/// Entry-point for notification responses (incl. action taps while the app
/// was backgrounded). Completing here is safe even with no active request:
/// [ApprovalService.answerWithChoice] is a no-op for unknown ids.
@pragma('vm:entry-point')
void approvalNotificationResponseHandler(NotificationResponse response) {
  ApprovalNotifications.instance.handleResponse(response);
}

/// Posts approval notifications and re-alerts until requests settle.
/// Wired as [ApprovalService.notificationSink] at app startup.
class ApprovalNotifications with WidgetsBindingObserver
    implements ApprovalNotificationSink {
  ApprovalNotifications._();

  /// App-wide instance.
  static final ApprovalNotifications instance = ApprovalNotifications._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _attached = false;
  bool _ready = false;
  bool _isForeground = true;

  /// request id -> posted notification id.
  final Map<String, int> _notifIds = <String, int>{};
  int _nextNotifId = 0xA990000;

  /// request id -> re-alert timer.
  final Map<String, Timer> _timers = <String, Timer>{};

  /// True when the app is currently foregrounded.
  bool get isForeground => _isForeground;

  /// Start observing lifecycle and initialize the notification plugin.
  /// Idempotent; safe to call before the binding is ready as long as it
  /// has been ensured (main() does this first).
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    _isForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse:
            approvalNotificationResponseHandler,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.high,
          ));
      _ready = true;
    } catch (e) {
      // Notifications unavailable (e.g. unsupported platform): the in-app
      // dialog path keeps working.
      debugPrint('[approvals] notification init failed: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    if (_isForeground) {
      // The in-app dialog takes over; drop any posted approval
      // notifications and stop re-alerting so they don't fight the dialog.
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
      for (final id in _notifIds.values) {
        unawaited(_cancel(id));
      }
      _notifIds.clear();
    }
  }

  @override
  void onApprovalActivated(ApprovalRequest request) {
    // Foregrounded: the in-app dialog owns this request.
    if (_isForeground) return;
    unawaited(_postWithReAlert(request));
  }

  @override
  void onApprovalSettled(ApprovalRequest request) {
    _timers.remove(request.id)?.cancel();
    final id = _notifIds.remove(request.id);
    if (id != null) unawaited(_cancel(id));
  }

  /// Handle a notification response: an action tap answers the request
  /// (completing the agent's future) without opening the app. A body tap
  /// carries no action id and is ignored here — opening the app surfaces
  /// the in-app dialog via the listener's resume path.
  void handleResponse(NotificationResponse response) {
    final actionId = response.actionId;
    if (actionId == null || actionId.isEmpty) return;
    final choice = switch (actionId) {
      _actionAllowOnce => ApprovalChoice.allowOnce,
      _actionAllowSession => ApprovalChoice.allowSession,
      _actionDeny => ApprovalChoice.deny,
      _ => null,
    };
    if (choice == null) return;
    final requestId = response.payload;
    if (requestId == null || requestId.isEmpty) return;
    ApprovalService.instance.answerWithChoice(requestId, choice);
  }

  Future<void> _postWithReAlert(ApprovalRequest request) async {
    if (!_ready) {
      await attach();
      if (!_ready) return;
    }
    if (request.isCompleted) return;
    await _post(request);
    _timers[request.id]?.cancel();
    _timers[request.id] = Timer.periodic(_reAlertInterval, (_) {
      if (request.isCompleted) {
        _timers.remove(request.id)?.cancel();
        return;
      }
      unawaited(_post(request));
    });
  }

  Future<void> _post(ApprovalRequest request) async {
    try {
      final id = _notifIds.putIfAbsent(request.id, () => _nextNotifId++);
      await _plugin.show(
        id: id,
        title: 'Approval needed',
        body: request.title,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            ticker: 'Approval needed: ${request.title}',
            styleInformation: BigTextStyleInformation(request.body),
            autoCancel: true,
            actions: const <AndroidNotificationAction>[
              AndroidNotificationAction(
                _actionAllowOnce,
                'Allow once',
                showsUserInterface: false,
                cancelNotification: true,
              ),
              AndroidNotificationAction(
                _actionAllowSession,
                'Allow session',
                showsUserInterface: false,
                cancelNotification: true,
              ),
              AndroidNotificationAction(
                _actionDeny,
                'Deny',
                showsUserInterface: false,
                cancelNotification: true,
              ),
            ],
          ),
        ),
        payload: request.id,
      );
    } catch (e) {
      debugPrint('[approvals] notification post failed: $e');
    }
  }

  Future<void> _cancel(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (e) {
      debugPrint('[approvals] notification cancel failed: $e');
    }
  }
}
