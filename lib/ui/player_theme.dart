import 'package:flutter/material.dart';
import '../domain/appearance.dart';
import 'app_theme.dart';

Color playerAccent(BuildContext context) => Color(
  (Theme.of(context).extension<AppAppearance>()?.palette ?? AppPalette.blue)
      .darkAccent,
);
const playerPanelColor = Color(0xff18191c);
const playerInputColor = Color(0xff242529);

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
    inputDecorationTheme: inherited.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: playerInputColor,
      focusColor: Colors.transparent,
      hoverColor: Colors.white.withValues(alpha: .04),
      labelStyle: const TextStyle(color: Colors.white70),
      floatingLabelStyle: TextStyle(color: accent),
      helperStyle: const TextStyle(color: Colors.white60),
      hintStyle: const TextStyle(color: Colors.white54),
      prefixIconColor: Colors.white60,
      suffixIconColor: Colors.white60,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white12),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white12),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white10),
      ),
    ),
    textSelectionTheme: inherited.textSelectionTheme.copyWith(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: .28),
      selectionHandleColor: accent,
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
