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
// App entry point. Wires the gadget protocol stack (service + commands) to
// the full-color companion UI: a stable persisted identity, the companion
// command set sized to the real display, the real CompanionExecutor as the
// service's RunCommand, and the presentation state that drives the screen.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:muse_companion/app/avatar_motion.dart';
import 'package:muse_companion/app/ble_peripheral.dart';
import 'package:muse_companion/app/captions.dart';
import 'package:muse_companion/app/chat.dart';
import 'package:muse_companion/app/companion_platform.dart';
import 'package:muse_companion/app/foreground.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/app/phone_bridge.dart';
import 'package:muse_companion/app/storage.dart';
import 'package:muse_companion/src/gadget/chat_events.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';
import 'package:muse_companion/src/gadget/commands.dart';
import 'package:muse_companion/src/gadget/service.dart';

import 'ui/companion_screen.dart';
import 'ui/muse_theme.dart';
import 'ui/scope.dart';

const String _appVersion = '0.2.7';

/// Edge-to-edge, with the status and navigation bars hidden until a swipe.
Future<void> _enterImmersive() {
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0x00000000),
      systemNavigationBarColor: Color(0x00000000),
      systemNavigationBarContrastEnforced: false,
    ),
  );
  return SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _enterImmersive();
  initForegroundSupport();
  initLinkService();

  final settings = await SettingsStore.init();
  final identity = await PersistentIdentity.loadOrCreate(
    const FlutterSecureStorage(),
  );
  final presentation = PresentationState(settings: settings.loadSettings());
  final savedStatus = settings.loadStatus();
  if (savedStatus.isNotEmpty) {
    presentation.applyStatus(savedStatus);
  }
  final cachedCharacter = await AppCompanionDisplay.loadCachedCharacter();
  if (cachedCharacter != null) {
    presentation.applyCharacter(cachedCharacter);
    // The portrait is already on the phone, so the setup message has done
    // its job. Remember that before the link comes up.
    if (!settings.loadIntroSent()) {
      await settings.saveIntroSent(true);
    }
  } else {
    // Fresh install: load the generic Muse logo as the default character.
    // The user's personal avatar is fetched on pairing via the avatar URL
    // mechanism (chat replies or link registration).
    try {
      final data = await rootBundle.load('assets/brand/juno-logo-glossy.png');
      presentation.applyCharacter(data.buffer.asUint8List());
      debugPrint('[muse] loaded generic logo as default character');
    } catch (e) {
      debugPrint('[muse] could not load default character: $e');
    }
  }

  final health = AppCompanionHealth(appVersion: _appVersion);
  final display = AppCompanionDisplay(
    listener: _DisplayListener(presentation),
    settings: settings,
  );
  final phone = const PhoneBridge();
  await phone.applySpeechVoice(presentation.settings.speechVoice);
  final poster = _ChatPoster();
  final autoCapture = _AutoCaptureScheduler(
    settings: settings,
    phone: phone,
    poster: poster,
  );
  autoCapture.sync();
  // Re-sync when settings change (presentation notifies via settings).
  settings.addListener(autoCapture.sync);
  // Push USB toggles to native so phone.capabilities reflects them.
  Future<void> syncUsbToggles() async {
    final s = presentation.settings;
    await phone.applyUsbToggles(
      storageEnabled: s.usbStorageEnabled,
      serialEnabled: s.usbSerialEnabled,
    );
  }

  await syncUsbToggles();
  settings.addListener(() {
    // ignore: unawaited_futures
    syncUsbToggles();
  });
  final executor = CompanionExecutor(
    display: display,
    health: health,
    phone: phone,
    postToMuse: poster.send,
    allowCalls: () => presentation.settings.allowCalls,
    allowSendSms: () => presentation.settings.allowSendSms,
    cameraFacing: () => presentation.settings.cameraFacing,
    usbStorageEnabled: () => presentation.settings.usbStorageEnabled,
    usbSerialEnabled: () => presentation.settings.usbSerialEnabled,
    lmStudioEnabled: () => presentation.settings.lmStudioEnabled,
    lmStudioUrl: () => presentation.settings.lmStudioUrl,
    lmStudioModel: () => presentation.settings.lmStudioModel,
  );

  final screen = _screenSize();
  final pairingStore = SecurePairingStore();
  final sdkTokens = SecureSdkTokenStore();
  final savedSdkToken = await sdkTokens.load();
  final service = GadgetService(
    identity: identity.identity,
    commands: companionCommandSpecs(
      screenWidth: screen.width,
      screenHeight: screen.height,
    ),
    runCommand: executor.run,
    pairingStore: pairingStore,
    version: _appVersion,
    sdkToken: savedSdkToken?.isEmpty == true ? null : savedSdkToken,
    displayName: 'Muse Companion',
    logger: (message) => debugPrint('[muse] $message'),
    introSent: settings.loadIntroSent(),
    persistIntro: settings.saveIntroSent,
    onCharacterUrl: (url) async {
      await executor.run('display.draw_url', {'url': url}, null);
    },
  );
  poster.bind(service);
  final chat = ChatHistory();
  service.onChatEvent.listen((event) {
    chat.applyServerEvent(event.event, event.payload);
  });
  // The on-screen Muse gadgets put the reply under the character while
  // it streams, then speak a short form of it. The full text stays in chat.
  chat.onCaption = (text) {
    final caption = captionFromReply(text);
    if (caption.isNotEmpty) presentation.applyStatus(caption);
    // Thinking only while tokens are still arriving. The done event, and
    // the message.assistant copy after it, must not pin the face.
    if (captionSetsThinking(
      streaming: chat.assistantStreaming,
      pose: presentation.pose,
    )) {
      presentation.applyPose(AvatarPose.thinking);
    }
  };
  chat.onActivity = (code) {
    final line = activityCaption(code);
    if (line != null) presentation.applyStatus(line);
    if (activitySetsPose(code, streaming: chat.assistantStreaming)) {
      presentation.applyPose(poseForActivity(code));
    }
  };
  chat.onHeard = (text) {
    final caption = captionFromReply(text);
    if (caption.isNotEmpty) presentation.applyStatus(caption);
  };
  chat.onAssistantDone = (text) {
    final image = httpsImageUrlInReply(text);
    if (image != null) {
      final host = Uri.tryParse(image)?.host;
      debugPrint(
        '[muse] drawing character from chat'
        '${host == null || host.isEmpty ? '' : ' ($host)'}',
      );
      unawaited(_drawChatCharacter(display, image));
    }
    final caption = captionFromReply(text);
    if (caption.isNotEmpty) {
      presentation.applyStatus(caption);
      unawaited(settings.saveStatus(caption));
    }
    if (!presentation.settings.speakReplies) {
      presentation.applyPose(AvatarPose.idle);
      return;
    }
    final spoken = speakableReply(text);
    if (spoken.isEmpty) {
      presentation.applyPose(AvatarPose.idle);
      return;
    }
    unawaited(_speakReply(phone, presentation, spoken));
  };
  final ble = BlePeripheralManager(
    identity: identity.identity,
    pairingStore: pairingStore,
    version: _appVersion,
    onProvisioned: service.wake,
    // Mirror the setup log to the console so pairing failures are
    // diagnosable from logcat (the ring buffer feeds Diagnostics too).
    logger: (message) => debugPrint('[ble-setup] $message'),
  );

  runApp(
    MuseCompanionApp(
      service: service,
      presentation: presentation,
      settings: settings,
      ble: ble,
      chat: chat,
      sdkTokens: sdkTokens,
      phone: phone,
    ),
  );
}

