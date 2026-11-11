# AsterLink local patch

## Optional property reads

Free the allocated property name when `mpv_get_property_string` returns null.
Playback monitoring probes optional properties on different libmpv builds;
unavailable properties must not leak a native allocation on every sample.

Based on the published `media_kit 1.2.6` package from pub.flutter-io.cn.
Original package archive SHA-256:
`ae9e79597500c7ad6083a3c7b7b7544ddabfceacce7ae5c9709b0ec16a5d6643`.
The upstream `lib/`, `assets/`, manifest, README, changelog and MIT license are
preserved. Screenshots, examples and upstream tests are omitted from this
application dependency.

## Container rotation field

`lib/src/player/native/player/real.dart` also accepts `demux-rotation` when
parsing `track-list`. libmpv exports rotation under that name; the original
package only accepted `demux-rotate`, leaving `VideoTrack.rotate` null for a
rotated QuickTime/MP4 track. The old spelling remains supported.

This allows AsterLink to determine display orientation from container metadata
before video decoding. No native library or decoder version is changed.
`test/native_playback_test.dart` in the application exercises the real bundled
Windows libmpv with generated rotation and pixel-aspect-ratio fixtures, with
video decoding disabled. `tool/fixtures/make_orientation_samples.py` reproduces
these original fixtures.

Remove this override after adopting an upstream release containing the same
fix and rerunning the native playback tests.

## Native wakeup lifetime (0.3.22)

On disposal, unregister the libmpv wakeup callback, invalidate its generation,
and drain the serialized Dart event handler. Queued callbacks cannot access a
closed or reused mpv handle. Keep the NativeCallable trampoline referenced until
mpv_terminate_destroy has returned, then close it. Dart's NativeCallable contract
forbids native invocations after close; unregistering a callback alone does not
make already scheduled Dart event handlers safe to dereference a retired handle.

The app's real libmpv regression and BT streaming tests cover seek, rotation,
play/pause, source closure, and delayed native destruction. Controller tests
cover source leases during decoder rebuilding. The existing native library
versions and delayed mpv destruction are preserved.

## Terminal playback failures (0.3.25)

Expose `NativePlayer.playbackFailures` as a broadcast stream carrying the native
error code only for `MPV_EVENT_END_FILE` with `MPV_END_FILE_REASON_ERROR`.
Close it during native player disposal. The original log and error streams stay
available: they include recoverable TCP, decoder and subtitle messages and are
not themselves proof that the media has stopped.

The application keeps those messages in diagnostics, but treats this new stream
and exhausted, demanded HTTP Range reads as playback failures. Expired URLs and
connection errors can reacquire the cloud source once, retaining playback
position and pause intent. Normal EOF, explicit stop and redirects do not emit
terminal errors. Real libmpv tests cover ongoing playback after recoverable log
messages, a missing media load, EOF and stop; controller and HTTP tests cover
bounded refresh, cancellation, source leases and Range retries.

Remove this extension when the upstream package exposes an equivalent terminal
failure signal and the application has migrated with these regressions passing.

## Screenshot argument allocation and cleanup

Allocate `screenshot-raw` arguments as a null-terminated array of pointers.
The upstream allocation used the total character count, which is insufficient
for three pointers on 64-bit platforms when capturing without subtitles.
Free the command result and arguments in `finally`, also when encoding fails.
Validate dimensions, stride and buffer length before encoding; cap captures at
16 megapixels to bound temporary image allocations. The real libmpv subtitle
render tests exercise PNG captures with and without libass subtitles.
