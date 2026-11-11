import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('brightness survives reopening and stays isolated by folder', () async {
    final state = StateStore.memory();
    final history = PlaybackStore(state);
    expect(history.brightnessFor('show-a'), isNull);
    await history.saveBrightness('show-a', .85);
    await history.saveBrightness('show-b', .35);
    final reopened = PlaybackStore(StateStore.memory(state.data));
    expect(reopened.brightnessFor('show-a'), .85);
    expect(reopened.brightnessFor('show-b'), .35);
    expect(reopened.brightnessFor('show-c'), isNull);
    expect(reopened.preferences.toJson(), isNot(contains('brightness')));
    await reopened.clearHistory();
    expect(reopened.brightnessFor('show-a'), .85);
    final preferences = reopened.preferencesFor('show-a');
    await reopened.saveEffectivePreferences(
      'show-a',
      preferences.copyWith(rate: 1.5),
      preferences,
    );
    expect(reopened.brightnessFor('show-a'), .85);
  });

  test(
    'pending brightness is immediately visible to the next player',
    () async {
      final state = StateStore.memory();
      final history = PlaybackStore(state);
      final first = history.saveBrightness('show', .6);
      final second = history.saveBrightness('show', .9);
      final next = PlaybackStore(state);
      expect(next.brightnessFor('show'), .9);
      await first;
      expect(next.brightnessFor('show'), .9);
      await second;
      expect(
        PlaybackStore(StateStore.memory(state.data)).brightnessFor('show'),
        .9,
      );
    },
  );

  test(
    'folder memory toggle disables saving without losing prior brightness',
    () async {
      final history = PlaybackStore(StateStore.memory());
      await history.saveBrightness('show', .8);
      await history.rememberFolder('show', false);
      expect(history.brightnessFor('show'), isNull);
      await history.saveBrightness('show', .2);
      await history.saveBrightness(null, .9);
      expect(history.brightnessFor(null), isNull);
      await history.rememberFolder('show', true);
      expect(history.brightnessFor('show'), .8);
      // A toggle queued before a save wins even when the old snapshot says enabled.
      final disable = history.rememberFolder('show', false);
      final save = history.saveBrightness('show', .4);
      await disable;
      await save;
      await history.rememberFolder('show', true);
      expect(history.brightnessFor('show'), .8);
    },
  );

  test(
    'brightness accepts zero, clamps finite values and ignores corrupt data',
    () async {
      final history = PlaybackStore(
        StateStore.memory({
          'playbackFolders': {
            'old': {'preferences': const PlaybackPreferences().toJson()},
            'zero': {'brightness': 0},
            'high': {'brightness': 2},
            'low': {'brightness': -1},
            'bad': {'brightness': 'invalid'},
            'nan': {'brightness': 'NaN'},
          },
        }),
      );
      expect(history.brightnessFor('old'), isNull);
      expect(history.brightnessFor('zero'), 0);
      expect(history.brightnessFor('high'), 1);
      expect(history.brightnessFor('low'), 0);
      expect(history.brightnessFor('bad'), isNull);
      expect(history.brightnessFor('nan'), isNull);
      await history.saveBrightness('show', 2);
      expect(history.brightnessFor('show'), 1);
      await history.saveBrightness('show', double.nan);
      await history.saveBrightness('show', double.infinity);
      expect(history.brightnessFor('show'), 1);
      await history.saveBrightness('show', 0);
      expect(history.brightnessFor('show'), 0);
    },
  );
}
