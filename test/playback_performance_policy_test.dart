import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_metrics.dart';
import 'package:asterlink/playback/playback_range_plan.dart';
import 'package:asterlink/playback/playback_render_policy.dart';

void main() {
  test(
    'First output frame and seek landing do not arm rebuffer escalation',
    () {
      final metrics = PlaybackMetrics()..firstFrame = Duration.zero;
      void sample(int ms, int position, {bool buffering = false}) =>
          metrics.observe(
            elapsed: Duration(milliseconds: ms),
            playing: true,
            buffering: buffering,
            position: Duration(milliseconds: position),
          );
      sample(0, 0);
      sample(1000, 0, buffering: true);
      sample(2000, 0);
      expect(metrics.bufferingCount, 0);
      expect(metrics.awaitingProgress, isTrue);
      sample(2100, 100);
      sample(2200, 100, buffering: true);
      sample(2300, 100);
      sample(2400, 100, buffering: true);
      expect(metrics.bufferingCount, 1);
      for (var i = 1; i <= 4; i++) {
        final at = 3000 * i, target = 10000 * i;
        metrics.seek(
          Duration(milliseconds: target),
          Duration(milliseconds: at),
        );
        sample(at + 100, target);
        sample(at + 200, target, buffering: true);
        expect(metrics.awaitingProgress, isTrue);
        sample(at + 300, target);
        sample(at + 400, target + 100);
        expect(metrics.awaitingProgress, isFalse);
      }
      expect(metrics.bufferingCount, 1);
    },
  );

  test(
    'Progressive ranges cover unaligned, short and large files without gaps',
    () {
      for (final chunk in [
        8192,
        524288,
        1048576,
        3 * 1048576,
        4 * 1048576,
        16 * 1048576,
      ]) {
        for (final start in [0, 1337, 5000007]) {
          for (final length in [1, 77777, 80 * 1048576 + 27]) {
            final plan = PlaybackRangePlan(start, start + length - 1, chunk);
            var next = start;
            for (var i = 0; i <= plan.last; i++) {
              final (from, to) = plan.range(i);
              expect(from, next);
              expect(to, greaterThanOrEqualTo(from));
              expect(to - from + 1, lessThanOrEqualTo(chunk));
              next = to + 1;
            }
            expect(next, start + length);
          }
        }
      }
    },
  );

  test(
    'Startup uses waves of 512 KiB, 1 MiB, 2 MiB then configured chunks',
    () {
      final plan = PlaybackRangePlan(123, 100 * 1048576, 4 * 1048576);
      int size(int i) => plan.range(i).$2 - plan.range(i).$1 + 1;
      expect(size(0), 524288);
      expect(size(7), 524288);
      expect(size(8), 1048576);
      expect(size(16), 2 * 1048576);
      expect(size(24), 4 * 1048576);
    },
  );

  test(
    'Render size respects physical pixels, zoom, portrait, cover and source ceiling',
    () {
      Size? size(
        Size source,
        Size viewport, {
        double dpr = 1,
        double zoom = 1,
        BoxFit fit = BoxFit.contain,
      }) => playbackRenderSize(
        source: source,
        viewport: viewport,
        pixelRatio: dpr,
        fit: fit,
        scale: zoom,
      );
      expect(
        size(const Size(3840, 2160), const Size(960, 540)),
        const Size(960, 540),
      );
      expect(
        size(const Size(3840, 2160), const Size(960, 540), dpr: 2),
        const Size(1920, 1080),
      );
      expect(
        size(const Size(3840, 2160), const Size(960, 540), zoom: 2),
        const Size(1920, 1080),
      );
      expect(
        size(const Size(720, 1280), const Size(1080, 1920)),
        const Size(720, 1280),
      );
      expect(
        size(const Size(1920, 1080), const Size(1000, 1000), fit: BoxFit.cover),
        const Size(1778, 1000),
      );
      expect(size(Size.zero, const Size(100, 100)), isNull);
      expect(
        playbackRenderSize(
          source: const Size(1920, 1080),
          viewport: const Size(3840, 2160),
          pixelRatio: 1,
          fit: BoxFit.contain,
          quality: .75,
        ),
        const Size(1440, 810),
      );
    },
  );

  test(
    'Only sustained drop rates downgrade, once, with reset-safe counters',
    () {
      final policy = PlaybackDropPolicy();
      bool sample(int second, int drops, {bool eligible = true}) =>
          policy.observe(
            elapsed: Duration(seconds: second),
            drops: drops,
            fps: 60,
            eligible: eligible,
          );
      expect(sample(0, 0), isFalse);
      expect(sample(10, 40), isFalse);
      policy.resetWindow(); // seek cancels the first bad window
      expect(sample(20, 80), isFalse);
      expect(sample(30, 0), isFalse); // native counter reset
      expect(sample(40, 40, eligible: false), isFalse);
      expect(sample(50, 80), isFalse);
      expect(sample(60, 120), isTrue);
      expect(sample(70, 200), isFalse);
    },
  );
}
