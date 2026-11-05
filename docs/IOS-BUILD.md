# iOS test builds

GitHub Actions `Build iOS unsigned test app` uses Flutter 3.41.4, Go 1.24.7
and the macOS 15 ARM64 runner's Xcode. It builds an iPhone ARM64 release app
without code signing, archives it as an unsigned IPA, then builds and launches
an ARM64 simulator app to check normal startup, QuickJS execution, free space,
a real four-connection HTTP download, and H.264 decoding.

The download core runs in the app through a C archive packaged as an
XCFramework. No subprocess or control HTTP server is needed. The same native
core supports HTTP, BT and ed2k; actual swarm performance needs device testing.
Completed downloads are stored in Documents/Downloads and can be exported from
the app or accessed in Files. Long-running background transfers follow iOS
process suspension rules; Android's foreground service is unavailable on iOS.
The player uses the existing media_kit backend; brightness, rotation and idle
timer are integrated. System PiP and external-player selection are not enabled
on iOS in this initial test build.

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
