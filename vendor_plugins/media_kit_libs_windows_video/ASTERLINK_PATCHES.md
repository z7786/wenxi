# AsterLink Windows media runtime

## Optional Windows x64 full component

The application bundles the original compact 20241021 runtime again. The full
PGS-capable 20261108 archive below remains pinned in source and is installed only
after a user clicks Download in Player components. Its archive and extracted DLL
must match SHA-256 before publication to the per-user application support folder.
The separate preference file does not alter account data or imported backups.

Switching requires a complete application restart. The video plugin delay-loads
libmpv so Dart and the native renderer resolve the same selected module. Independent
windows inherit the parent's active variant, including when a pending selection
has not yet been applied. An unavailable/corrupt full component falls back to the
bundled compact runtime. Active full DLLs cannot be overwritten or removed.

Unmodified 7-Zip Extra 26.01 x64 7za.exe is packaged in tools/player-7za.exe from
native/third_party/player-7za-x64-26.01.bin. Both build and runtime verify its
SHA-256; component extraction does not require an external 7-Zip installation.
Its source and license links are in Windows-x64-media-NOTICES.txt.

## 2026-11-09: Windows x64 PGS subtitles (#69)

The x64 runtime now uses `zhongfly/mpv-winbuild`, release
`2026-11-08-8bc468896e`, baseline x86-64 development archive
`mpv-dev-x86_64-20261108-git-8bc468896e.7z`.

- SHA-256: `a36392a8fbd989ae274a37c63d01ef6c51b6070a5ebd2ee26d2715ae88f90ceb`.
- MD5: `f6678a79e2526b16b45ff629574fd96f`.
- Original PGS regression media verifies automatic and explicit subtitle
  selection and disable/re-enable against the real DLL. Both the former
  20241021 runtime and the proposed upstream 0.41.0 runtime fail this test:
  the latter's FFmpeg decoder allowlist still omits `pgssub`.
- The full archive is kept in `native/third_party` because upstream releases
  are retained for 30 days. CMake, build preparation and native test preparation
  verify and use it before network downloads. Headers, import library and
  packaged DLL come from the same archive and a new extraction directory.
- The full build imports `vulkan-1.dll`; the existing verified ANGLE distribution
  supplies this DLL and it remains bundled alongside libmpv. Native test
  preparation supplies it and adds the test runtime directory to the process PATH.
- Source references and component notices are included in
  `assets/licenses/Windows-x64-media-NOTICES.txt`. This is a GPL-enabled build.
  The uncompressed DLL is larger (about 117 MiB); the development archive is
  about 31 MiB. Android/ARM64 media versions and ANGLE are unchanged.

## Earlier runtime changes

The plugin retains its upstream MIT license and existing ANGLE build. The
Windows x64 libmpv pin now matches the runtime used by upstream media_kit's
Windows plugin at the time of the 2026-09-24 playback review:

- Upstream configuration: https://github.com/media-kit/media-kit/blob/main/libs/windows/media_kit_libs_windows_video/windows/CMakeLists.txt
- Build source / release: https://github.com/media-kit/libmpv-win32-video-cmake/releases/tag/20241021
- Archive: `mpv-dev-x86_64-20241021-git-0f78584.7z`
- Upstream MD5: `6ecf18e85b093c3f7edb16f3ee6603f3`
- SHA-256: `e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007`
- Reported runtime: `mpv v0.39.0-179-g0f78584518`, client API 2.3.

The previous pin was `mpv-dev-x86_64-20230924-git-652a1dd.7z` (mpv 0.36
development snapshot, client API 2.1). The versioned extraction directory
prevents an existing build from silently reusing the older DLL. Both the CMake
build and preparation scripts verify the archive. Existing network mirror and
download deadlines remain in place.

Clean builds also prepare headers and import libraries from this same pin in
the stable `build/windows/x64/libmpv` layout consumed by `media_kit_video`.
Extraction finishes during CMake configuration, before video compilation, and
checks required files so a partial directory cannot count as a completed
dependency. The packaged DLL still comes from the versioned directory.

Native regression covers HTTP Range, streaming startup, truncated input,
bounded source recovery, cached seeking, rotation, subtitle rendering, BT and
download-backed playback. This does not establish compatibility with every
GPU, HDR display or Android device. Android's runtime is unchanged.

Windows ARM64 uses a separate dependency directory and native runtime:

- libmpv: `shinchiro/mpv-winbuild-cmake`, release `20261021`, archive
  `mpv-dev-aarch64-20261021-git-e471496c56.7z`, SHA-256
  `015f133399b3525021b6d937cf54ace2761d4f70224d5e62f5df24191b28f398`.
- ANGLE: DLLs from Electron `32.3.3`'s official Windows ARM64 archive, SHA-256
  `0cdac1de0f5750a0d327896b7b4fdeec47a32cc8a9ede1148dc8552a60417a4f`.
  Public EGL/GLES headers remain from the existing ANGLE pin. Electron is not
  embedded. The complete component licenses accompany the Windows payload.
- `tool/prepare-windows-arm64-media.ps1` verifies downloads, extracts only
  native dependencies and license notices, and generates ARM64 MSVC import
  libraries directly from the DLL exports. Modern 7-Zip is required to read
  the ARM64-filtered libmpv archive.
- Installer preparation verifies the PE architecture of every DLL/EXE and the
  ELF/PE architecture of the Dart AOT snapshot before packaging. Native helper
  output is separate from the x64 binary.
