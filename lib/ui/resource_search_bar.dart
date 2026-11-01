import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'liquid_glass.dart';

/// Shared search styling for the catalog and results, with room for large text.
class ResourceSearchBar extends StatelessWidget {
  const ResourceSearchBar({
    super.key,
    required this.field,
    required this.onPressed,
    required this.buttonKey,
    this.label = '搜索',
  });

  final Widget field;
  final VoidCallback? onPressed;
  final Key buttonKey;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appearance = AppAppearance.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final large = MediaQuery.textScalerOf(context).scale(14) > 21;
    final radius = BorderRadius.circular(large ? 22 : 30);
    final button = LiquidGlassButton(
      key: buttonKey,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(72, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(large ? 16 : 24),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: LiquidGlassSurface(
        borderRadius: radius,
        tint: colors.surface,
        opacity: math.max(appearance.glassOpacity, dark ? .68 : .86),
        refractionHeight: 8,
        refractionAmount: 8,
        saturation: 1.03,
        highlight: .20,
        shadow: 0,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: large
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [field, const SizedBox(height: 6), button],
                )
              : Row(
                  children: [
                    Expanded(child: field),
                    const SizedBox(width: 4),
                    button,
                  ],
                ),
        ),
      ),
    );
  }
}