/// Download a portrait Muse put in a chat reply. The invoke channel is
/// not involved; [AppCompanionDisplay.drawImageFromUrl] is the same
/// downloader `display.draw_url` uses.
Future<void> _drawChatCharacter(AppCompanionDisplay display, String url) async {
  try {
    final result = await display.drawImageFromUrl(url);
    if (!result.isOk) {
      debugPrint('[muse] chat character was not drawn: ${result.error}');
    } else {
      debugPrint('[muse] chat character drawn');
    }
  } catch (e) {
    debugPrint('[muse] chat character was not drawn: $e');
  }
}

/// Generation counter for [_speakReply]: an interrupt (or a newer reply)
/// must not let an older finally block reset the pose of speech that is
/// still running.
int _speakReplyGeneration = 0;

/// Set the speaker, then read [spoken]. The speaking pose lasts until the
/// utterance finishes. A new hold that moved the pose is left alone.
Future<void> _speakReply(
  PhoneBridge phone,
  PresentationState presentation,
  String spoken,
) async {
  final generation = ++_speakReplyGeneration;
  presentation.applyPose(AvatarPose.speaking);
  try {
    await phone.run('phone.volume', {
      'level': presentation.settings.speechVolume,
    });
    await phone.speak(spoken);
  } on PhoneActionException {
    // The caption under the character is the fallback.
  } finally {
    if (generation == _speakReplyGeneration &&
        presentation.pose == AvatarPose.speaking) {
      presentation.applyPose(AvatarPose.idle);
    }
  }
}

