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
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:muse_companion/app/companion_platform.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/app/storage.dart';
import 'package:muse_companion/src/gadget/commands.dart';
import 'package:muse_companion/src/gadget/service.dart';

import 'ui/companion_screen.dart';
import 'ui/scope.dart';

const String _appVersion = '0.1.0';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  final service = GadgetService(
    identity: identity.identity,
    commands: companionCommandSpecs(
      screenWidth: screen.width,
      screenHeight: screen.height,
    ),
    runCommand: executor.run,
    pairingStore: SecurePairingStore(),
    version: _appVersion,
    displayName: 'Muse Companion',
  );

  runApp(MuseCompanionApp(
    service: service,
    presentation: presentation,
    settings: settings,
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
  });

  final GadgetService service;
  final PresentationState presentation;
  final SettingsStore settings;

  @override
  State<MuseCompanionApp> createState() => _MuseCompanionAppState();
}

class _MuseCompanionAppState extends State<MuseCompanionApp> {
  Timer? _healthTimer;

  @override
  void initState() {
    super.initState();
    // Start the connection loop (idempotent). Pairing happens through the
    // existing gadget stack; nothing here re-implements it.
    widget.service.start();
    _pollHealth();
    _healthTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _pollHealth());
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
    widget.service.stop();
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
      builder: (context, _) => MaterialApp(
        title: 'Muse Companion',
        debugShowCheckedModeBanner: false,
        theme: _themeFor(Brightness.light),
        darkTheme: _themeFor(Brightness.dark),
        themeMode: _modeFor(widget.presentation.settings.theme),
        home: AppScope(
          service: widget.service,
          presentation: widget.presentation,
          settings: widget.settings,
          child: const CompanionScreen(),
        ),
      ),
    );
  }
}
