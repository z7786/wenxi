# AsterLink patches

Upstream: media_kit_video 2.0.1, https://github.com/media-kit/media-kit .
MIT LICENSE and copyright headers retained. Platform sources and shared Darwin
files are vendored; no global pub cache is patched.

2026-11-11:

- Android prefers mediacodec,mediacodec-copy; emulator detection retains software.
  The application exposes a persistent copy-decoder fallback.
- Android implements setSize, retains source dimensions for reset, deduplicates
  dimensions, serializes Surface attachment/disposal, and reconfigures VO to apply
  android-surface-size without calling player.seek.
- SurfaceProducer reuses a JNI global reference for the same Surface object.
  Replacement/cleanup schedules old-reference release; disposal is idempotent.
- Desktop video parameter updates respect dimensions set via setSize.

Tests: test/native_video_output_test.dart uses real Windows mpv handles with mocked
Android MethodChannel operations. PlaybackTextureTest exercises production Java
under Robolectric with fake SurfaceProducer/JNI. Neither proves real GPU output.
See docs/PLAYER-PERFORMANCE-CHECKLIST.md for integration and device QA.
