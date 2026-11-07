# iOS test builds

GitHub Actions `Build iOS unsigned test app` uses Flutter 3.41.4, Go 1.24.7
and the macOS 15 ARM64 runner's Xcode. It builds an iPhone ARM64 release app
without code signing, archives it as an unsigned IPA, then builds and launches
an ARM64 simulator app to check normal startup, QuickJS execution, free space,
a real four-connection HTTP download, H.264 decoding, and an authenticated
AVKit stream with play, pause, seek and final-position handoff.

The download core runs in the app through a C archive packaged as an
XCFramework. No subprocess or control HTTP server is needed. The same native
core supports HTTP, BT and ed2k; actual swarm performance needs device testing.
Completed downloads are stored in Documents/Downloads and can be exported from
the app or accessed in Files. Long-running background transfers follow iOS
process suspension rules; Android's foreground service is unavailable on iOS.
The player uses the existing media_kit backend; brightness, rotation, the idle
timer and system volume are integrated. Output volume follows hardware button
changes; if the current output cannot be controlled, the player keeps its
existing volume fallback. Screenshots can be saved to Photos with permission.
System PiP uses AVKit on supported devices. Entering PiP pauses media_kit before
the system decoder opens a separate authenticated local transport; ordinary
playback continues to use media_kit. Returning restores the final position;
closing PiP saves progress and keeps playback paused. Unsupported system formats
or failed PiP startup restore the original decoder. The window is one system
PiP session, not multiple independent iOS windows. External playback supports
installed Infuse and VLC through their URL schemes. Only directly accessible
HTTP(S) links are handed off; videos requiring account headers or an app-local
proxy need the internal player or file export, since another app can suspend
this app's local server. Infuse receives the resume position; VLC's stream
scheme starts from the beginning. External-app progress is not synced back.

## Platform compatibility

- Account backups, torrent files, subtitles and background images use iOS
  document types. Backup and diagnostic exports use the native document picker;
  sharing includes an iPad popover anchor.
- Directory selection keeps security-scoped bookmarks and restores access on
  launch. App-container and granted-directory moves update both client task
  paths and native download checkpoints before tasks are loaded. Accounts,
  source links, task IDs and downloaded byte ranges are preserved. Same-volume
  saves inside the app may use hard links. New payloads stay in Application
  Support until complete; external Files providers receive coordinated copies.
  Existing download cache roots are preserved for upgrades and resume.
- Account login and browser search share the persistent WK website store, so
  HttpOnly login cookies can be captured. Starting another account login clears
  that provider's cookies and its known authentication hosts.
- Device pairing supports the camera and manual addresses. Automatic discovery
  sends bounded unicast probes on up to four local /24 networks; peers outside
  those ranges need manual pairing. Connected peers receive reply-requesting
  heartbeats. No restricted broadcast/multicast entitlement is required.
- TV casting accepts a device IP address or complete description URL when
  automatic SSDP discovery is unavailable. Local-network permission is required.
- `wenxi://` links enter the existing validated external-open flow, including
  cold launches. An iOS Share Extension and file associations are not included.
- The update page explains signed builds, TestFlight and App Store installation.
  iOS cannot use the Android APK or Windows installer update paths. Apple native
  crash-report collection is not integrated.

The default Documents download directory is the most predictable storage path.
Access to third-party cloud file providers depends on the provider being online
and its security-scoped access; direct download I/O does not yet use
`NSFileCoordinator`, so those providers need device testing.

The workflow compiles the native bridges and runs Dart regressions, native Go
storage/resume tests and the simulator smoke checks. Simulator checks cover the
AVKit transport and playback operations; real system PiP window interaction,
background playback, camera, document pickers, Photos, hardware volume and
provider login still need verification on an Apple device.

Run the workflow on `codex/ios-build-*`, or dispatch it manually. Official mode
reuses the protected `release` environment's existing client configuration;
public mode omits it. Server code and credentials are not committed.

On a Mac with Xcode, CocoaPods, PowerShell, Go and Flutter:

```sh
flutter config --no-enable-swift-package-manager
pwsh tool/build-ios.ps1
python tool/package-ios.py
pwsh tool/build-ios.ps1 -Simulator
python tool/ios-simulator-smoke.py
```

The IPA is unsigned and **cannot be installed directly**. Use an Apple
development/distribution signing identity and provisioning profile to sign a
device build; App Store/TestFlight publication also requires an Apple developer
account. Simulator verification does not substitute for testing on an iPhone.