/// Stop any in-progress speech immediately and return the avatar to idle.
/// Safe to call when nothing is speaking (effectively a no-op). The
/// caption is untouched — it was set separately.
Future<void> stopSpeaking(
  PhoneBridge phone,
  PresentationState presentation,
) async {
  _speakReplyGeneration++;
  try {
    await phone.stopSpeak();
  } on PhoneActionException {
    // Engine not ready or the call failed; the pose reset below applies.
  }
  if (presentation.pose == AvatarPose.speaking) {
    presentation.applyPose(AvatarPose.idle);
  }
}

/// Lets the executor post a photo or voice note before the service exists.

/// Automatically captures photos on a schedule and posts them to the Muse
/// chat. Works without device.invoke - the app pushes photos itself via
/// sendChat. Controlled by CompanionSettings.autoCaptureEnabled and
/// autoCaptureIntervalMinutes.
class _AutoCaptureScheduler {
  _AutoCaptureScheduler({
    required SettingsStore settings,
    required PhoneBridge phone,
    required _ChatPoster poster,
  })  : _settings = settings,
        _phone = phone,
        _poster = poster;

  final SettingsStore _settings;
  final PhoneBridge _phone;
  final _ChatPoster _poster;
  Timer? _timer;

  /// Start or restart the scheduler based on current settings.
  void sync() {
    _timer?.cancel();
    _timer = null;
    final s = _settings.loadSettings();
    if (!s.autoCaptureEnabled) return;
    final minutes = s.autoCaptureIntervalMinutes;
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => _capture());
    debugPrint('[muse] auto-capture every $minutes minutes');
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _capture() async {
    try {
      final s = _settings.loadSettings();
      if (!s.autoCaptureEnabled) return;
      final jpeg = await _phone.captureJpeg(facing: s.cameraFacing);
      final now = DateTime.now();
      final stamp =
          '${now.year}-${_two(now.month)}-${_two(now.day)} '
          '${_two(now.hour)}:${_two(now.minute)}';
      final message = 'Auto-capture $stamp (${s.cameraFacing} camera)';
      // TODO: ADB info was sending as empty voice notes instead of text.
      // Disabled until the sendChat routing is fixed.
      await _poster.send(
        message,
        [ChatAttachment(mimeType: 'image/jpeg', filename: 'auto-capture.jpg', bytes: jpeg)],
      );
      debugPrint('[muse] auto-capture posted');
    } catch (e) {
      debugPrint('[muse] auto-capture failed: $e');
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _ChatPoster {
  GadgetService? _service;

  void bind(GadgetService service) => _service = service;

  Future<Map<String, Object?>> send(
    String message,
    List<ChatAttachment> attachments,
  ) {
    final service = _service;
    if (service == null) {
      return Future.value({'ok': false, 'error': 'not ready'});
    }
    return service.sendChat(message, null, attachments);
  }
}

/// Physical pixels of the primary view; the Muse sizes art from this.
({int width, int height}) _screenSize() {
  try {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize;
    final width = size.width.round();
    final height = size.height.round();
    if (width > 0 && height > 0) {
      return (width: width, height: height);
    }
  } catch (_) {
    // Fall through to the fallback.
  }
  return (width: 1080, height: 2400);
}

/// Bridges the platform display side to the pure PresentationState.
class _DisplayListener implements CompanionDisplayListener {
  _DisplayListener(this._presentation);

  final PresentationState _presentation;

  @override
  void onCharacter(Uint8List bytes, int width, int height) =>
      _presentation.applyCharacter(bytes, width: width, height: height);

  @override
  void onStatus(String text) {
    _presentation.applyStatus(text);
    final pose = poseForStatus(text);
    if (pose != null) _presentation.applyPose(pose);
  }

  @override
  void onPlaceholder() => _presentation.applyPlaceholder();

  @override
  void onSettings(CompanionSettings settings) =>
      _presentation.applySettings(settings);
}

class MuseCompanionApp extends StatefulWidget {
  const MuseCompanionApp({
    super.key,
    required this.service,
    required this.presentation,
    required this.settings,
    required this.ble,
    required this.chat,
    required this.sdkTokens,
    required this.phone,
  });

  final GadgetService service;
  final PresentationState presentation;
  final SettingsStore settings;
  final BlePeripheralManager ble;
  final ChatHistory chat;
  final SecureSdkTokenStore sdkTokens;
  final PhoneBridge phone;

  @override
  State<MuseCompanionApp> createState() => _MuseCompanionAppState();
}

class _MuseCompanionAppState extends State<MuseCompanionApp>
    with WidgetsBindingObserver {
  Timer? _healthTimer;
  StreamSubscription<ConnectionState>? _linkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start the connection loop (idempotent). Pairing happens through the
    // existing gadget stack; nothing here re-implements it.
    widget.service.start();
    _pollHealth();
    _healthTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _pollHealth(),
    );
    // Keep the link alive in the background (Android) and mirror its
    // state into the persistent notification.
    _linkSub = widget.service.onStateChanged.listen((_) {
      updateLinkNotification(_notificationText());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      startLinkService(_notificationText());
    });
  }

  String _notificationText() {
    return linkNotificationText(
      widget.service.connectionState.name,
      widget.service.statusDetail,
      widget.service.agentName,
    );
  }

  Future<void> _pollHealth() async {
    try {
      final info = await AppCompanionHealth(appVersion: _appVersion).health();
      final battery = info['battery_level'] as int?;
      widget.presentation.applyBattery(battery);
    } on Exception {
      // Battery is best-effort; the header still renders without it.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_enterImmersive());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healthTimer?.cancel();
    _linkSub?.cancel();
    widget.service.stop();
    widget.ble.dispose();
    widget.chat.close();
    widget.presentation.close();
    super.dispose();
  }

  ThemeData _themeFor(Brightness brightness) => museTheme(brightness);

  ThemeMode _modeFor(String theme) {
    switch (theme) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild the theme whenever settings change (user or Muse).
    return StreamBuilder<void>(
      stream: widget.presentation.stream,
      builder: (context, _) => AppScope(
        service: widget.service,
        presentation: widget.presentation,
        settings: widget.settings,
        ble: widget.ble,
        chat: widget.chat,
        sdkTokens: widget.sdkTokens,
        phone: widget.phone,
        child: MaterialApp(
          title: 'Muse Companion',
          debugShowCheckedModeBanner: false,
          navigatorObservers: [routeObserver],
          theme: _themeFor(Brightness.light),
          darkTheme: _themeFor(Brightness.dark),
          themeMode: _modeFor(widget.presentation.settings.theme),
          builder: (context, child) {
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: const SystemUiOverlayStyle(
                statusBarColor: Color(0x00000000),
                systemNavigationBarColor: Color(0x00000000),
                systemNavigationBarContrastEnforced: false,
                statusBarIconBrightness: Brightness.light,
                systemNavigationBarIconBrightness: Brightness.light,
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const CompanionScreen(),
        ),
      ),
    );
  }
}
