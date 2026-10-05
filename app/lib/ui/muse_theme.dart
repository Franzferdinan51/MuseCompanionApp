// Muse Companion visual system.
//
// Facebook blue (#1877F2) is the primary. Surfaces are round, with a light
// gloss band and a soft shadow, so controls read as bubbles rather than
// flat Material tiles. The full-screen backdrop and the in-app mark are
// the glossy assets in assets/brand. Launcher mipmaps are separate.

import 'package:flutter/material.dart';

const Color museBlue = Color(0xFF1877F2);
const Color museBlueDeep = Color(0xFF0A3F86);
const Color museInk = Color(0xFF07101C);
const Color museNight = Color(0xFF0C1828);
/// Bottom clearance (logical px) that tab content must reserve so its
/// lowest interactive elements sit above the floating tab-bar row.
/// The tab bar is roughly 16px top pad + 48px icon row + 12px bottom pad,
/// plus a small margin. Device bottom insets are handled by each
/// tab's own SafeArea, so this covers just the floating row itself.
const double kFloatingTabBarClearance = 88.0;

const Color museMist = Color(0xFFF4F8FF);

const String museLogoAsset = 'assets/brand/juno-logo-glossy.png';
const String museBackdropAsset = 'assets/brand/juno-bg-glossy.png';

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
    scaffoldBackgroundColor: museInk,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      foregroundColor: Colors.white,
      titleTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
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
        decoration: museBackdrop(),
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

/// Glossy duck mark. The source has a white margin, so the circle is
/// zoomed until that margin falls outside the clip.
class MuseLogo extends StatelessWidget {
  const MuseLogo({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: museBlue.withValues(alpha: 0.45),
              blurRadius: size * 0.28,
              offset: Offset(0, size * 0.08),
            ),
          ],
        ),
        child: ClipOval(
          child: Transform.scale(
            scale: 1.26,
            child: Image.asset(
              museLogoAsset,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              semanticLabel: 'Muse Companion',
            ),
          ),
        ),
      ),
    );
  }
}

BoxDecoration museBackdrop() {
  return const BoxDecoration(
    color: museInk,
    image: DecorationImage(
      image: AssetImage(museBackdropAsset),
      fit: BoxFit.cover,
      alignment: Alignment.center,
    ),
  );
}
