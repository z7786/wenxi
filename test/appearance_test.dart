import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/appearance.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/player_theme.dart';
import 'support.dart';

double contrast(Color a, Color b) {
  final first = a.computeLuminance(), second = b.computeLuminance();
  return (math.max(first, second) + .05) / (math.min(first, second) + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unchanged appearance does not restart theme transitions on store updates',
    () {
      final first = appTheme(
        Brightness.light,
        palette: AppPalette.mint,
        glassStyle: GlassStyle.frosted,
      );
      final next = appTheme(
        Brightness.light,
        palette: AppPalette.mint,
        glassStyle: GlassStyle.frosted,
      );
      expect(next, first);
      expect(
        next.extension<AppAppearance>().hashCode,
        first.extension<AppAppearance>().hashCode,
      );
    },
  );

  test(
    'old settings retain appearance mode and use the classic glass theme',
    () {
      for (final mode in ['Light', 'Dark', 'System']) {
        final settings = AppSettings.fromJson({'theme': mode, 'threads': 16});
        expect(settings.theme, mode);
        expect(settings.themePalette, AppPalette.blue);
        expect(settings.glassStyle, GlassStyle.clear);
        expect(settings.glassControls, isFalse);
        expect(settings.glassLowPower, isFalse);
        expect(settings.hideResourceNavigation, isFalse);
        expect(settings.threads, 16);
      }
      final unknown = AppSettings.fromJson({
        'themePalette': 'future-palette',
        'glassStyle': {'unexpected': true},
      });
      expect(unknown.themePalette, AppPalette.blue);
      expect(unknown.glassStyle, GlassStyle.clear);
    },
  );

  for (final palette in AppPalette.values) {
    for (final brightness in Brightness.values) {
      test(
        '${palette.name} ${brightness.name} has readable colors and a dark player',
        () {
          final theme = appTheme(brightness, palette: palette);
          final c = theme.colorScheme;
          expect(contrast(c.primary, c.onPrimary), greaterThanOrEqualTo(4.5));
          expect(
            contrast(c.secondary, c.onSecondary),
            greaterThanOrEqualTo(4.5),
          );
          expect(contrast(c.onSurface, c.surface), greaterThanOrEqualTo(7));
          expect(
            contrast(c.onSurfaceVariant, c.surfaceContainerLow),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(c.primary, c.surfaceContainerLow),
            greaterThanOrEqualTo(4.5),
          );
          final player = playerTheme(theme);
          expect(player.brightness, Brightness.dark);
          expect(player.colorScheme.surface, playerPanelColor);
          expect(player.colorScheme.primary, Color(palette.darkAccent));
          expect(
            contrast(player.colorScheme.primary, player.colorScheme.onPrimary),
            greaterThanOrEqualTo(4.5),
          );
        },
      );
    }
  }

  test(
    'appearance survives encrypted storage reopening and a backup round trip',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wenxi-appearance-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = CryptoBox.random(32);
      final store = await StateStore.open(directory, testKey: key);
      final native = FakeNative();
      final services = AppServices(
        store: store,
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: native,
        files: FakeFiles(directory),
        http: FakeHttp(),
        controlEnabled: false,
        platformFeatures: false,
      );
      await services.updateSettings({
        'threads': 16,
        'destination': 'D:/Downloads',
      });
      final before = List<String>.of(native.calls);
      await services.updateAppearance(
        mode: 'Dark',
        palette: AppPalette.mint,
        glassStyle: GlassStyle.frosted,
        hideResourceNavigation: true,
        glassControls: true,
        glassLowPower: true,
      );
      expect(
        native.calls,
        before,
        reason: 'Appearance must not restart or reconfigure transfers',
      );
      expect(services.settings.threads, 16);
      expect(services.settings.destination, 'D:/Downloads');
      final backup = await services.backup.create('theme-test-password');
      await store.flush();
      final reopened = await StateStore.open(directory, testKey: key);
      final persisted = AppSettings.fromJson(reopened.data.obj('settings'));
      expect(persisted.theme, 'Dark');
      expect(persisted.themePalette, AppPalette.mint);
      expect(persisted.glassStyle, GlassStyle.frosted);
      expect(persisted.glassControls, isTrue);
      expect(persisted.glassLowPower, isTrue);
      expect(persisted.hideResourceNavigation, isTrue);
      final target = StateStore.memory();
      await BackupRepository(target).restore(backup, 'theme-test-password');
      final restored = AppSettings.fromJson(target.data.obj('settings'));
      expect(restored.themePalette, AppPalette.mint);
      expect(restored.glassStyle, GlassStyle.frosted);
      expect(restored.glassControls, isTrue);
      expect(restored.glassLowPower, isTrue);
      expect(restored.hideResourceNavigation, isTrue);
      expect(restored.threads, 16);
      expect(restored.destination, isNull);
      await services.close();
      reopened.dispose();
      target.dispose();
    },
  );

  test(
    'glass theme interpolation is continuous and solid mode disables blur',
    () {
      final clear = appTheme(
        Brightness.light,
        palette: AppPalette.blue,
      ).extension<AppAppearance>()!;
      final solid = appTheme(
        Brightness.dark,
        palette: AppPalette.rose,
        glassStyle: GlassStyle.solid,
      ).extension<AppAppearance>()!;
      final mid = clear.lerp(solid, .5);
      expect(
        mid.glassOpacity,
        closeTo((clear.glassOpacity + solid.glassOpacity) / 2, .001),
      );
      expect(mid.blurSigma, closeTo(clear.blurSigma / 2, .001));
      expect(solid.glassOpacity, 1);
      expect(solid.blurSigma, 0);
      final tones = AppPalette.rose.colors(true);
      expect(
        tones.overlay(GlassStyle.solid)['accent'],
        solid.palette.darkAccent,
      );
    },
  );
}
