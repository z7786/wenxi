import 'dart:ui' show lerpDouble;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../domain/appearance.dart';

Color themeAccent(BuildContext context) =>
    Theme.of(context).colorScheme.primary;
Color themeCompanion(BuildContext context) =>
    Theme.of(context).colorScheme.secondary;
Color themeOnAccent(BuildContext context) =>
    Theme.of(context).colorScheme.onPrimary;

@immutable
class AppAppearance extends ThemeExtension<AppAppearance> {
  const AppAppearance({
    required this.palette,
    required this.glassStyle,
    required this.glassColor,
    required this.glassOpacity,
    required this.blurSigma,
    required this.lensColor,
  });

  factory AppAppearance.resolve(
    AppPalette palette,
    GlassStyle style,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    final colors = palette.colors(dark);
    return AppAppearance(
      palette: palette,
      glassStyle: style,
      glassColor: Color(colors.glass),
      glassOpacity: switch (style) {
        GlassStyle.clear => .40,
        GlassStyle.frosted => dark ? .94 : .92,
        GlassStyle.solid => 1,
      },
      blurSigma: switch (style) {
        GlassStyle.clear => 8,
        GlassStyle.frosted => 18,
        GlassStyle.solid => 0,
      },
      lensColor: style == GlassStyle.solid
          ? Color.alphaBlend(
              Color(colors.accent).withValues(alpha: dark ? .18 : .08),
              Color(colors.surface),
            )
          : (dark ? Colors.white : Colors.black).withValues(alpha: .10),
    );
  }

  final AppPalette palette;
  final GlassStyle glassStyle;
  final Color glassColor, lensColor;
  final double glassOpacity, blurSigma;

  @override
  bool operator ==(Object other) =>
      other is AppAppearance &&
      palette == other.palette &&
      glassStyle == other.glassStyle &&
      glassColor == other.glassColor &&
      lensColor == other.lensColor &&
      glassOpacity == other.glassOpacity &&
      blurSigma == other.blurSigma;

  @override
  int get hashCode => Object.hash(
    palette,
    glassStyle,
    glassColor,
    lensColor,
    glassOpacity,
    blurSigma,
  );

  static AppAppearance of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppAppearance>() ??
        AppAppearance.resolve(
          AppPalette.blue,
          GlassStyle.clear,
          theme.brightness,
        );
  }

  @override
  AppAppearance copyWith({
    AppPalette? palette,
    GlassStyle? glassStyle,
    Color? glassColor,
    double? glassOpacity,
    double? blurSigma,
    Color? lensColor,
  }) => AppAppearance(
    palette: palette ?? this.palette,
    glassStyle: glassStyle ?? this.glassStyle,
    glassColor: glassColor ?? this.glassColor,
    glassOpacity: glassOpacity ?? this.glassOpacity,
    blurSigma: blurSigma ?? this.blurSigma,
    lensColor: lensColor ?? this.lensColor,
  );

  @override
  AppAppearance lerp(covariant AppAppearance? other, double t) {
    if (other == null) return this;
    return AppAppearance(
      palette: t < .5 ? palette : other.palette,
      glassStyle: t < .5 ? glassStyle : other.glassStyle,
      glassColor: Color.lerp(glassColor, other.glassColor, t)!,
      glassOpacity: lerpDouble(glassOpacity, other.glassOpacity, t)!,
      blurSigma: lerpDouble(blurSigma, other.blurSigma, t)!,
      lensColor: Color.lerp(lensColor, other.lensColor, t)!,
    );
  }
}

ThemeData appTheme(
  Brightness brightness, {
  String? fontFamily,
  AppPalette palette = AppPalette.blue,
  GlassStyle glassStyle = GlassStyle.clear,
}) {
  final dark = brightness == Brightness.dark;
  final windows = defaultTargetPlatform == TargetPlatform.windows;
  final resolvedFont = fontFamily ?? (windows ? 'Microsoft YaHei UI' : null);
  final fallbackFonts = windows ? const ['Microsoft YaHei', 'Segoe UI'] : null;
  final tones = palette.colors(dark);
  final surface = Color(tones.surface);
  final colors =
      ColorScheme.fromSeed(
        seedColor: Color(tones.accent),
        brightness: brightness,
      ).copyWith(
        primary: Color(tones.accent),
        onPrimary: Color(tones.onAccent),
        secondary: Color(tones.companion),
        onSecondary: Color(tones.onAccent),
        surface: surface,
        onSurface: Color(tones.foreground),
        onSurfaceVariant: Color(tones.muted),
        surfaceContainerLow: Color(tones.fill),
        surfaceContainer: Color(tones.fill),
        outlineVariant: Color(tones.border),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    extensions: [AppAppearance.resolve(palette, glassStyle, brightness)],
    fontFamily: resolvedFont,
    fontFamilyFallback: fallbackFonts,
    scaffoldBackgroundColor: surface,
    dividerColor: colors.outlineVariant,
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 56,
      titleTextStyle: TextStyle(
        fontFamily: resolvedFont,
        fontFamilyFallback: fallbackFonts,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: colors.onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLow,
      contentPadding: const EdgeInsets.all(14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.primary),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? colors.surfaceContainerLow : surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}
