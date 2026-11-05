import 'package:flutter/material.dart';
import '../domain/appearance.dart';
import 'app_theme.dart';

Color playerAccent(BuildContext context) => Color(
  (Theme.of(context).extension<AppAppearance>()?.palette ?? AppPalette.blue)
      .darkAccent,
);
const playerPanelColor = Color(0xff18191c);

/// Media controls stay readable over video regardless of the surrounding app theme.
ThemeData playerTheme(ThemeData inherited) {
  final appearance = inherited.extension<AppAppearance>();
  final palette = appearance?.palette ?? AppPalette.blue;
  final accent = Color(palette.darkAccent);
  return inherited.copyWith(
    extensions: [
      ...inherited.extensions.values.where((e) => e is! AppAppearance),
      AppAppearance.resolve(
        palette,
        appearance?.glassStyle ?? GlassStyle.clear,
        Brightness.dark,
        glassControls: appearance?.glassControls ?? false,
        glassLowPower: appearance?.glassLowPower ?? false,
      ),
    ],
    brightness: Brightness.dark,
    disabledColor: Colors.white38,
    canvasColor: playerPanelColor,
    colorScheme: ColorScheme.dark(
      primary: accent,
      onPrimary: const Color(0xff101418),
      secondary: accent,
      surface: playerPanelColor,
      onSurface: Colors.white,
      onSurfaceVariant: Colors.white60,
      outline: Colors.white24,
      outlineVariant: Colors.white12,
    ),
    textTheme: inherited.textTheme.apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    iconTheme: const IconThemeData(color: Colors.white70),
    dividerColor: Colors.white12,
    dividerTheme: const DividerThemeData(color: Colors.white12, thickness: .6),
    listTileTheme: ListTileThemeData(
      textColor: Colors.white,
      iconColor: Colors.white70,
      selectedColor: accent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: accent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: const Color(0xff101418),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white24),
      ),
    ),
    sliderTheme: inherited.sliderTheme.copyWith(
      activeTrackColor: accent,
      inactiveTrackColor: Colors.white24,
      thumbColor: accent,
      overlayColor: accent.withValues(alpha: .15),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? accent : Colors.white24,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
  );
}
