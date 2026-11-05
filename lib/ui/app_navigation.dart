import 'dart:ui' as ui;
import 'liquid_bottom_navigation.dart';
import 'navigation_transfer_icon.dart';
import '../download/navigation_transfers.dart';
import '../domain/appearance.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'app_theme.dart' show AppAppearance;
import 'common.dart';

class AppNavigation extends StatelessWidget {
  const AppNavigation({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.rail = false,
    this.hideResources = false,
    this.transfers,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool rail;
  final bool hideResources;
  final ValueListenable<NavigationTransferStatus>? transfers;

  static const destinations = [
    ('解析', 'assets/navigation/parse.svg'),
    ('资源', 'assets/navigation/search.svg'),
    ('网盘', 'assets/navigation/cloud.svg'),
    ('传输', 'assets/navigation/downloads.svg'),
    ('我的', 'assets/navigation/settings.svg'),
  ];

  // Keep page IDs stable when a destination is hidden.
  static List<int> visibleIndices({bool hideResources = false}) => [
    0,
    if (!hideResources) 1,
    2,
    3,
    4,
  ];

  @override
  Widget build(BuildContext context) {
    final indices = visibleIndices(hideResources: hideResources);
    final visibleSelection = indices.indexOf(selectedIndex);
    final navigationSelection = visibleSelection < 0 ? 0 : visibleSelection;
    final compact = rail && MediaQuery.sizeOf(context).height < 560;
    final appearance = AppAppearance.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final colors = Theme.of(context).colorScheme;
    final active = themeAccent(context);
    final inactive = highContrast || appearance.glassStyle == GlassStyle.clear
        ? colors.onSurface
        : colors.onSurfaceVariant;

    Widget item(int index) {
      final (label, asset) = destinations[index];
      final selected = index == indices[navigationSelection];
      final color = selected ? active : inactive;
      void activate() => onSelected(index);
      return Semantics(
        key: ValueKey('navigation-$index'),
        label: label,
        selected: selected,
        button: true,
        onTap: activate,
        child: InkWell(
          excludeFromSemantics: true,
          onTap: activate,
          customBorder: const StadiumBorder(),
          splashColor: active.withValues(alpha: .12),
          highlightColor: active.withValues(alpha: .05),
          focusColor: active.withValues(alpha: .10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60, minWidth: 48),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: rail ? 18 : 6,
                vertical: rail ? (compact ? 8 : 18) : 9,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (label == '传输')
                    NavigationTransferIcon(
                      asset: asset,
                      color: color,
                      size: 26,
                      transfers: transfers,
                    )
                  else
                    SvgPicture.asset(
                      asset,
                      width: 26,
                      height: 26,
                      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                      excludeFromSemantics: true,
                    ),
                  const SizedBox(height: 4),
                  ExcludeSemantics(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (rail) {
      final solid = highContrast || appearance.glassStyle == GlassStyle.solid;
      return ClipRect(
        child: BackdropFilter(
          enabled:
              !solid &&
              !appearance.glassLowPower &&
              TickerMode.valuesOf(context).enabled,
          filter: ui.ImageFilter.blur(
            sigmaX: appearance.blurSigma,
            sigmaY: appearance.blurSigma,
          ),
          child: Material(
            key: const Key('navigation-rail-surface'),
            color: appearance.glassColor.withValues(
              alpha: solid
                  ? 1
                  : appearance.glassLowPower
                  ? .86
                  : appearance.glassOpacity,
            ),
            child: Container(
              width: 88,
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: border(context), width: .5),
                ),
              ),
              child: SafeArea(
                right: false,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: compact ? 12 : 24,
                      ),
                      child: Image.asset(
                        'assets/icons/app.png',
                        width: 34,
                        height: 34,
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [for (final index in indices) item(index)],
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(bottom: compact ? 10 : 18),
                      child: Text(
                        '文析助手',
                        style: TextStyle(fontSize: 10, color: inactive),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return LiquidBottomNavigation(
      key: ValueKey(hideResources),
      selectedIndex: navigationSelection,
      allowReselect: visibleSelection < 0,
      onSelected: (index) => onSelected(indices[index]),
      destinations: [for (final index in indices) destinations[index]],
      destinationIds: indices,
      transfers: transfers,
    );
  }
}
