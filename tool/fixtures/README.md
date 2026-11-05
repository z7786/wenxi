# macOS playback fixture

`macos-playback.mp4` is an original 12-second, 160×90 H.264 video generated from FFmpeg's `testsrc2` filter. It contains no user media or audio and is used only by the macOS CI playback smoke test; it is not included in application assets.

Recreate with FFmpeg:

```sh
ffmpeg -f lavfi -i testsrc2=size=160x90:rate=30 -t 12 -an -c:v libx264 -pix_fmt yuv420p -preset fast -crf 30 -movflags +faststart macos-playback.mp4
```
