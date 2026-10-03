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

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:muse_companion/app/ble_peripheral.dart';
import 'package:muse_companion/app/chat.dart';
import 'package:muse_companion/app/companion_platform.dart';
import 'package:muse_companion/app/foreground.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/app/storage.dart';
import 'package:muse_companion/src/gadget/commands.dart';
import 'package:muse_companion/src/gadget/service.dart';

import 'ui/companion_screen.dart';
import 'ui/scope.dart';

const String _appVersion = '0.1.0';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initForegroundSupport();
  initLinkService();

  final settings = await SettingsStore.init();
  final identity =
      await PersistentIdentity.loadOrCreate(const FlutterSecureStorage());
  final presentation = PresentationState(settings: settings.loadSettings());
  final savedStatus = settings.loadStatus();
  if (savedStatus.isNotEmpty) {
    presentation.applyStatus(savedStatus);
  }

  final health = AppCompanionHealth(appVersion: _appVersion);
  final display = AppCompanionDisplay(
    listener: _DisplayListener(presentation),
    settings: settings,
  );
  final executor = CompanionExecutor(display: display, health: health);

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
  );
  final ble = BlePeripheralManager(
    identity: identity.identity,
    pairingStore: pairingStore,
    version: _appVersion,
    onProvisioned: service.wake,
    // Mirror the setup log to the console so pairing failures are
    // diagnosable from logcat (the ring buffer feeds Diagnostics too).
    logger: (message) => debugPrint('[ble-setup] $message'),
  );

  runApp(MuseCompanionApp(
    service: service,
    presentation: presentation,
    settings: settings,
    ble: ble,
    chat: ChatHistory(),
    sdkTokens: sdkTokens,
  ));
}

/// Physical pixels of the primary view; the Muse sizes art from this.
({int width, int height}) _screenSize() {
  try {
    final view =
        WidgetsBinding.instance.platformDispatcher.views.first;
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
  void onStatus(String text) => _presentation.applyStatus(text);

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
  });

  final GadgetService service;
  final PresentationState presentation;
  final SettingsStore settings;
  final BlePeripheralManager ble;
  final ChatHistory chat;
  final SecureSdkTokenStore sdkTokens;

  @override
  State<MuseCompanionApp> createState() => _MuseCompanionAppState();
}

class _MuseCompanionAppState extends State<MuseCompanionApp> {
  Timer? _healthTimer;
  StreamSubscription<ConnectionState>? _linkSub;

  @override
  void initState() {
    super.initState();
    // Start the connection loop (idempotent). Pairing happens through the
    // existing gadget stack; nothing here re-implements it.
    widget.service.start();
    _pollHealth();
    _healthTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _pollHealth());
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
      final info =
          await AppCompanionHealth(appVersion: _appVersion).health();
      final battery = info['battery_level'] as int?;
      widget.presentation.applyBattery(battery);
    } on Exception {
      // Battery is best-effort; the header still renders without it.
    }
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _linkSub?.cancel();
    widget.service.stop();
    widget.ble.dispose();
    widget.chat.close();
    widget.presentation.close();
    super.dispose();
  }

  ThemeData _themeFor(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6C4CF0),
        brightness: brightness,
      ),
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF121217)
          : const Color(0xFFF4F2FA),
    );
  }

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
        child: MaterialApp(
          title: 'Muse Companion',
          debugShowCheckedModeBanner: false,
          navigatorObservers: [routeObserver],
          theme: _themeFor(Brightness.light),
          darkTheme: _themeFor(Brightness.dark),
          themeMode: _modeFor(widget.presentation.settings.theme),
          home: const CompanionScreen(),
        ),
      ),
    );
  }
}
