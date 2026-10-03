// Muse Companion visual system.
//
// Facebook blue (#1877F2) is the primary. Surfaces are round, with a light
// gloss band and a soft shadow, so controls read as bubbles rather than
// flat Material tiles. Launcher art is separate and arrives later.

import 'package:flutter/material.dart';

const Color museBlue = Color(0xFF1877F2);
const Color museBlueDeep = Color(0xFF0A3F86);
const Color museInk = Color(0xFF07101C);
const Color museNight = Color(0xFF0C1828);
const Color museMist = Color(0xFFF4F8FF);

ThemeData museTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: museBlue,
    brightness: brightness,
    primary: museBlue,
    onPrimary: Colors.white,
    surface: dark ? museNight : museMist,
  );
  final radius = BorderRadius.circular(22);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? museInk : museMist,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      foregroundColor: scheme.onSurface,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: museBlue,
        backgroundColor: museBlue.withValues(alpha: dark ? 0.18 : 0.10),
        shape: const CircleBorder(),
        side: BorderSide(
          color: Colors.white.withValues(alpha: dark ? 0.22 : 0.7),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: museBlue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: radius),
        elevation: 0,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF13233C) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF16325C) : museBlueDeep,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? museNight : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outline.withValues(alpha: 0.18),
    ),
    cardTheme: CardThemeData(
      color: dark ? const Color(0xFF14305A) : Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: Colors.white.withValues(alpha: dark ? 0.22 : 0.85),
        ),
      ),
    ),
  );
}

/// A full-screen Muse page: gradient behind a transparent app bar.
class MusePage extends StatelessWidget {
  const MusePage({super.key, this.appBar, required this.body});

  final PreferredSizeWidget? appBar;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: appBar != null,
      appBar: appBar,
      body: DecoratedBox(
        decoration: museBackdrop(Theme.of(context).brightness),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(top: appBar == null ? 0 : kToolbarHeight),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// A rounded control with a top gloss and a soft blue shadow.
class MuseBubble extends StatelessWidget {
  const MuseBubble({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.radius = 22,
    this.color,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = color ?? (dark ? const Color(0xFF14305A) : Colors.white);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(base, Colors.white, dark ? 0.16 : 0.0)!,
            base,
            Color.lerp(base, museBlueDeep, dark ? 0.25 : 0.06)!,
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: dark ? 0.22 : 0.85),
        ),
        boxShadow: [
          BoxShadow(
            color: museBlue.withValues(alpha: dark ? 0.28 : 0.16),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            left: 12,
            right: 12,
            top: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: dark ? 0.22 : 0.55),
                    Colors.white.withValues(alpha: 0),
                  ],
                ),
              ),
              child: const SizedBox(height: 10),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

BoxDecoration museBackdrop(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: dark
          ? const [Color(0xFF1A4E96), museInk, Color(0xFF05070C)]
          : const [Color(0xFFD7E8FF), museMist, Color(0xFFE7F0FF)],
      stops: const [0, 0.42, 1],
    ),
  );
}
