import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_screen_display.dart';
import 'package:asterlink/playback/playback_screen_speed.dart';

void main() {
  test('old and malformed screen settings preserve useful defaults', () {
    final old = PlaybackPreferences.fromJson({});
    expect(old.screenDisplay.enabled, isFalse);
    expect(old.screenDisplay.style, PlaybackScreenStyle.outline);
    expect(old.screenDisplay.items, contains(PlaybackScreenItem.progress));
    expect(old.screenDisplay.items, isNot(contains(PlaybackScreenItem.media)));
    final future = PlaybackScreenDisplay.fromJson({
      'enabled': true,
      'items': ['time', 'future-field', 123, 'time'],
    });
    expect(future.items, {PlaybackScreenItem.time});
    expect(future.style, PlaybackScreenStyle.outline);
    expect(
      PlaybackScreenDisplay.fromJson({'style': 'future-style'}).style,
      PlaybackScreenStyle.outline,
    );
    expect(
      PlaybackScreenDisplay.fromJson({'enabled': true, 'items': []}).visible,
      isFalse,
    );
    expect(
      PlaybackScreenDisplay.fromJson({'items': 'bad'}).items,
      old.screenDisplay.items,
    );
  });

  test(
    'screen choices are global and survive reopening and layout reset',
    () async {
      final state = StateStore.memory();
      addTearDown(state.dispose);
      final store = PlaybackStore(state);
      final before = store.preferencesFor('series-a');
      final selected = before.copyWith(
        screenDisplay:
            const PlaybackScreenDisplay(
                  enabled: true,
                  style: PlaybackScreenStyle.background,
                )
                .withItem(PlaybackScreenItem.media, true)
                .withItem(PlaybackScreenItem.time, false),
        rate: 1.5,
      );
      await store.saveEffectivePreferences('series-a', selected, before);
      final reopenedState = StateStore.memory(state.data);
      addTearDown(reopenedState.dispose);
      final reopened = PlaybackStore(reopenedState);
      for (final folder in ['series-a', 'series-b', null]) {
        final prefs = reopened.preferencesFor(folder);
        expect(prefs.screenDisplay.enabled, isTrue);
        expect(prefs.screenDisplay.items, selected.screenDisplay.items);
        expect(prefs.screenDisplay.style, PlaybackScreenStyle.background);
        expect(
          prefs.withLayout(const PlaybackPreferences()).screenDisplay.style,
          PlaybackScreenStyle.background,
        );
        expect(
          prefs.withLayout(const PlaybackPreferences()).screenDisplay.items,
          selected.screenDisplay.items,
        );
      }
      expect(reopened.preferencesFor('series-a').rate, 1.5);
      expect(reopened.preferencesFor('series-b').rate, 1);
      final roundTrip = PlaybackPreferences.fromJson(selected.toJson());
      expect(roundTrip.screenDisplay.items, selected.screenDisplay.items);
      expect(roundTrip.screenDisplay.style, PlaybackScreenStyle.background);
    },
  );

  test('network speed sums received bytes and uses actual elapsed time', () {
    final speed = PlaybackScreenSpeed();
    final source = Object();
    expect(speed.sample(source, 1000, Duration.zero), isNull);
    expect(
      speed.sample(source, 1100, const Duration(milliseconds: 500)),
      isNull,
    );
    expect(speed.sample(source, 3048, const Duration(seconds: 1)), 2048);
    expect(speed.sample(source, 3048, const Duration(seconds: 2)), 0);
    expect(speed.sample(source, 7144, const Duration(seconds: 4)), 2048);
  });

  test('network speed discards old counters when switching and resetting', () {
    final speed = PlaybackScreenSpeed();
    final source = Object();
    speed.sample(source, 10, Duration.zero);
    expect(speed.sample(source, 1010, const Duration(seconds: 1)), 1000);
    expect(speed.sample(Object(), 500000, const Duration(seconds: 2)), isNull);
    expect(speed.sample(source, 10, const Duration(seconds: 3)), isNull);
    expect(speed.sample(source, 5, const Duration(seconds: 4)), isNull);
    expect(speed.sample(source, null, const Duration(seconds: 5)), isNull);
    expect(speed.sample(source, 100, const Duration(seconds: 6)), isNull);
  });
}
