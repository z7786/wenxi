# Apple storage, picture in picture and remote configuration

iOS keeps new incomplete downloads in Application Support. Completed files are
published to the user's selected Files directory through `NSFileCoordinator`,
with security-scoped directory access restored from existing bookmarks. Local
app-directory saves may use hard links; external File Providers always receive
an independent file. Writers close before publication completes. Cancellation
removes only the document created by that save and preserves the downloaded
payload. Existing task cache roots remain unchanged so upgrades can resume them.
An iCloud upload indicator reflects the provider's sync state and is distinct
from a completed local download.

The iOS PiP video layer mounts on the active scene's native root view before
creating the `AVPictureInPictureController`. The original media_kit texture stays
mounted throughout preparation and restoration. The native layer remains
transparent until it has a video frame. Preparation succeeds only after the
seek, visible attachment and first frame; failed or timed-out preparation closes
the native session and restores the original player's position. Diagnostic
events include readiness, dimensions and native error domain/code, never URLs
or account headers. The system player still needs an AVKit-compatible source;
the ordinary player remains available for other formats.

Implementation references inspected on GitHub:

- [BetterPlayer iOS](https://github.com/jhomlala/betterplayer/blob/d9438b37c494641e007626d7b39f9224a8655487/packages/better_player_ios/ios/better_player_ios/Sources/better_player_ios/BetterPlayer.swift): native-root PiP layer mounting and controller lifecycle.
- [VLC iOS](https://github.com/videolan/vlc-ios/blob/f4a0d6c64c332a47670216f6809034596fc8b45c/Sources/Playback/Control/PictureInPictureMediaController.swift): play/pause, seek and current-time ownership for system controls. VLC uses VLCKit; this app retains media_kit and AVKit rather than adding a second VLC runtime.
- [Nextcloud iOS](https://github.com/nextcloud/ios/blob/d502bbf5cea0ea64e41cac1d3f8d12e5055676cb/File%20Provider%20Extension/FileProviderExtension.swift): security-scoped access and coordinated document import.
- [LocalSend file saver](https://github.com/localsend/localsend/blob/92e133aa43869e94d394fd04fa70c50a0f796a64/packages/localsend_isolates/lib/src/task/server/file_saver.dart): separate cached payloads and final destinations, path validation and preservation of existing files.

`远程配置编辑器.html` and `config/control.example.json` include separate
`updates.android`, `updates.windows`, `updates.ios` and `updates.macos` fields.
Announcements, cloud availability, help and parser configuration remain shared.
Each update uses the installed platform's build number, with independent cache,
validation, expiry and ignore rules. Older configurations that omit Apple update
fields still work. iOS opens the configured download/release page in the browser;
an unsigned test IPA still requires user signing. macOS supports DMG/ZIP updates.

The iOS workflow verifies native file publication and duplicate-name protection
in a simulator, along with authenticated AVKit playback and repeated system PiP
entry/exit. It also invokes the production player page's PiP menu action twice,
checks that the ordinary decoder pauses, and verifies that restoration continues
playback with the same decoder and Flutter texture element. iCloud/File Provider
sync, signed device playback and system-window button taps require device
verification.
